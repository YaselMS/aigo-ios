import SwiftUI
import UIKit

/// GET /api/v1/desktop/info.
struct DesktopInfo: Decodable, Equatable {
    var supported: Bool?
    var enabled: Bool?
    var maxFps: Int?
    var quality: Int?
    var maxWidth: Int?
    /// Hosts with `desktop.monitors` (API §7d); id 0 is the primary.
    var monitors: [DesktopMonitor]?
    /// Hosts with `desktop.control`: may this device control the PC?
    var control: DesktopControl?
}

/// `control` in desktop info / the stream (API §7d).
struct DesktopControl: Decodable, Equatable {
    var allowed: Bool
    var reason: String?
}

struct DesktopMonitor: Decodable, Equatable, Identifiable {
    var index: Int
    var name: String?
    var x: Int?
    var y: Int?
    var width: Int?
    var height: Int?
    var primary: Bool?
    var id: Int { index }

    private enum CodingKeys: String, CodingKey { case id, index, name, x, y, width, height, primary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` and `index` are the same number; older builds sent only `index`.
        index = try c.decodeIfPresent(Int.self, forKey: .id) ?? c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        x = try c.decodeIfPresent(Int.self, forKey: .x)
        y = try c.decodeIfPresent(Int.self, forKey: .y)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        primary = try c.decodeIfPresent(Bool.self, forKey: .primary)
    }

    var label: String {
        var s = name?.isEmpty == false ? name! : "Monitor \(index + 1)"
        if let w = width, let h = height { s += " · \(w)×\(h)" }
        if primary == true { s += " · primary" }
        return s
    }
}

enum DesktopModifier: String, CaseIterable, Identifiable {
    case ctrl, alt, win
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .win: return "Win"
        }
    }
    var code: String {
        switch self {
        case .ctrl: return "ControlLeft"
        case .alt: return "AltLeft"
        case .win: return "MetaLeft"
        }
    }
    var key: String {
        switch self {
        case .ctrl: return "Control"
        case .alt: return "Alt"
        case .win: return "Meta"
        }
    }
}

/// Remote desktop of the active PC (#63): JPEG frames over
/// /api/v1/desktop/stream, input sent back as normalized events (same
/// protocol as the desktop/web viewer). View only until "Take control".
@MainActor
final class DesktopModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// The PC can't stream (off, unsupported, too old). Retrying won't help.
        case unavailable(title: String, message: String)
        case connecting(String?)
        case live
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var info: DesktopInfo?
    /// Size of the PC screen (source pixels) and of the streamed picture.
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var fps = 0
    @Published private(set) var kbps = 0
    @Published private(set) var rttMs: Int?
    /// Last error the PC reported while streaming (desktop locked, UAC…).
    @Published private(set) var hostError: String?
    @Published private(set) var hasFrame = false

    @Published var control = false {
        didSet { if !control { releaseAll() } }
    }
    /// The PC lets this device control it (API §7d). Viewing always works.
    @Published private(set) var controlAllowed = true
    @Published private(set) var controlReason: String?
    @Published var trackpad = false
    /// While controlling: one finger pans/zooms the picture instead of the mouse.
    @Published var panLock = false
    @Published var keyboard = false
    @Published private(set) var latched: Set<DesktopModifier> = []

    @Published var maxWidth = 1600 { didSet { sendConfig() } }
    @Published var quality = 60 { didSet { sendConfig() } }
    @Published var targetFps = 8 { didSet { sendConfig() } }
    @Published var monitor = 0 { didSet { if monitor != oldValue && !applyingHost { sendConfig() } } }

    /// Set by the picture view; called for each decoded frame.
    var onFrame: ((UIImage) -> Void)?
    /// Set by the picture view: the PC's real pointer (normalized over the
    /// selected monitor), from `cursor` messages. Not published (30 Hz).
    var onCursor: ((CGPoint, Bool) -> Void)?
    private(set) var hostCursor: CGPoint?
    private var applyingHost = false

    private var client: APIClient?
    private var socket: LiveSocket?
    private var statsTimer: Timer?
    private var frames = 0
    private var bytes = 0
    private var decoding = false
    private var pendingJPEG: Data?
    private var buttonsDown: Set<Int> = []
    private var lastMove = Date.distantPast
    /// Last pointer position sent, so releasing a stuck button doesn't move it.
    private var lastPoint = CGPoint(x: 0.5, y: 0.5)
    private var running = false
    private var configured = false

    var hostLabel: String { client?.hostLabel ?? "PC" }

    func start(client: APIClient?) {
        guard let client = client else {
            phase = .unavailable(title: "Not connected", message: "Connect to a PC first.")
            return
        }
        if running, self.client === client { return }
        stop()
        self.client = client
        running = true
        phase = .loading
        Task { await loadInfoAndConnect() }
    }

    func stop() {
        releaseAll()
        running = false
        socket?.stop()
        socket = nil
        statsTimer?.invalidate()
        statsTimer = nil
        rttMs = nil
        fps = 0
        kbps = 0
    }

    /// Back from the background: iOS dropped the socket; connect again.
    func resume() {
        guard let c = client else { return }
        running = false
        start(client: c)
    }

    /// Going to the background: let go of buttons/keys and close the stream so
    /// the PC stops capturing.
    func suspend() {
        releaseAll()
        socket?.stop()
        socket = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }

    func retry() {
        guard let c = client else { return }
        running = false
        start(client: c)
    }

    private func loadInfoAndConnect() async {
        guard let client = client else { return }
        do {
            let i = try await client.get("/api/v1/desktop/info", as: DesktopInfo.self)
            guard running, self.client === client else { return }
            info = i
            if let c = i.control { applyControl(c) }
            if let bad = DesktopModel.unavailability(i) {
                phase = bad
                return
            }
            if !configured {
                configured = true
                let maxFps = max(i.maxFps ?? 8, 1)
                targetFps = min(maxFps, 8)
                quality = min(i.quality ?? 60, 60)
                maxWidth = min(i.maxWidth ?? 1600, 1600)
            }
            connect()
        } catch let e as APIError where e.status == 404 {
            phase = .unavailable(title: "Not available on this PC",
                                 message: "This PC's Aigo has no remote desktop. Update Aigo on the PC.")
        } catch {
            guard running else { return }
            phase = .connecting(APIError.describe(error))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if running, self.client === client { await loadInfoAndConnect() }
        }
    }

    static func unavailability(_ i: DesktopInfo) -> Phase? {
        if i.supported == false {
            return .unavailable(title: "Not supported on this PC",
                                message: "Remote desktop works with Windows PCs for now.")
        }
        if i.enabled != true {
            return .unavailable(title: "Remote desktop is off",
                                message: "Turn it on at the PC: Aigo → Settings → Remote desktop. For safety it can only be switched on at the PC itself, not from this iPhone.")
        }
        return nil
    }

    private func connect() {
        guard let client = client else { return }
        phase = .connecting(nil)
        let s = LiveSocket(client: client, path: "/api/v1/desktop/stream")
        socket = s
        s.onState = { [weak self] state in
            self?.socketState(state)
        }
        s.onMessage = { [weak self] data in
            self?.handleText(data)
        }
        s.onBinary = { [weak self] data in
            self?.handleJPEG(data)
        }
        s.start()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func socketState(_ state: LiveSocket.State) {
        switch state {
        case .connecting:
            if phase != .live { phase = .connecting(nil) }
        case .open:
            phase = .live
            hostError = nil
            sendConfig()
        case .closed(let problem):
            buttonsDown.removeAll()
            phase = .connecting(problem.message)
            // A refused upgrade (403/501) looks like a dropped link: ask the
            // PC why, and stop retrying if remote desktop is off.
            Task { await recheckInfo() }
        }
    }

    private func recheckInfo() async {
        guard let client = client,
              let i = try? await client.get("/api/v1/desktop/info", as: DesktopInfo.self) else { return }
        guard running, self.client === client else { return }
        info = i
        if let bad = DesktopModel.unavailability(i) {
            socket?.stop()
            socket = nil
            phase = bad
        }
    }

    private func tick() {
        fps = frames
        kbps = bytes / 1024
        frames = 0
        bytes = 0
        socket?.ping { [weak self] rtt in
            guard let self = self else { return }
            self.rttMs = rtt.map { Int(($0 * 1000).rounded()) }
        }
    }

    private struct Message: Decodable {
        var type: String?
        var w: Int?
        var h: Int?
        var srcW: Int?
        var srcH: Int?
        var error: String?
        // info / control (API §7d)
        var monitors: [DesktopMonitor]?
        var monitor: Int?
        var control: DesktopControl?
        var allowed: Bool?
        var reason: String?
        var maxFps: Int?
        // cursor
        var x: Double?
        var y: Double?
        var onMonitor: Bool?
        var visible: Bool?
    }

    private func applyControl(_ c: DesktopControl) {
        if controlAllowed != c.allowed { controlAllowed = c.allowed }
        let r = c.allowed ? nil : c.reason
        if controlReason != r { controlReason = r }
        if !c.allowed && control { control = false }
    }

    private func handleText(_ data: Data) {
        guard let m = try? JSONDecoder().decode(Message.self, from: data) else { return }
        switch m.type {
        case "frame":
            if let w = m.srcW, let h = m.srcH, w > 0, h > 0 {
                let s = CGSize(width: w, height: h)
                if s != sourceSize { sourceSize = s }
            }
            if let w = m.w, let h = m.h, w > 0, h > 0 {
                let s = CGSize(width: w, height: h)
                if s != frameSize { frameSize = s }
            }
        case "info":
            var i = info ?? DesktopInfo()
            if let list = m.monitors { i.monitors = list }
            if let f = m.maxFps { i.maxFps = f }
            if let c = m.control { i.control = c; applyControl(c) }
            if i != info { info = i }
            if let sel = m.monitor, sel != monitor {
                // The host's choice (e.g. fell back to the primary): adopt it without echoing.
                applyingHost = true
                monitor = sel
                applyingHost = false
            }
        case "control":
            if let a = m.allowed { applyControl(DesktopControl(allowed: a, reason: m.reason)) }
        case "cursor":
            if let x = m.x, let y = m.y {
                let p = CGPoint(x: x, y: y)
                hostCursor = p
                onCursor?(p, (m.onMonitor ?? true) && (m.visible ?? true))
            }
        case "error":
            hostError = m.error ?? "The PC could not capture its screen."
        default:
            break
        }
    }

    /// Decodes off the main thread; while one decode runs only the newest
    /// frame waits, older ones are dropped.
    private func handleJPEG(_ data: Data) {
        frames += 1
        bytes += data.count
        if decoding {
            pendingJPEG = data
            return
        }
        decode(data)
    }

    private func decode(_ data: Data) {
        decoding = true
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)?.preparingForDisplay()
            }.value
            guard let self = self else { return }
            if let image = image {
                if !self.hasFrame { self.hasFrame = true }
                if self.hostError != nil { self.hostError = nil }
                self.onFrame?(image)
            }
            self.decoding = false
            if let next = self.pendingJPEG {
                self.pendingJPEG = nil
                self.decode(next)
            }
        }
    }

    // MARK: - Settings

    var fpsChoices: [Int] {
        let maxFps = info?.maxFps ?? 8
        let list = [2, 5, 8, 12, 15, 20, 30].filter { $0 <= maxFps }
        return list.isEmpty ? [maxFps] : list
    }

    var monitors: [DesktopMonitor] { info?.monitors ?? [] }

    private func sendConfig() {
        guard let s = socket, s.isOpen else { return }
        var cfg: [String: Any] = ["type": "config", "fps": targetFps, "quality": quality, "maxWidth": maxWidth]
        if !monitors.isEmpty { cfg["monitor"] = monitor }
        s.send(cfg)
    }

    // MARK: - Input (normalized 0…1 coordinates of the streamed screen)

    var canSend: Bool { control && controlAllowed && phase == .live }

    private func send(_ o: [String: Any]) {
        guard canSend, let s = socket, s.isOpen else { return }
        s.send(o)
    }

    func move(_ p: CGPoint, force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastMove) < 0.03 { return }
        lastMove = now
        lastPoint = p
        send(["type": "move", "x": p.x, "y": p.y])
    }

    func button(_ b: Int, down: Bool, at p: CGPoint) {
        guard canSend else { return }
        if down { buttonsDown.insert(b) } else { buttonsDown.remove(b) }
        lastPoint = p
        send(["type": down ? "down" : "up", "button": b, "x": p.x, "y": p.y])
    }

    func click(_ b: Int, at p: CGPoint) {
        guard canSend else { return }
        move(p, force: true)
        button(b, down: true, at: p)
        button(b, down: false, at: p)
        releaseLatched()
    }

    /// Positive = scroll up (Windows WHEEL_DELTA is 120 per notch).
    func wheel(_ delta: Int, at p: CGPoint) {
        guard delta != 0 else { return }
        send(["type": "wheel", "delta": delta, "x": p.x, "y": p.y])
    }

    private func key(code: String, key: String, down: Bool) {
        send(["type": "key", "code": code, "key": key, "down": down])
    }

    /// Presses and releases one key, with any latched modifiers held.
    func press(code: String, key k: String) {
        guard canSend else { return }
        Haptics.selection()
        key(code: code, key: k, down: true)
        key(code: code, key: k, down: false)
        releaseLatched()
    }

    /// Typed text. With a modifier latched, a single character goes as a key
    /// (Ctrl+C) instead of Unicode text.
    func typeText(_ text: String) {
        guard canSend, !text.isEmpty else { return }
        if text == "\n" {
            press(code: "Enter", key: "Enter")
            return
        }
        if text == "\t" {
            press(code: "Tab", key: "Tab")
            return
        }
        if !latched.isEmpty, text.count == 1, let ch = text.first {
            let (code, k) = DesktopModel.keyFor(ch)
            press(code: code, key: k)
            return
        }
        send(["type": "text", "text": text])
    }

    static func keyFor(_ ch: Character) -> (String, String) {
        let s = String(ch)
        if ch.isASCII, ch.isLetter { return ("Key" + s.uppercased(), s.lowercased()) }
        if ch.isASCII, ch.isNumber { return ("Digit" + s, s) }
        if ch == " " { return ("Space", " ") }
        return ("", s)
    }

    /// Ctrl / Alt / Win: tap to hold for the next key. Tapping a held one
    /// again with nothing in between presses it alone (Win opens Start).
    func toggle(_ m: DesktopModifier) {
        guard canSend else { return }
        Haptics.selection()
        if latched.contains(m) {
            latched.remove(m)
            key(code: m.code, key: m.key, down: false)
        } else {
            latched.insert(m)
            key(code: m.code, key: m.key, down: true)
        }
    }

    private func releaseLatched() {
        for m in latched {
            key(code: m.code, key: m.key, down: false)
        }
        latched.removeAll()
    }

    /// Never leave a button or modifier stuck on the PC.
    private func releaseAll() {
        guard let s = socket, s.isOpen else {
            buttonsDown.removeAll()
            latched.removeAll()
            return
        }
        for b in buttonsDown {
            s.send(["type": "up", "button": b, "x": lastPoint.x, "y": lastPoint.y])
        }
        buttonsDown.removeAll()
        for m in latched {
            s.send(["type": "key", "code": m.code, "key": m.key, "down": false])
        }
        latched.removeAll()
    }
}
