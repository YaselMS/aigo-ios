import SwiftUI
import UIKit

/// Grid size in character cells.
struct GridSize: Equatable {
    var cols: Int
    var rows: Int
}

/// Font metrics of one terminal font size.
struct TerminalMetrics {
    let font: UIFont
    let bold: UIFont
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    static func make(name: String, boldName: String, size: CGFloat) -> TerminalMetrics {
        let font = UIFont(name: name, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont(name: boldName, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        return TerminalMetrics(font: font, bold: bold, cellWidth: max(1, w), lineHeight: max(1, ceil(font.lineHeight)))
    }
}

/// Draws a `VTEmulator`: scrollback above the screen, scrolls both ways,
/// follows new output only while the user is at the bottom.
///
/// The emulator always keeps the PTY's size (`cols`×`rows` from the host's
/// `size` message). When that is wider than the view at the chosen text size,
/// the font is scaled down to fit the width (not below `minFontSize`; past
/// that it scrolls horizontally). The grid that would fit at the chosen text
/// size is reported separately through `onPhoneGrid` ("Fit to phone").
final class TerminalCanvasView: UIView, UIScrollViewDelegate {
    var emulator: VTEmulator {
        didSet { contentChanged() }
    }
    var onPhoneGrid: ((GridSize) -> Void)?
    var onTap: (() -> Void)?

    /// The text size the user picked.
    var userFontSize: CGFloat = 12 {
        didSet { if userFontSize != oldValue { fontChanged() } }
    }
    var fontName = "JetBrainsMono-Regular" {
        didSet { if fontName != oldValue { fontChanged() } }
    }
    var boldFontName = "JetBrainsMono-Bold" {
        didSet { if boldFontName != oldValue { fontChanged() } }
    }
    /// Draw the cursor (live, running session).
    var showsCursor = true {
        didSet { if showsCursor != oldValue { canvas.setNeedsDisplay() } }
    }
    /// While a snapshot is being written nothing is redrawn.
    var holdsUpdates = false {
        didSet { if !holdsUpdates && oldValue { contentChanged() } }
    }

    static let minFontSize: CGFloat = 5
    let padding: CGFloat = 8

    private let scroll = UIScrollView()
    private let canvas = TerminalDrawView()
    private var userMetrics: TerminalMetrics
    private(set) var metrics: TerminalMetrics
    private var followBottom = true
    private var lastDropped = 0
    private var lastEpoch = 0
    private var lastLineCount = 0
    private var lastGrid: GridSize?
    private var lastBounds: CGSize = .zero
    private var reportedGrid: GridSize?

    init(emulator: VTEmulator) {
        self.emulator = emulator
        let m = TerminalMetrics.make(name: "JetBrainsMono-Regular", boldName: "JetBrainsMono-Bold", size: 12)
        userMetrics = m
        metrics = m
        super.init(frame: .zero)
        backgroundColor = TerminalColors.background
        scroll.backgroundColor = TerminalColors.background
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.automaticallyAdjustsScrollIndicatorInsets = false
        scroll.alwaysBounceVertical = true
        scroll.indicatorStyle = .white
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = self
        scroll.scrollsToTop = false
        addSubview(scroll)
        canvas.owner = self
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = TerminalColors.background
        canvas.contentMode = .redraw
        scroll.addSubview(canvas)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityTraits = [.staticText]
        accessibilityLabel = "Terminal"
        lastDropped = emulator.droppedLines
        lastEpoch = emulator.historyEpoch
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var accessibilityValue: String? {
        get { emulator.text(includeHistory: false) }
        set {}
    }

    @objc private func tapped() {
        onTap?()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroll.frame != bounds {
            let wasAtBottom = followBottom
            scroll.frame = bounds
            reportPhoneGrid()
            relayout(keepBottom: wasAtBottom)
        }
    }

    private func fontChanged() {
        userMetrics = TerminalMetrics.make(name: fontName, boldName: boldFontName, size: userFontSize)
        reportedGrid = nil
        reportPhoneGrid()
        relayout(keepBottom: followBottom, forceMetrics: true)
    }

    /// The grid that fits the view at the user's text size.
    private func reportPhoneGrid() {
        let w = bounds.width - 2 * padding, h = bounds.height - 2 * padding
        guard w > 40, h > 40 else { return }
        let g = GridSize(cols: max(20, Int(w / userMetrics.cellWidth)), rows: max(5, Int(h / userMetrics.lineHeight)))
        if g != reportedGrid {
            reportedGrid = g
            onPhoneGrid?(g)
        }
    }

    /// Display metrics: the user's size, shrunk so the PTY width fits.
    private func displayMetrics() -> TerminalMetrics {
        let avail = bounds.width - 2 * padding
        let needed = CGFloat(emulator.cols) * userMetrics.cellWidth
        guard avail > 40, needed > avail else { return userMetrics }
        var size = userFontSize * avail / needed
        size = max(TerminalCanvasView.minFontSize, floor(size * 4) / 4)
        if abs(size - metrics.font.pointSize) < 0.01 && metrics.font.fontName == userMetrics.font.fontName {
            return metrics
        }
        var m = TerminalMetrics.make(name: fontName, boldName: boldFontName, size: size)
        // Rounding can leave the grid a hair too wide: step down until it fits.
        while CGFloat(emulator.cols) * m.cellWidth > avail && size > TerminalCanvasView.minFontSize {
            size = max(TerminalCanvasView.minFontSize, size - 0.25)
            m = TerminalMetrics.make(name: fontName, boldName: boldFontName, size: size)
        }
        return m
    }

    private func relayout(keepBottom: Bool, forceMetrics: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let grid = GridSize(cols: emulator.cols, rows: emulator.rows)
        let oldLine = metrics.lineHeight
        let topLine = (scroll.contentOffset.y - padding) / max(1, oldLine)
        if forceMetrics || grid != lastGrid || bounds.size != lastBounds {
            metrics = displayMetrics()
            lastGrid = grid
            lastBounds = bounds.size
        }
        let contentW = max(bounds.width, CGFloat(emulator.cols) * metrics.cellWidth + 2 * padding)
        let contentH = max(bounds.height, CGFloat(emulator.lineCount) * metrics.lineHeight + 2 * padding)
        let size = CGSize(width: ceil(contentW), height: ceil(contentH))
        if scroll.contentSize != size {
            scroll.contentSize = size
        }
        var offset = scroll.contentOffset
        let maxY = max(0, size.height - bounds.height)
        let maxX = max(0, size.width - bounds.width)
        if keepBottom {
            offset.y = maxY
        } else if oldLine != metrics.lineHeight {
            offset.y = padding + topLine * metrics.lineHeight
        }
        offset.y = min(max(0, offset.y), maxY)
        offset.x = min(max(0, offset.x), maxX)
        if offset != scroll.contentOffset {
            scroll.setContentOffset(offset, animated: false)
        }
        followBottom = keepBottom || offset.y >= maxY - 1
        placeCanvas()
    }

    /// New output or a new snapshot.
    func contentChanged() {
        guard !holdsUpdates, bounds.width > 0 else { return }
        let dropped = emulator.droppedLines - lastDropped
        let epochChanged = emulator.historyEpoch != lastEpoch
        let oldMaxY = max(0, scroll.contentSize.height - bounds.height)
        let distanceFromBottom = oldMaxY - scroll.contentOffset.y
        lastDropped = emulator.droppedLines
        lastEpoch = emulator.historyEpoch
        lastLineCount = emulator.lineCount
        let follow = followBottom
        let userScrolling = scroll.isTracking || scroll.isDecelerating
        relayout(keepBottom: follow && !userScrolling)
        if !follow && !userScrolling {
            var offset = scroll.contentOffset
            let maxY = max(0, scroll.contentSize.height - bounds.height)
            if epochChanged {
                // Scrollback was rebuilt (snapshot): keep the distance from the bottom.
                offset.y = maxY - distanceFromBottom
            } else if dropped > 0 {
                // Old lines fell off the top: keep the same lines in view.
                offset.y -= CGFloat(dropped) * metrics.lineHeight
            }
            offset.y = min(max(0, offset.y), maxY)
            if offset != scroll.contentOffset {
                scroll.setContentOffset(offset, animated: false)
            }
            placeCanvas()
        }
        canvas.setNeedsDisplay()
    }

    func scrollToBottom() {
        followBottom = true
        relayout(keepBottom: true)
        canvas.setNeedsDisplay()
    }

    private func placeCanvas() {
        let o = scroll.contentOffset
        let f = CGRect(x: max(0, o.x), y: max(0, o.y), width: bounds.width, height: bounds.height)
        if canvas.frame != f {
            canvas.frame = f
        }
        canvas.setNeedsDisplay()
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        placeCanvas()
        if scrollView.isTracking || scrollView.isDecelerating || scrollView.isDragging {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            followBottom = scrollView.contentOffset.y >= maxY - metrics.lineHeight * 0.5
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        followBottom = scrollView.contentOffset.y >= maxY - metrics.lineHeight * 0.5
        // Output that arrived while the user was flicking.
        contentChanged()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollViewDidEndDecelerating(scrollView) }
    }

    // MARK: - Drawing (called by the canvas)

    fileprivate func draw(in ctx: CGContext, rect: CGRect, origin: CGPoint) {
        let m = metrics
        let lh = m.lineHeight
        let first = max(0, Int(floor((origin.y + rect.minY - padding) / lh)))
        let last = min(emulator.lineCount - 1, Int(ceil((origin.y + rect.maxY - padding) / lh)))
        guard first <= last else { return }
        let firstCol = max(0, Int(floor((origin.x + rect.minX - padding) / m.cellWidth)))
        let lastCol = Int(ceil((origin.x + rect.maxX - padding) / m.cellWidth))
        let cursorLine = showsCursor && emulator.cursorVisible ? emulator.cursorLineIndex : -1
        for i in first...last {
            guard let line = emulator.line(i) else { continue }
            let y = padding + CGFloat(i) * lh - origin.y
            drawLine(line, y: y, metrics: m, ctx: ctx, originX: origin.x, firstCol: firstCol, lastCol: lastCol)
            if i == cursorLine {
                let x = padding + CGFloat(emulator.cursorX) * m.cellWidth - origin.x
                ctx.setFillColor(TerminalColors.cursor.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: m.cellWidth, height: lh))
            }
        }
    }

    private func drawLine(_ line: VTLine, y: CGFloat, metrics m: TerminalMetrics, ctx: CGContext,
                          originX: CGFloat, firstCol: Int, lastCol: Int) {
        let cells = line.cells
        let end = min(cells.count, lastCol + 1)
        guard firstCol < end else { return }
        // Backgrounds.
        var col = firstCol
        while col < end {
            let c = cells[col]
            let bg = TerminalColors.background(of: c)
            guard let bgColor = bg else { col += 1; continue }
            var stop = col + 1
            while stop < end, TerminalColors.sameBackground(cells[stop], c) { stop += 1 }
            ctx.setFillColor(bgColor.cgColor)
            ctx.fill(CGRect(x: padding + CGFloat(col) * m.cellWidth - originX, y: y,
                            width: CGFloat(stop - col) * m.cellWidth, height: m.lineHeight))
            col = stop
        }
        // Text: runs of same-styled cells whose glyphs are in the terminal font
        // (drawn in one go); wide and fallback characters one by one at their cell.
        col = firstCol
        if col > 0, cells[col].width == 0 { col -= 1 }
        while col < end {
            let c = cells[col]
            if c.width == 0 || c.code == 0 || c.code == 32 || c.attr & VTAttr.invisible != 0 {
                if c.attr & (VTAttr.underline | VTAttr.strike) != 0, c.width != 0 {
                    decorate(c, x: padding + CGFloat(col) * m.cellWidth - originX, y: y, width: m.cellWidth, metrics: m, ctx: ctx)
                }
                col += 1
                continue
            }
            let simple = c.width == 1 && canvas.isNative(c.code, metrics: m)
            var stop = col + 1
            var scalars = String.UnicodeScalarView()
            scalars.append(Unicode.Scalar(c.code) ?? "?")
            if simple {
                while stop < end {
                    let n = cells[stop]
                    guard n.width == 1, n.fg == c.fg, n.bg == c.bg, n.attr == c.attr else { break }
                    if n.code == 0 || n.code == 32 {
                        scalars.append(" ")
                    } else if canvas.isNative(n.code, metrics: m) {
                        scalars.append(Unicode.Scalar(n.code) ?? "?")
                    } else {
                        break
                    }
                    stop += 1
                }
            }
            let x = padding + CGFloat(col) * m.cellWidth - originX
            let width = CGFloat(stop - col) * m.cellWidth * (c.width == 2 ? 2 : 1)
            let font = c.attr & VTAttr.bold != 0 ? m.bold : m.font
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TerminalColors.foreground(of: c)]
            if c.attr & VTAttr.italic != 0 { attrs[.obliqueness] = 0.15 }
            NSAttributedString(string: String(scalars), attributes: attrs)
                .draw(at: CGPoint(x: x, y: y + (m.lineHeight - font.lineHeight) / 2))
            if c.attr & (VTAttr.underline | VTAttr.strike) != 0 {
                decorate(c, x: x, y: y, width: width, metrics: m, ctx: ctx)
            }
            col = stop
        }
    }

    private func decorate(_ c: VTCell, x: CGFloat, y: CGFloat, width: CGFloat, metrics m: TerminalMetrics, ctx: CGContext) {
        ctx.setFillColor(TerminalColors.foreground(of: c).cgColor)
        let t = max(1, m.font.pointSize / 14)
        if c.attr & VTAttr.underline != 0 {
            ctx.fill(CGRect(x: x, y: y + m.lineHeight - t - 1, width: width, height: t))
        }
        if c.attr & VTAttr.strike != 0 {
            ctx.fill(CGRect(x: x, y: y + m.lineHeight / 2, width: width, height: t))
        }
    }
}

/// The visible window onto the scroll content; it moves with the scroll offset.
final class TerminalDrawView: UIView {
    weak var owner: TerminalCanvasView?
    private var nativeCache: [UInt32: Bool] = [:]
    private var cacheFont = ""

    override func draw(_ rect: CGRect) {
        guard let owner = owner, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(TerminalColors.background.cgColor)
        ctx.fill(rect)
        owner.draw(in: ctx, rect: rect, origin: frame.origin)
    }

    /// The character has a glyph in the terminal font itself (so it is one cell wide).
    func isNative(_ code: UInt32, metrics m: TerminalMetrics) -> Bool {
        if code < 0x7F { return true }
        if cacheFont != m.font.fontName {
            cacheFont = m.font.fontName
            nativeCache.removeAll()
        }
        if let v = nativeCache[code] { return v }
        var ok = false
        if let scalar = Unicode.Scalar(code) {
            let utf16 = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            ok = CTFontGetGlyphsForCharacters(m.font as CTFont, utf16, &glyphs, utf16.count) && glyphs.allSatisfy { $0 != 0 }
        }
        nativeCache[code] = ok
        return ok
    }
}

/// xterm palette and Aigo's default colours.
enum TerminalColors {
    static let background = UIColor(red: 0x08 / 255.0, green: 0x09 / 255.0, blue: 0x0A / 255.0, alpha: 1)
    static let foregroundDefault = UIColor(red: 0xE6 / 255.0, green: 0xE7 / 255.0, blue: 0xE3 / 255.0, alpha: 1)
    static let cursor = UIColor(red: 0xC6 / 255.0, green: 0xF4 / 255.0, blue: 0x32 / 255.0, alpha: 0.45)

    private static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let palette: [UIColor] = {
        let base: [UInt32] = [0x1D1F21, 0xE0605A, 0x9FCB4C, 0xE5C24F, 0x6CA3E8, 0xC27FD6, 0x5CC3C3, 0xC5C8C6,
                              0x6E7378, 0xFF7A6E, 0xC6F432, 0xFFD866, 0x8FB8F0, 0xE09AF0, 0x8FE0E0, 0xFFFFFF]
        var out = base.map(rgb)
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    out.append(rgb((steps[r] << 16) | (steps[g] << 8) | steps[b]))
                }
            }
        }
        for i in 0..<24 {
            let v = UInt32(8 + i * 10)
            out.append(rgb((v << 16) | (v << 8) | v))
        }
        return out
    }()

    private static func resolve(_ code: UInt32) -> UIColor? {
        switch code >> 24 {
        case 1: return palette[Int(code & 0xFF)]
        case 2: return rgb(code & 0xFFFFFF)
        default: return nil
        }
    }

    static func foreground(of c: VTCell) -> UIColor {
        var color: UIColor
        if c.attr & VTAttr.inverse != 0 {
            color = resolve(c.bg) ?? background
        } else {
            color = resolve(c.fg) ?? foregroundDefault
        }
        if c.attr & VTAttr.dim != 0 { color = color.withAlphaComponent(0.55) }
        return color
    }

    static func sameBackground(_ a: VTCell, _ b: VTCell) -> Bool {
        let ai = a.attr & VTAttr.inverse != 0, bi = b.attr & VTAttr.inverse != 0
        if ai != bi { return false }
        return ai ? a.fg == b.fg : a.bg == b.bg
    }

    /// nil = default background (nothing to paint).
    static func background(of c: VTCell) -> UIColor? {
        if c.attr & VTAttr.inverse != 0 {
            return resolve(c.fg) ?? foregroundDefault
        }
        return resolve(c.bg)
    }
}

/// SwiftUI wrapper around `TerminalCanvasView`.
struct TerminalCanvas: UIViewRepresentable {
    @ObservedObject var model: TerminalModel
    var fontSize: CGFloat
    var onTap: () -> Void

    func makeUIView(context: Context) -> TerminalCanvasView {
        let v = TerminalCanvasView(emulator: model.emulator)
        v.fontName = TerminalScreen.fontName
        v.boldFontName = TerminalScreen.boldFontName
        v.userFontSize = fontSize
        v.onTap = onTap
        v.onPhoneGrid = { [weak model] g in model?.setPhoneGrid(g) }
        model.canvas = v
        return v
    }

    func updateUIView(_ v: TerminalCanvasView, context: Context) {
        v.fontName = TerminalScreen.fontName
        v.boldFontName = TerminalScreen.boldFontName
        v.userFontSize = fontSize
        v.onTap = onTap
        v.showsCursor = model.live && !model.exited
        if model.canvas !== v { model.canvas = v }
        if v.emulator !== model.emulator { v.emulator = model.emulator }
    }

    static func dismantleUIView(_ v: TerminalCanvasView, coordinator: ()) {
        v.onPhoneGrid = nil
    }
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
