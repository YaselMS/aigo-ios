import SwiftUI
import UIKit
import SwiftTerm

/// Grid size in character cells.
struct GridSize: Equatable {
    var cols: Int
    var rows: Int
}

/// Font names of the terminal.
enum TerminalScreen {
    /// The chosen UI font, or JetBrains Mono when that font lacks terminal glyphs.
    static var fontName: String {
        AigoAppearance.current.family.terminalFamily.postScriptName(.regular)
    }

    static var boldFontName: String {
        AigoAppearance.current.family.terminalFamily.postScriptName(.bold)
    }
}

/// Aigo's terminal colours (graphite background, lime cursor) and ANSI palette.
enum TerminalPalette {
    static let background = rgb(0x08090A)
    static let foreground = rgb(0xE6E7E3)
    static let lime = rgb(0xC6F432)

    /// ANSI 0–15; SwiftTerm derives the 256-colour cube from these.
    static let ansi: [UInt32] = [0x1D1F21, 0xE0605A, 0x9FCB4C, 0xE5C24F, 0x6CA3E8, 0xC27FD6, 0x5CC3C3, 0xC5C8C6,
                                 0x6E7378, 0xFF7A6E, 0xC6F432, 0xFFD866, 0x8FB8F0, 0xE09AF0, 0x8FE0E0, 0xFFFFFF]

    static var swiftTermColors: [SwiftTerm.Color] {
        ansi.map { v in
            SwiftTerm.Color(red8: UInt16((v >> 16) & 0xFF), green8: UInt16((v >> 8) & 0xFF), blue8: UInt16(v & 0xFF))
        }
    }

    static func rgb(_ v: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}

/// A key on the special-keys bar.
enum TerminalKey: Equatable {
    case esc, tab, enter, up, down, left, right
    case bytes([UInt8])
    case text(String)
}

/// SwiftTerm's UIKit terminal with Aigo's input routing.
///
/// Keystrokes, paste and mouse events are user input (they go to the socket
/// and claim the PTY size). The emulator's own answers to queries (focus
/// in/out, cursor position, device attributes, OSC replies) are reports: the
/// model drops them during a snapshot and sends the rest as `report` messages
/// (REST on older hosts), which never claim the size (API.md §6, "Terminal
/// reports are not typing").
final class AigoTermView: TerminalView {
    var onReport: ((ArraySlice<UInt8>) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onMouseModeChange: (() -> Void)?

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if AigoTermView.isMouseReport(data) {
            super.send(source: source, data: data)
        } else {
            onReport?(data)
        }
    }

    /// `ESC [ <` (SGR) or `ESC [ M` (X10/UTF-8) mouse reports come from a touch.
    static func isMouseReport(_ d: ArraySlice<UInt8>) -> Bool {
        guard d.count >= 3 else { return false }
        let i = d.startIndex
        return d[i] == 0x1B && d[i + 1] == 0x5B && (d[i + 2] == 0x3C || d[i + 2] == 0x4D)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Deferred: this can run inside a SwiftUI update.
        if ok { let cb = onFocusChange; DispatchQueue.main.async { cb?(true) } }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let was = isFirstResponder
        let ok = super.resignFirstResponder()
        if was && ok { let cb = onFocusChange; DispatchQueue.main.async { cb?(false) } }
        return ok
    }

    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        onMouseModeChange?()
    }
}

/// The one terminal view for live, read-only and exited sessions: SwiftTerm's
/// `TerminalView`, kept at exactly the PTY's cols×rows from the host's `size`
/// message.
///
/// The terminal's frame is cols×rows cells at the display font, so SwiftTerm's
/// own layout keeps that grid. The display font is the chosen text size,
/// shrunk so the PTY's width and height fit ("PC size"); pinch zooms on top of
/// that (then it pans sideways). With Fit to phone, pinch changes the text
/// size itself, and the grid that fits at that size is reported through
/// `onPhoneGrid` for the model to send as an interactive `resize`.
///
/// Touch: one finger scrolls the scrollback, selects (long press / double
/// tap) or, when the program turned mouse reporting on, taps and drags as the
/// mouse (the first tap on an unfocused terminal both focuses and clicks).
/// Two fingers scroll: wheel events with mouse reporting, arrow keys on the
/// alternate screen, otherwise the scrollback.
final class TerminalSurfaceView: UIView, TerminalViewDelegate, UIGestureRecognizerDelegate {
    let term: AigoTermView
    private let pan = UIScrollView()

    /// Keystrokes, paste, mouse: bytes for the PTY.
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    /// The emulator's own replies to queries.
    var onReport: ((ArraySlice<UInt8>) -> Void)?
    /// The grid that fits this view at the chosen text size.
    var onPhoneGrid: ((GridSize) -> Void)?
    var onKeyboardChange: ((Bool) -> Void)?
    /// Ctrl / Alt latch state changed (they reset after the next key).
    var onModifiersChange: (() -> Void)?
    /// Pinch picked a new text size (Fit to phone).
    var onTextSize: ((CGFloat) -> Void)?

    /// Running session: keyboard input allowed.
    var acceptsInput = false {
        didSet {
            guard acceptsInput != oldValue else { return }
            // Read-only: the view can still take focus (selection menu) but shows no keyboard.
            term.inputView = acceptsInput ? nil : UIView(frame: .zero)
            if !acceptsInput && term.isFirstResponder { _ = term.resignFirstResponder() }
            if term.isFirstResponder { term.reloadInputViews() }
        }
    }
    /// Fit to phone: pinch changes the text size. Otherwise it zooms.
    var pinchChangesTextSize = false
    var userFontSize: CGFloat = 12 {
        didSet { if userFontSize != oldValue { relayout() } }
    }
    var fontName = "JetBrainsMono-Regular" {
        didSet { if fontName != oldValue { relayout() } }
    }
    var boldFontName = "JetBrainsMono-Bold" {
        didSet { if boldFontName != oldValue { relayout() } }
    }

    /// The PTY size from the latest `size` (nil: not known yet).
    private(set) var pty: GridSize?
    /// Pinch zoom on top of the fitted size (PC size).
    private(set) var zoom: CGFloat = 1
    private var shownFont: (name: String, size: CGFloat)?
    private var cell = CGSize(width: 7, height: 14)
    private var reportedGrid: GridSize?
    private var pinching = false
    private var wheelRemainder: CGFloat = 0
    /// Sends the click of a tap that only focused the terminal (SwiftTerm's
    /// own single tap just shows the keyboard when it is not focused).
    private var focusTap: UITapGestureRecognizer!
    private var focusedAtTouch = true
    private var observers: [NSObjectProtocol] = []
    private let padding: CGFloat = 4
    static let minFontSize: CGFloat = 4

    override init(frame: CGRect) {
        term = AigoTermView(frame: .zero)
        super.init(frame: frame)
        backgroundColor = TerminalPalette.background
        clipsToBounds = true

        pan.backgroundColor = TerminalPalette.background
        pan.contentInsetAdjustmentBehavior = .never
        pan.showsVerticalScrollIndicator = false
        pan.alwaysBounceVertical = false
        pan.alwaysBounceHorizontal = false
        pan.scrollsToTop = false
        pan.panGestureRecognizer.maximumNumberOfTouches = 1
        addSubview(pan)
        pan.addSubview(term)

        term.terminalDelegate = self
        term.inputAccessoryView = nil  // Aigo's own key bar sits above the keyboard.
        term.inputView = UIView(frame: .zero)  // read-only until `acceptsInput`
        term.keyboardAppearance = .dark
        term.optionAsMetaKey = true
        // On only while the program asked for the mouse: SwiftTerm clears the
        // selection on every output while it is on.
        term.allowMouseReporting = false
        term.bellStyle = .none
        term.customBlockGlyphs = true  // box drawing, blocks and powerline drawn exactly
        term.nativeForegroundColor = TerminalPalette.foreground
        term.nativeBackgroundColor = TerminalPalette.background
        term.layer.backgroundColor = TerminalPalette.background.cgColor
        term.installColors(TerminalPalette.swiftTermColors)
        term.caretColor = TerminalPalette.lime
        term.caretTextColor = TerminalPalette.background
        term.selectedTextBackgroundColor = TerminalPalette.rgb(0xC6F432, alpha: 0.35)
        term.changeScrollback(5000)
        term.panGestureRecognizer.maximumNumberOfTouches = 1
        term.indicatorStyle = .white
        term.scrollsToTop = false
        term.onReport = { [weak self] d in self?.onReport?(d) }
        term.onFocusChange = { [weak self] on in self?.onKeyboardChange?(on) }
        term.onMouseModeChange = { [weak self] in self?.mouseModeChanged() }
        applyFont(size: userFontSize)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        wheel.delegate = self
        addGestureRecognizer(wheel)

        focusTap = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
        focusTap.delegate = self
        focusTap.cancelsTouchesInView = false
        // Same timing as SwiftTerm's single tap (after a double tap has failed).
        for g in term.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { focusTap.require(toFail: t) }
        }
        term.addGestureRecognizer(focusTap)

        let nc = NotificationCenter.default
        for name in [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset] {
            observers.append(nc.addObserver(forName: name, object: term, queue: .main) { [weak self] _ in
                self?.onModifiersChange?()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Stream

    func feed(_ data: Data) {
        term.feed(byteArray: ArraySlice([UInt8](data)))
    }

    /// Sets the emulator to the PTY's size (before the snapshot that follows).
    func setPTY(_ g: GridSize) {
        pty = g
        relayout()
        ensureGrid(g)
    }

    /// Clears the screen and the scrollback (for text that is not a stream).
    func clear() {
        term.feed(text: "\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[3J")
    }

    // MARK: - Input

    func setKeyboard(_ on: Bool) {
        if on && acceptsInput && !term.isFirstResponder {
            _ = term.becomeFirstResponder()
        } else if !on && term.isFirstResponder {
            _ = term.resignFirstResponder()
        }
    }

    var ctrlLatched: Bool {
        get { term.controlModifier }
        set { term.controlModifier = newValue; onModifiersChange?() }
    }

    var altLatched: Bool {
        get { term.metaModifier }
        set { term.metaModifier = newValue; onModifiersChange?() }
    }

    /// A key from the bar, combined with the latched Ctrl / Alt and the
    /// program's cursor-key mode.
    func press(_ key: TerminalKey) {
        let t = term.getTerminal()
        let ctrl = term.controlModifier, alt = term.metaModifier
        var out: [UInt8]
        switch key {
        case .up, .down, .left, .right:
            let letter: UInt8 = key == .up ? 0x41 : key == .down ? 0x42 : key == .right ? 0x43 : 0x44
            let mod = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0)
            if mod > 1 {
                out = Array("\u{1B}[1;\(mod)".utf8) + [letter]
            } else {
                out = [0x1B, t.applicationCursor ? 0x4F : 0x5B, letter]
            }
        case .esc:
            out = [0x1B]
        case .tab:
            out = alt ? [0x1B, 0x09] : [0x09]
        case .enter:
            out = alt ? [0x1B] + term.returnByteSequence : term.returnByteSequence
        case .bytes(let b):
            out = b
        case .text(let s):
            out = Array(s.utf8)
            if ctrl, s.count == 1, let u = s.lowercased().unicodeScalars.first {
                if u.value >= 0x61 && u.value <= 0x7A {
                    out = [UInt8(u.value - 0x60)]
                } else if s == " " || s == "2" || s == "@" {
                    out = [0]
                }
            }
            if alt { out = [0x1B] + out }
        }
        if ctrl { term.controlModifier = false }
        if alt { term.metaModifier = false }
        onModifiersChange?()
        term.send(out)
    }

    func paste() {
        term.paste(nil)
    }

    // MARK: - Text

    func selectedText() -> String? {
        term.getSelection()
    }

    func text(includeHistory: Bool) -> String {
        let t = term.getTerminal()
        var lines = String(decoding: t.getBufferAsData(), as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if !includeHistory { lines = Array(lines.suffix(t.rows)) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if pan.frame != bounds { pan.frame = bounds }
        relayout()
    }

    /// SwiftTerm's cell size for a font (same formula as SwiftTerm's
    /// `computeFontDimensions`, so the frame below gives exactly cols×rows).
    private static func cellSize(_ font: UIFont) -> CGSize {
        let w = ("W" as NSString).size(withAttributes: [.font: font]).width
        let h = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let s = UIScreen.main.scale
        return CGSize(width: max(1, (w * s).rounded() / s), height: max(1, min(ceil(h * s) / s, 8192)))
    }

    private func font(_ name: String, _ size: CGFloat, bold: Bool) -> UIFont {
        UIFont(name: name, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private func relayout() {
        guard !pinching else { return }
        let availW = bounds.width - 2 * padding, availH = bounds.height - 2 * padding
        guard availW > 60, availH > 40 else { return }
        let user = Self.cellSize(font(fontName, userFontSize, bold: false))
        let phone = GridSize(cols: max(20, Int(availW / user.width)), rows: max(5, Int(availH / user.height)))
        if phone != reportedGrid {
            reportedGrid = phone
            onPhoneGrid?(phone)
        }
        let grid = pty ?? phone
        // The chosen size, shrunk so the PTY width fits, times the pinch zoom,
        // never taller than the view.
        var size = userFontSize
        size = min(size, userFontSize * availW / (CGFloat(grid.cols) * user.width))
        size *= zoom
        size = min(size, userFontSize * availH / (CGFloat(grid.rows) * user.height))
        size = max(Self.minFontSize, floor(size * 4) / 4)
        var c = Self.cellSize(font(fontName, size, bold: false))
        while size > Self.minFontSize,
              CGFloat(grid.rows) * c.height > availH || (zoom == 1 && CGFloat(grid.cols) * c.width > availW) {
            size = max(Self.minFontSize, size - 0.25)
            c = Self.cellSize(font(fontName, size, bold: false))
        }
        let fontChanged = shownFont?.name != fontName || shownFont?.size != size
        if fontChanged {
            // With a zero frame SwiftTerm changes the font without resizing
            // (or soft-resetting) the terminal; the frame below sets the grid.
            term.transform = .identity
            term.frame = .zero
            term.layoutIfNeeded()
            applyFont(size: size)
        }
        cell = c
        // Half a cell of slack so rounding never loses a column or row.
        let w = CGFloat(grid.cols) * c.width + c.width / 2
        let h = CGFloat(grid.rows) * c.height + c.height / 2
        let target = CGRect(x: padding, y: padding, width: w, height: h)
        if term.frame != target {
            term.frame = target
            term.layoutIfNeeded()
        }
        if fontChanged {
            // Same grid, new cell size: let SwiftTerm recompute its scroll content.
            term.sizeChanged(source: term.getTerminal())
        }
        let content = CGSize(width: max(bounds.width, w + 2 * padding), height: max(bounds.height, h + 2 * padding))
        if pan.contentSize != content { pan.contentSize = content }
        if pty != nil { ensureGrid(grid) }
    }

    private func applyFont(size: CGFloat) {
        let normal = font(fontName, size, bold: false)
        let bold = font(boldFontName, size, bold: true)
        term.setFonts(normal: normal, bold: bold, italic: normal, boldItalic: bold)
        shownFont = (fontName, size)
        cell = Self.cellSize(normal)
    }

    /// Safety net: the terminal must be exactly the PTY size.
    private func ensureGrid(_ g: GridSize) {
        let t = term.getTerminal()
        if t.cols != g.cols || t.rows != g.rows {
            t.resize(cols: g.cols, rows: g.rows)
            term.sizeChanged(source: t)
        }
    }

    /// SwiftTerm adds a mouse pan when a program turns mouse reporting on;
    /// keep it to one finger so two fingers stay free for wheel and pinch.
    private func mouseModeChanged() {
        term.allowMouseReporting = term.getTerminal().mouseMode != .off
        for g in term.gestureRecognizers ?? [] {
            if let p = g as? UIPanGestureRecognizer { p.maximumNumberOfTouches = 1 }
        }
    }

    // MARK: - First tap

    /// SwiftTerm's single tap on an unfocused terminal only focuses it, so the
    /// first tap into a TUI with mouse reporting was lost. Send that click here
    /// (SwiftTerm still does the focusing; it sends clicks only when focused).
    @objc private func focusTapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, !focusedAtTouch, acceptsInput, term.allowMouseReporting else { return }
        guard !g.modifierFlags.contains(.shift) else { return }
        let t = term.getTerminal()
        // SwiftTerm's MouseMode.sendButtonPress() / sendButtonRelease() (internal there).
        guard t.mouseMode == .vt200 || t.mouseMode == .buttonEventTracking || t.mouseMode == .anyEvent else { return }
        let p = g.location(in: term)
        let col = min(max(0, Int(p.x / cell.width)), t.cols - 1)
        let y = p.y - term.contentOffset.y
        let row = min(max(0, Int(y / cell.height)), t.rows - 1)
        for release in [false, true] {
            let flags = t.encodeButton(button: 0, release: release, shift: false, meta: false, control: false)
            t.sendEvent(buttonFlags: flags, x: col, y: row, pixelX: Int(p.x), pixelY: Int(y))
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === focusTap { focusedAtTouch = term.isFirstResponder }
        return true
    }

    // MARK: - Pinch (text size or zoom)

    func resetZoom() {
        guard zoom != 1 else { return }
        zoom = 1
        relayout()
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinching = true
        case .changed:
            let s = min(max(g.scale, 0.3), 4)
            term.transform = CGAffineTransform(scaleX: s, y: s)
        case .ended:
            term.transform = .identity
            pinching = false
            let s = g.scale
            if pinchChangesTextSize {
                let size = min(max((userFontSize * s * 2).rounded() / 2, 6), 24)
                if size != userFontSize {
                    userFontSize = size
                    onTextSize?(size)
                }
            } else {
                zoom = min(max(zoom * s, 1), 8)
            }
            relayout()
        default:
            term.transform = .identity
            pinching = false
            relayout()
        }
    }

    // MARK: - Two-finger scroll

    @objc private func wheeled(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            wheelRemainder = 0
        case .changed:
            guard !pinching || abs(g.translation(in: self).y) > cell.height * 2 else { return }
            wheelRemainder += g.translation(in: self).y
            g.setTranslation(.zero, in: self)
            let step = max(cell.height, 8)
            while abs(wheelRemainder) >= step {
                let up = wheelRemainder > 0  // fingers down: show earlier lines
                wheelRemainder += up ? -step : step
                wheel(up: up, at: g.location(in: term))
            }
        default:
            wheelRemainder = 0
        }
    }

    private func wheel(up: Bool, at p: CGPoint) {
        let t = term.getTerminal()
        if t.mouseMode != .off && term.allowMouseReporting {
            let col = min(max(0, Int(p.x / cell.width)), t.cols - 1)
            let y = p.y - term.contentOffset.y
            let row = min(max(0, Int(y / cell.height)), t.rows - 1)
            let flags = t.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            t.sendEvent(buttonFlags: flags, x: col, y: row, pixelX: Int(p.x), pixelY: Int(y))
        } else if t.isCurrentBufferAlternate {
            if t.alternateScrollMode {
                term.send([0x1B, t.applicationCursor ? 0x4F : 0x5B, up ? 0x41 : 0x42])
            }
        } else if up {
            term.scrollUp(lines: 1)
        } else {
            term.scrollDown(lines: 1)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger scroll run together; whichever moves more wins.
        // The first-tap click runs alongside SwiftTerm's own tap (which focuses).
        g === focusTap || other === focusTap || (g.view === self && other.view === self)
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
        }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// Keystrokes, paste and mouse events from SwiftTerm.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
    }
}

/// SwiftUI wrapper: the model owns the view, so the terminal state survives
/// tab switches.
struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var model: TerminalModel
    @Binding var fontSize: Double
    /// Running session: keyboard input allowed.
    var interactive: Bool

    func makeUIView(context: Context) -> TerminalSurfaceView {
        let v = model.surface
        configure(v)
        return v
    }

    func updateUIView(_ v: TerminalSurfaceView, context: Context) {
        configure(v)
    }

    private func configure(_ v: TerminalSurfaceView) {
        v.fontName = TerminalScreen.fontName
        v.boldFontName = TerminalScreen.boldFontName
        v.userFontSize = CGFloat(fontSize)
        v.acceptsInput = interactive && !model.exited
        v.pinchChangesTextSize = model.choice == .phone && !model.exited
        let size = $fontSize
        v.onTextSize = { s in size.wrappedValue = Double(s) }
    }
}
