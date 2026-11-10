import Foundation

/// Live terminal of one session (docs/API.md §6, issue #46).
///
/// Streams `WS /api/v1/sessions/{id}/attach?history=3000` into a local VT
/// emulator. The host owns the truth: every `size` message sets the emulator
/// to the PTY's cols×rows first, and a `size` with `replay:true` is followed
/// by a snapshot (it clears the screen and scrollback itself) that ends with
/// `replayed`. Nothing is cached or replayed locally; after a reconnect or a
/// return from the background the socket re-attaches and gets a new snapshot.
///
/// Size: "PC size" sends `resize` with `mode:"view"` (the PC keeps its size,
/// the phone scales the text to fit); "Fit to phone" sends `mode:"interactive"`
/// (the PTY takes the phone's size). Typing switches to Fit to phone unless
/// the user explicitly picked PC size. Outside the Terminal tab the phone is
/// always in view mode.
///
/// GET /screen is still polled (debounced) for the on-screen menu and the
/// "working" line; it no longer drives the rendering.
@MainActor
final class TerminalModel: ObservableObject {
    enum SizeChoice: String {
        case pc
        case phone
    }

    /// Host-parsed screen: menu and "working" line.
    @Published private(set) var screen: ScreenState?
    /// The attach socket is open.
    @Published private(set) var live = false
    @Published private(set) var problem: String?
    @Published private(set) var exited = false
    /// PC size (view) or Fit to phone (interactive).
    @Published private(set) var choice: SizeChoice = .pc
    /// The PTY size from the latest `size` message.
    @Published private(set) var ptySize: GridSize?
    /// This phone owns the PTY size.
    @Published private(set) var owner = false
    /// The host speaks the v0.4 attach protocol (sends `size`).
    @Published private(set) var sizeProtocol = false
    /// The iOS keyboard is typing into the terminal.
    @Published private(set) var keyboardShown = false
    /// Ctrl from the key bar: the next letter is sent as a control key.
    @Published var ctrlLatched = false

    let emulator: VTEmulator = {
        let e = VTEmulator(cols: 80, rows: 24)
        // The snapshot brings up to 3000 lines; keep room for live output after it.
        e.maxHistory = 5000
        return e
    }()
    weak var canvas: TerminalCanvasView? {
        didSet { canvas?.holdsUpdates = replaying }
    }

    /// Minimum delay between output and the GET /screen it triggers.
    var debounceNanos: UInt64 = 400_000_000
    /// Scrollback lines per snapshot: everything the host keeps (API §6, max 3000; #82).
    static let historyLines = 3000

    private var socket: LiveSocket?
    private var client: APIClient?
    private var sessionID: String?
    private var refreshTask: Task<Void, Never>?
    private var refreshGen = 0
    private var dirty = false
    private var fallback: Task<Void, Never>?

    /// The Terminal tab is on screen (interactive mode allowed).
    private var visible = false
    /// The user picked PC size / Fit to phone themselves.
    private var explicitChoice = false
    /// Between `size(replay:true)` (or `hello` on older hosts) and `replayed`.
    private var replaying = false {
        didSet { canvas?.holdsUpdates = replaying }
    }
    private var replayWatchdog: Task<Void, Never>?
    /// Input typed while a snapshot was being written.
    private var pendingInput: [Data] = []
    /// The first snapshot of this connection has been written.
    private var attached = false
    private var gotSize = false
    private var legacyReplay = false
    private var helloSize: GridSize?
    /// The grid that fits the phone at the chosen text size.
    private var phoneGrid: GridSize?
    private var lastSent: (grid: GridSize, mode: String)?
    private var resizeTask: Task<Void, Never>?
    /// The emulator shows GET /screen text (exited session), not a stream.
    private var showsScreenText = false
    /// A snapshot from the host was written (then GET /screen text is not shown).
    private var hadSnapshot = false

    var mode: String {
        visible && choice == .phone && !exited ? "interactive" : "view"
    }

    /// Exited sessions are attached too (view mode, never typed into): the
    /// host replays their last screen and scrollback, so they scroll and zoom
    /// like a live terminal (#81). GET /screen text is only the fallback.
    func start(client: APIClient, sessionID: String, running: Bool) {
        if self.sessionID == sessionID && self.client === client && socket != nil { return }
        stop()
        self.client = client
        self.sessionID = sessionID
        exited = !running
        do {
            let s = LiveSocket(client: client,
                               path: "/api/v1/sessions/\(sessionID)/attach?history=\(TerminalModel.historyLines)")
            s.onBinary = { [weak self] data in
                self?.output(data)
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
        socket?.stop()
        socket = nil
        refreshGen += 1
        refreshTask?.cancel()
        refreshTask = nil
        fallback?.cancel()
        fallback = nil
        resizeTask?.cancel()
        resizeTask = nil
        replayWatchdog?.cancel()
        replayWatchdog = nil
        sessionID = nil
        hadSnapshot = false
        live = false
        resetConnectionState()
    }

    private func resetConnectionState() {
        replaying = false
        pendingInput.removeAll()
        attached = false
        gotSize = false
        legacyReplay = false
        lastSent = nil
    }

    /// The session (re)started on the PC: attach again.
    func reconnect() {
        guard let c = client, let sid = sessionID else { return }
        stop()
        start(client: c, sessionID: sid, running: true)
    }

    /// Back from the background: re-attach for a fresh snapshot (iOS
    /// suspends sockets; never replay what was cached).
    func resume() {
        guard let s = socket else {
            scheduleRefresh(immediate: true)
            return
        }
        resetConnectionState()
        live = false
        s.restart()
        scheduleRefresh(immediate: true)
    }

    /// Asks for a fresh snapshot on the live socket.
    func refreshSnapshot() {
        guard let s = socket, s.isOpen, sizeProtocol, !replaying else {
            resume()
            return
        }
        s.send(["type": "refresh"])
    }

    // MARK: - Size choice

    /// The Terminal tab is shown / hidden.
    func setVisible(_ on: Bool) {
        guard visible != on else { return }
        visible = on
        sendResize()
    }

    /// The user's explicit choice in the Terminal tab.
    func choose(_ c: SizeChoice) {
        explicitChoice = true
        guard choice != c else { return }
        choice = c
        sendResize()
    }

    /// Columns/rows that fit the visible terminal at the chosen text size.
    /// Debounced: keyboard and rotation animations report many sizes.
    func setPhoneGrid(_ g: GridSize) {
        let grid = GridSize(cols: min(max(g.cols, 20), 400), rows: min(max(g.rows, 5), 200))
        guard grid != phoneGrid else { return }
        phoneGrid = grid
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.sendResize()
        }
    }

    /// Reports this phone's size and mode to the host (once per change).
    private func sendResize(force: Bool = false) {
        guard let s = socket, s.isOpen, attached, let grid = phoneGrid else { return }
        let m = mode
        if sizeProtocol {
            if !force, let last = lastSent, last.grid == grid, last.mode == m { return }
            lastSent = (grid, m)
            s.send(["type": "resize", "cols": grid.cols, "rows": grid.rows, "mode": m])
        } else {
            // Older host: every resize is applied, so only send one for Fit to phone.
            guard m == "interactive" else { return }
            if !force, let last = lastSent, last.grid == grid { return }
            lastSent = (grid, m)
            s.send(["type": "resize", "cols": grid.cols, "rows": grid.rows])
        }
    }

    // MARK: - Stream

    private func frame(_ data: Data) {
        guard let f = try? JSONDecoder().decode(AttachFrame.self, from: data) else { return }
        switch f.type {
        case "hello":
            exited = !(f.session?.isRunning ?? true)
            resetConnectionState()
            if let c = f.session?.cols, let r = f.session?.rows, c > 0, r > 0 {
                helloSize = GridSize(cols: c, rows: r)
            }
            // Older hosts replay raw output right after hello; v0.4 hosts send `size` first.
            beginReplay()
        case "size":
            sizeProtocol = true
            gotSize = true
            if let c = f.cols, let r = f.rows, c > 0, r > 0 {
                // Resize the emulator first; the snapshot that follows draws at this size.
                emulator.resize(cols: c, rows: r)
                ptySize = GridSize(cols: c, rows: r)
                canvas?.contentChanged()
            }
            owner = f.owner ?? false
            if f.replay == true {
                beginReplay()
            } else if !attached {
                // Do not wait for a snapshot that will not come.
                endReplay()
            }
        case "replayed":
            endReplay()
        case "exit", "removed":
            exited = true
            scheduleRefresh(immediate: true)
        default:
            break
        }
    }

    private func beginReplay() {
        replaying = true
        replayWatchdog?.cancel()
        replayWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.endReplay()
        }
    }

    private func endReplay() {
        replayWatchdog?.cancel()
        replayWatchdog = nil
        let first = !attached
        if first && !sizeProtocol && !legacyReplay, let h = helloSize {
            // Older host with nothing to replay.
            emulator.resize(cols: h.cols, rows: h.rows)
            ptySize = h
        }
        replaying = false
        attached = true
        if sizeProtocol || legacyReplay { hadSnapshot = true }
        canvas?.contentChanged()
        flushPendingInput()
        if first {
            sendResize(force: true)
        }
        scheduleRefresh(immediate: true)
    }

    private func output(_ data: Data) {
        if showsScreenText {
            showsScreenText = false
            shownText = nil
            emulator.reset()
        }
        if !gotSize && !attached && !legacyReplay {
            // Older host: raw output history recorded at earlier sizes. Start clean once.
            legacyReplay = true
            if let h = helloSize {
                emulator.resize(cols: h.cols, rows: h.rows)
                ptySize = h
            }
            emulator.reset()
        }
        emulator.feed(data)
        if !replaying {
            canvas?.contentChanged()
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
            resetConnectionState()
            if !exited {
                problem = p.message
            }
        }
    }

    // MARK: - Screen (menu, working line)

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
            if socket == nil || (exited && !hadSnapshot) {
                showScreenText(s.text ?? "")
            }
        }
    }

    private var shownText: String?

    /// Exited sessions have no stream: show the host's last screen text.
    private func showScreenText(_ text: String) {
        guard text != shownText else { return }
        shownText = text
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            while let last = l.last, last == " " || last == "\r" { l = l.dropLast() }
            return String(l)
        }
        var trimmed = lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        let width = max(20, trimmed.map { $0.unicodeScalars.count }.max() ?? 20)
        emulator.resize(cols: min(width, 400), rows: max(1, trimmed.count))
        emulator.reset()
        emulator.feed(trimmed.joined(separator: "\r\n"))
        showsScreenText = true
        canvas?.contentChanged()
    }

    /// Safety net: a slow poll for the menu / working line.
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

    // MARK: - Keyboard (#78: keystrokes go straight to the terminal)

    /// Called by the canvas when it gains/loses keyboard focus.
    func keyboardChanged(_ on: Bool) {
        if keyboardShown != on { keyboardShown = on }
        if !on { ctrlLatched = false }
    }

    func setKeyboard(_ on: Bool) {
        canvas?.setKeyboard(on)
    }

    /// One keystroke (or pasted text) from the keyboard. With Ctrl latched a
    /// single letter becomes its control character.
    func keystroke(_ text: String) -> String {
        guard ctrlLatched else { return text }
        ctrlLatched = false
        guard text.count == 1, let u = text.lowercased().unicodeScalars.first else { return text }
        if u.value >= 0x61 && u.value <= 0x7A, let c = Unicode.Scalar(u.value - 0x60) {
            return String(Character(c))
        }
        switch text {
        case "[": return "\u{1B}"
        case "]": return "\u{1D}"
        case " ", "@", "2": return "\u{00}"
        default: return text
        }
    }

    // MARK: - Input

    /// Sends raw bytes to the PTY. Returns an error message, or nil.
    /// Typing switches to Fit to phone unless the user picked PC size.
    func send(_ text: String) async -> String? {
        guard !text.isEmpty, !exited else { return nil }
        if sendNow(text) { return nil }
        var bytes = text
        if emulator.appCursorKeys, let mapped = TerminalKeys.applicationCursor[text] {
            bytes = mapped
        }
        guard let c = client, let sid = sessionID else { return "Not connected to your PC." }
        do {
            try await c.input(sid, data: bytes)
            scheduleRefresh()
            return nil
        } catch {
            return c.problem(for: error).message
        }
    }

    /// Sends (or queues, during a snapshot) on the live socket, synchronously
    /// so keystrokes keep their order. False: no open socket.
    @discardableResult
    func sendNow(_ text: String) -> Bool {
        guard !text.isEmpty, !exited else { return true }
        var bytes = text
        if emulator.appCursorKeys, let mapped = TerminalKeys.applicationCursor[text] {
            bytes = mapped
        }
        if visible && choice == .pc && !explicitChoice {
            choice = .phone
            sendResize()
        }
        canvas?.scrollToBottom()
        guard let s = socket, s.isOpen else { return false }
        if replaying {
            // No input while a snapshot is being written (API.md §6).
            pendingInput.append(Data(bytes.utf8))
            return true
        }
        return s.sendData(Data(bytes.utf8))
    }

    private func flushPendingInput() {
        guard !pendingInput.isEmpty, let s = socket, s.isOpen else {
            pendingInput.removeAll()
            return
        }
        let queued = pendingInput
        pendingInput.removeAll()
        for d in queued { s.sendData(d) }
    }

    // MARK: - Copy

    func screenText() -> String { emulator.text(includeHistory: false) }
    func allText() -> String { emulator.text(includeHistory: true) }
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

    /// Arrow keys while the program asked for application cursor keys (DECCKM).
    static let applicationCursor: [String: String] = [
        "\u{1B}[A": "\u{1B}OA",
        "\u{1B}[B": "\u{1B}OB",
        "\u{1B}[C": "\u{1B}OC",
        "\u{1B}[D": "\u{1B}OD",
    ]
}
