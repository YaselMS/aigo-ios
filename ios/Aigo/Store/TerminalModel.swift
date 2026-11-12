import Foundation

/// Live terminal of one session (docs/API.md §6, issue #46).
///
/// Streams `WS /api/v1/sessions/{id}/attach?history=3000` into SwiftTerm
/// (`TerminalSurfaceView`). The host owns the truth: every `size` message sets
/// the terminal to the PTY's cols×rows first, and a `size` with `replay:true`
/// is followed by a snapshot (a replay that starts with its own reset) that
/// ends with `replayed`. Binary frames are raw PTY bytes and go straight to
/// SwiftTerm. Nothing is cached or replayed locally; back from the background
/// the model asks for a fresh snapshot (`refresh`), or re-attaches.
///
/// Size: "PC size" sends `resize` with `mode:"view"` (the PC keeps its size,
/// the phone scales the text to fit); "Fit to phone" sends `mode:"interactive"`
/// with the grid SwiftTerm fits on the phone (the PTY takes the phone's size).
/// Typing switches to Fit to phone unless the user explicitly picked PC size.
/// Outside the Terminal tab the phone is always in view mode.
///
/// Snapshots are replays of raw VT output (host v0.4.0, issue #94): they start
/// with their own reset (RIS), so the bytes go to SwiftTerm as they are and the
/// terminal is not reset or cleared here (only an older host's raw history and
/// an exited session's screen text start from a cleared screen).
///
/// Input: SwiftTerm encodes keys (cursor-key mode, bracketed paste, mouse) and
/// the bytes go to the socket. The emulator's own replies to queries are not
/// typing: they are dropped during a snapshot and otherwise sent as
/// `{"type":"report"}` on the socket when `hello.terminal.report` is true (the
/// host passes on only the size owner's), else by REST (older hosts). Neither
/// claims the PTY size.
///
/// GET /screen is still polled (debounced) for the on-screen menu and the
/// "working" line; it does not drive the rendering.
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
    /// Ctrl / Alt from the key bar: applied to the next key.
    @Published private(set) var ctrlLatched = false
    @Published private(set) var altLatched = false

    /// The terminal view (SwiftTerm). Owned here so it keeps its state while
    /// another tab is shown.
    let surface = TerminalSurfaceView(frame: .zero)

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
    private var replaying = false
    private var replayWatchdog: Task<Void, Never>?
    /// The replay counts as stuck when no frame arrived before this time.
    private var replayDeadline = Date.distantPast
    /// A `refresh` was sent; re-attach if no `size` answers it.
    private var refreshWatchdog: Task<Void, Never>?
    /// Input typed while a snapshot was being written.
    private var pendingInput: [Data] = []
    /// The first snapshot of this connection has been written.
    private var attached = false
    private var gotSize = false
    private var legacyReplay = false
    /// `hello.terminal.report`: the host takes `{"type":"report"}` messages.
    private var reportProtocol = false
    private var helloSize: GridSize?
    /// The grid that fits the phone at the chosen text size.
    private var phoneGrid: GridSize?
    private var lastSent: (grid: GridSize, mode: String)?
    private var resizeTask: Task<Void, Never>?
    /// The terminal shows GET /screen text (exited session), not a stream.
    private var showsScreenText = false
    /// A snapshot from the host was written (then GET /screen text is not shown).
    private var hadSnapshot = false

    init() {
        surface.onUserInput = { [weak self] bytes in self?.userInput(bytes) }
        surface.onReport = { [weak self] bytes in self?.report(bytes) }
        surface.onPhoneGrid = { [weak self] g in self?.setPhoneGrid(g) }
        surface.onKeyboardChange = { [weak self] on in self?.keyboardChanged(on) }
        surface.onModifiersChange = { [weak self] in self?.syncModifiers() }
    }

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
        refreshWatchdog?.cancel()
        refreshWatchdog = nil
        pendingInput.removeAll()
        attached = false
        gotSize = false
        legacyReplay = false
        reportProtocol = false
        lastSent = nil
    }

    /// The session (re)started on the PC: attach again.
    func reconnect() {
        guard let c = client, let sid = sessionID else { return }
        stop()
        start(client: c, sessionID: sid, running: true)
    }

    /// Back from the background: ask for a fresh snapshot on the live socket
    /// (API.md §6), or re-attach if the socket did not survive. Never replay
    /// what was cached.
    func resume() {
        refreshSnapshot()
        scheduleRefresh(immediate: true)
    }

    /// Asks for a fresh snapshot (`refresh`); re-attaches when the socket is
    /// gone or the host does not answer.
    func refreshSnapshot() {
        guard let s = socket else { return }
        guard s.isOpen, sizeProtocol, attached, !replaying else {
            restartSocket()
            return
        }
        s.send(["type": "refresh"])
        refreshWatchdog?.cancel()
        refreshWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.restartSocket()
        }
    }

    private func restartSocket() {
        guard let s = socket else { return }
        resetConnectionState()
        live = false
        s.restart()
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
        if c == .phone { surface.resetZoom() }
        sendResize()
    }

    /// Columns/rows SwiftTerm fits in the visible terminal at the chosen text
    /// size. Debounced: keyboard and rotation animations report many sizes.
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
            reportProtocol = f.terminal?.report == true
            if let c = f.session?.cols, let r = f.session?.rows, c > 0, r > 0 {
                helloSize = GridSize(cols: c, rows: r)
            }
            // Older hosts replay raw output right after hello; v0.4 hosts send `size` first.
            beginReplay()
        case "size":
            refreshWatchdog?.cancel()
            refreshWatchdog = nil
            sizeProtocol = true
            gotSize = true
            if let c = f.cols, let r = f.rows, c > 0, r > 0 {
                // Resize the terminal first; the snapshot that follows draws at this size.
                takeOverFromScreenText()
                let g = GridSize(cols: c, rows: r)
                surface.setPTY(g)
                if ptySize != g { ptySize = g }
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
            // Unknown message types (newer hosts) are ignored.
            break
        }
    }

    /// A replay can be large (scrollback plus up to 1 MB of raw output), so the
    /// watchdog only ends it after 5 s without a frame (30 s at most).
    private func beginReplay() {
        replaying = true
        replayDeadline = Date().addingTimeInterval(5)
        let cap = Date().addingTimeInterval(30)
        replayWatchdog?.cancel()
        replayWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.replayDeadline else { return }
                let left = min(deadline, cap).timeIntervalSinceNow
                if left <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000) + 1_000_000)
            }
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
            surface.setPTY(h)
            ptySize = h
        }
        replaying = false
        attached = true
        if sizeProtocol || legacyReplay { hadSnapshot = true }
        flushPendingInput()
        if first {
            sendResize(force: true)
        }
        scheduleRefresh(immediate: true)
    }

    private func takeOverFromScreenText() {
        guard showsScreenText else { return }
        showsScreenText = false
        shownText = nil
        surface.clear()
    }

    private func output(_ data: Data) {
        takeOverFromScreenText()
        if !gotSize && !attached && !legacyReplay {
            // Older host: raw output history recorded at earlier sizes. Start clean once.
            legacyReplay = true
            if let h = helloSize {
                surface.setPTY(h)
                ptySize = h
            }
            surface.clear()
        }
        // Replays and live output alike go to SwiftTerm as they are.
        surface.feed(data)
        if replaying {
            replayDeadline = Date().addingTimeInterval(5)
        } else {
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
        let g = GridSize(cols: min(width, 400), rows: max(1, trimmed.count))
        surface.setPTY(g)
        ptySize = g
        surface.clear()
        surface.feed(Data(trimmed.joined(separator: "\r\n").utf8))
        showsScreenText = true
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

    /// The terminal gained/lost keyboard focus.
    private func keyboardChanged(_ on: Bool) {
        if keyboardShown != on { keyboardShown = on }
    }

    func setKeyboard(_ on: Bool) {
        surface.setKeyboard(on)
    }

    func toggleCtrl() {
        surface.ctrlLatched.toggle()
    }

    func toggleAlt() {
        surface.altLatched.toggle()
    }

    private func syncModifiers() {
        if ctrlLatched != surface.ctrlLatched { ctrlLatched = surface.ctrlLatched }
        if altLatched != surface.altLatched { altLatched = surface.altLatched }
    }

    /// A key from the bar (through SwiftTerm, so Ctrl/Alt and cursor-key mode apply).
    func press(_ key: TerminalKey) {
        guard !exited else { return }
        surface.press(key)
    }

    func paste() {
        guard !exited else { return }
        surface.paste()
    }

    // MARK: - Input

    /// Keystrokes, paste and mouse events from SwiftTerm.
    private func userInput(_ bytes: ArraySlice<UInt8>) {
        let data = Data(bytes)
        if sendNow(data) { return }
        // No socket: REST input keeps typing working while it reconnects.
        guard let c = client, let sid = sessionID else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { [weak self] in
            try? await c.input(sid, data: text)
            self?.scheduleRefresh()
        }
    }

    /// The emulator's replies to queries: never typed, so they must not claim
    /// the PTY size. Dropped while a snapshot is written (they answer the
    /// snapshot, not the program). Sent as `report` on the socket when the host
    /// understands it (API.md §6), else by REST.
    private func report(_ bytes: ArraySlice<UInt8>) {
        guard !exited, attached, !replaying, let c = client, let sid = sessionID else { return }
        let text = String(decoding: Data(bytes), as: UTF8.self)
        if reportProtocol, let s = socket, s.isOpen {
            s.send(["type": "report", "data": text])
            return
        }
        Task { try? await c.input(sid, data: text) }
    }

    /// Sends text to the PTY (menu actions). Returns an error message, or nil.
    func send(_ text: String) async -> String? {
        guard !text.isEmpty, !exited else { return nil }
        if sendNow(Data(text.utf8)) { return nil }
        guard let c = client, let sid = sessionID else { return "Not connected to your PC." }
        do {
            try await c.input(sid, data: text)
            scheduleRefresh()
            return nil
        } catch {
            return c.problem(for: error).message
        }
    }

    /// Sends (or queues, during a snapshot) on the live socket, synchronously
    /// so keystrokes keep their order. False: no open socket.
    /// Typing switches to Fit to phone unless the user picked PC size.
    @discardableResult
    private func sendNow(_ data: Data) -> Bool {
        guard !data.isEmpty, !exited else { return true }
        if visible && choice == .pc && !explicitChoice {
            choice = .phone
            surface.resetZoom()
            sendResize()
        }
        guard let s = socket, s.isOpen else { return false }
        if replaying {
            // No input while a snapshot is being written (API.md §6).
            pendingInput.append(data)
            return true
        }
        return s.sendData(data)
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

    func screenText() -> String { surface.text(includeHistory: false) }
    func allText() -> String { surface.text(includeHistory: true) }
    func selectedText() -> String? { surface.selectedText() }
}

/// The special-keys bar.
enum TerminalKeys {
    struct Key: Identifiable {
        let label: String
        let key: TerminalKey
        let accessibility: String
        var id: String { label }
    }

    static let bar: [Key] = [
        Key(label: "Esc", key: .esc, accessibility: "Escape"),
        Key(label: "Tab", key: .tab, accessibility: "Tab"),
        Key(label: "↑", key: .up, accessibility: "Up arrow"),
        Key(label: "↓", key: .down, accessibility: "Down arrow"),
        Key(label: "←", key: .left, accessibility: "Left arrow"),
        Key(label: "→", key: .right, accessibility: "Right arrow"),
        Key(label: "Enter", key: .enter, accessibility: "Enter"),
        Key(label: "^C", key: .bytes([0x03]), accessibility: "Control C"),
        Key(label: "^D", key: .bytes([0x04]), accessibility: "Control D"),
        Key(label: "1", key: .text("1"), accessibility: "1"),
        Key(label: "2", key: .text("2"), accessibility: "2"),
        Key(label: "3", key: .text("3"), accessibility: "3"),
        Key(label: "y", key: .text("y"), accessibility: "y"),
        Key(label: "n", key: .text("n"), accessibility: "n"),
    ]
}
