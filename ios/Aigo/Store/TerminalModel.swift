import Foundation

/// Live terminal of one session.
///
/// Streams WS /api/v1/sessions/{id}/attach: binary output frames are only
/// used as a "something changed" signal that triggers a debounced refresh of
/// the host-rendered screen (GET /screen, the host's VT emulator), so TUIs,
/// colours-free shells and agent menus all render correctly. Input is sent as
/// raw bytes over the same socket (falls back to POST /input).
@MainActor
final class TerminalModel: ObservableObject {
    @Published private(set) var screen: ScreenState?
    /// The attach socket is open.
    @Published private(set) var live = false
    @Published private(set) var problem: String?
    @Published private(set) var exited = false
    /// The PTY is resized to the phone's width while on the Terminal tab.
    @Published private(set) var fitToPhone = false

    /// Minimum delay between output and the screen refresh it triggers.
    var debounceNanos: UInt64 = 150_000_000

    private var socket: LiveSocket?
    private var client: APIClient?
    private var sessionID: String?
    private var replayed = false
    private var refreshTask: Task<Void, Never>?
    private var refreshGen = 0
    private var dirty = false
    private var fallback: Task<Void, Never>?
    private var originalSize: (cols: Int, rows: Int)?
    private var phoneSize: (cols: Int, rows: Int)?
    private var appliedSize: (cols: Int, rows: Int)?

    func start(client: APIClient, sessionID: String, running: Bool) {
        if self.sessionID == sessionID && (socket != nil || !running) { return }
        stop()
        self.client = client
        self.sessionID = sessionID
        exited = !running
        if running {
            let s = LiveSocket(client: client, path: "/api/v1/sessions/\(sessionID)/attach")
            s.onBinary = { [weak self] _ in
                self?.output()
            }
            s.onMessage = { [weak self] data in
                self?.frame(data)
            }
            s.onState = { [weak self] state in
                self?.stateChanged(state)
            }
            socket = s
            s.start()
        }
        scheduleRefresh(immediate: true)
        startFallback()
    }

    func stop() {
        restoreSize()
        socket?.stop()
        socket = nil
        refreshGen += 1
        refreshTask?.cancel()
        refreshTask = nil
        fallback?.cancel()
        fallback = nil
        sessionID = nil
        live = false
        replayed = false
        appliedSize = nil
        originalSize = nil
    }

    /// The session (re)started on the PC: reconnect the stream.
    func reconnect() {
        guard let c = client, let sid = sessionID else { return }
        let fit = fitToPhone
        stop()
        start(client: c, sessionID: sid, running: true)
        if fit {
            fitToPhone = true
        }
    }

    // MARK: - Stream

    private func frame(_ data: Data) {
        guard let f = try? JSONDecoder().decode(AttachFrame.self, from: data) else { return }
        switch f.type {
        case "hello":
            replayed = false
            exited = false
            if originalSize == nil, let c = f.session?.cols, let r = f.session?.rows, c > 0, r > 0 {
                originalSize = (c, r)
            }
        case "replayed":
            replayed = true
            if fitToPhone {
                applyFit()
            }
            scheduleRefresh(immediate: true)
        case "exit", "removed":
            exited = true
            scheduleRefresh(immediate: true)
        default:
            break
        }
    }

    private func output() {
        // The replay of old output is followed by "replayed"; one refresh then is enough.
        if replayed {
            scheduleRefresh()
        }
    }

    private func stateChanged(_ state: LiveSocket.State) {
        switch state {
        case .connecting:
            break
        case .open:
            live = true
            problem = nil
        case .closed(let p):
            live = false
            replayed = false
            appliedSize = nil
            if !exited {
                problem = p.message
            }
        }
    }

    // MARK: - Screen refresh

    /// Coalesces bursts of output into at most one GET /screen per debounce window.
    func scheduleRefresh(immediate: Bool = false) {
        if refreshTask != nil {
            dirty = true
            return
        }
        let gen = refreshGen
        refreshTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let model = self, gen == model.refreshGen else { return }
                model.dirty = false
                let wait = model.debounceNanos
                if !(first && immediate) {
                    try? await Task.sleep(nanoseconds: wait)
                }
                first = false
                guard let again = self, !Task.isCancelled, gen == again.refreshGen else { return }
                await again.fetch()
                if !again.dirty { break }
            }
            if let model = self, gen == model.refreshGen {
                model.refreshTask = nil
            }
        }
    }

    func fetch() async {
        guard let c = client, let sid = sessionID else { return }
        if let s = try? await c.screen(sid), sid == sessionID {
            if s != screen {
                screen = s
            }
        }
    }

    /// Safety net: a slow poll while the stream is down (or quiet).
    private func startFallback() {
        fallback?.cancel()
        fallback = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self = self, !Task.isCancelled else { return }
                tick += 1
                if self.exited {
                    if tick % 6 == 0 { await self.fetch() }
                } else if !self.live || tick % 4 == 0 {
                    await self.fetch()
                }
            }
        }
    }

    // MARK: - Input

    /// Sends raw bytes to the PTY. Returns an error message, or nil.
    func send(_ text: String) async -> String? {
        guard !text.isEmpty else { return nil }
        if let s = socket, s.sendData(Data(text.utf8)) {
            scheduleRefresh()
            return nil
        }
        guard let c = client, let sid = sessionID else { return "Not connected to your PC." }
        do {
            try await c.input(sid, data: text)
            scheduleRefresh()
            return nil
        } catch {
            return c.problem(for: error).message
        }
    }

    // MARK: - Size

    /// Columns/rows that fit the visible terminal area.
    func setPhoneSize(cols: Int, rows: Int) {
        let c = min(max(cols, 20), 300)
        let r = min(max(rows, 8), 200)
        if let p = phoneSize, p.cols == c, p.rows == r { return }
        phoneSize = (c, r)
        if fitToPhone {
            applyFit()
        }
    }

    func setFit(_ on: Bool) {
        fitToPhone = on
        if on {
            applyFit()
        } else {
            restoreSize()
        }
    }

    private func applyFit() {
        guard let p = phoneSize else { return }
        if let a = appliedSize, a.cols == p.cols, a.rows == p.rows { return }
        resize(cols: p.cols, rows: p.rows)
        appliedSize = p
    }

    /// Puts the PTY back to the size it had before the phone attached.
    func restoreSize() {
        guard appliedSize != nil else { return }
        appliedSize = nil
        if let o = originalSize {
            resize(cols: o.cols, rows: o.rows)
        }
    }

    private func resize(cols: Int, rows: Int) {
        if let s = socket, s.isOpen {
            s.send(["type": "resize", "cols": cols, "rows": rows])
        } else if let c = client, let sid = sessionID {
            Task {
                try? await c.call("POST", "/api/v1/sessions/\(sid)/resize", body: ["cols": cols, "rows": rows])
            }
        }
        scheduleRefresh()
    }
}

/// Byte sequences for the terminal key bar (xterm / ConPTY compatible).
enum TerminalKeys {
    struct Key: Identifiable {
        let label: String
        let bytes: String
        let accessibility: String
        var id: String { label }
    }

    static let bar: [Key] = [
        Key(label: "Esc", bytes: "\u{1B}", accessibility: "Escape"),
        Key(label: "Tab", bytes: "\t", accessibility: "Tab"),
        Key(label: "↑", bytes: "\u{1B}[A", accessibility: "Up arrow"),
        Key(label: "↓", bytes: "\u{1B}[B", accessibility: "Down arrow"),
        Key(label: "←", bytes: "\u{1B}[D", accessibility: "Left arrow"),
        Key(label: "→", bytes: "\u{1B}[C", accessibility: "Right arrow"),
        Key(label: "Enter", bytes: "\r", accessibility: "Enter"),
        Key(label: "^C", bytes: "\u{03}", accessibility: "Control C"),
        Key(label: "^D", bytes: "\u{04}", accessibility: "Control D"),
        Key(label: "1", bytes: "1", accessibility: "1"),
        Key(label: "2", bytes: "2", accessibility: "2"),
        Key(label: "3", bytes: "3", accessibility: "3"),
        Key(label: "y", bytes: "y", accessibility: "y"),
        Key(label: "n", bytes: "n", accessibility: "n"),
    ]
}
