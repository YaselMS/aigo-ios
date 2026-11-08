import Foundation

/// One character cell of the terminal grid.
struct VTCell: Equatable {
    /// Unicode scalar value; 0 = blank.
    var code: UInt32 = 0
    /// Foreground / background colour, see `VTColor`.
    var fg: UInt32 = 0
    var bg: UInt32 = 0
    /// `VTAttr` bits.
    var attr: UInt16 = 0
    /// 1 = normal, 2 = first half of a wide character, 0 = its second half.
    var width: UInt8 = 1

    static let blank = VTCell()

    var isBlankDefault: Bool { (code == 0 || code == 32) && bg == 0 && attr & VTAttr.inverse == 0 }
}

/// Colour encoding of `VTCell.fg` / `.bg`: 0 = default, palette index or 24-bit RGB.
enum VTColor {
    static let `default`: UInt32 = 0
    static func palette(_ i: Int) -> UInt32 { 0x0100_0000 | UInt32(max(0, min(255, i))) }
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0x0200_0000 | (UInt32(max(0, min(255, r))) << 16) | (UInt32(max(0, min(255, g))) << 8) | UInt32(max(0, min(255, b)))
    }
}

enum VTAttr {
    static let bold: UInt16 = 1
    static let dim: UInt16 = 2
    static let italic: UInt16 = 4
    static let underline: UInt16 = 8
    static let inverse: UInt16 = 16
    static let invisible: UInt16 = 32
    static let strike: UInt16 = 64
}

struct VTLine {
    var cells: [VTCell]
    /// The line continues on the next one (soft wrap).
    var wrapped = false

    init(cols: Int, fill: VTCell = .blank) {
        cells = Array(repeating: fill, count: cols)
    }

    init(cells: [VTCell], wrapped: Bool) {
        self.cells = cells
        self.wrapped = wrapped
    }

    /// The line without trailing default blanks (for scrollback).
    func trimmed() -> VTLine {
        var end = cells.count
        while end > 0, cells[end - 1].isBlankDefault { end -= 1 }
        return VTLine(cells: Array(cells[0..<end]), wrapped: wrapped)
    }

    var text: String {
        var s = String.UnicodeScalarView()
        for c in cells where c.width != 0 {
            if c.code == 0 {
                s.append(" ")
            } else if let u = Unicode.Scalar(c.code) {
                s.append(u)
            }
        }
        var out = String(s)
        while out.last == " " { out.removeLast() }
        return out
    }
}

/// A small VT100/xterm emulator: enough for shells, ConPTY output, Codex and
/// Claude Code, and the host's attach snapshots (docs/API.md §6). It never
/// answers queries (the PC's own terminal does that). Not thread-safe: use it
/// from the main thread.
final class VTEmulator {
    private(set) var cols: Int
    private(set) var rows: Int
    private var main: [VTLine]
    private var alt: [VTLine]
    private(set) var usingAlt = false
    /// Lines that scrolled off the top of the main screen, oldest first.
    private(set) var history: [VTLine] = []
    var maxHistory = 3000
    /// Total number of history lines dropped from the top (cap or ED 3).
    private(set) var droppedLines = 0
    /// Increments when the scrollback is cleared (ED 3 / reset).
    private(set) var historyEpoch = 0
    /// Increments on every change.
    private(set) var version = 0

    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private var pendingWrap = false
    private(set) var cursorVisible = true
    private(set) var appCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var title = ""

    private var pen = VTCell()
    private var top = 0
    private var bottom: Int
    private var autowrap = true
    private var originMode = false
    private var insertMode = false
    private var g0Graphics = false
    private var tabStops: Set<Int> = []
    private var lastPrinted: UInt32 = 0

    private struct Saved {
        var x = 0, y = 0
        var pen = VTCell()
        var origin = false
        var autowrap = true
        var graphics = false
    }
    private var savedMain = Saved()
    private var savedAlt = Saved()

    // Parser
    private enum State { case ground, escape, escSkip, charset(Int), csi, osc, oscEsc, string, stringEsc }
    private var state: State = .ground
    private var params: [Int] = []
    private var colonParams: [Bool] = []
    private var current = -1
    private var currentColon = false
    private var privateMarker: UInt8 = 0
    private var intermediate: UInt8 = 0
    private var oscBytes: [UInt8] = []
    private var utf8: UInt32 = 0
    private var utf8Left = 0

    init(cols: Int, rows: Int) {
        let c = max(1, cols), r = max(1, rows)
        self.cols = c
        self.rows = r
        main = Array(repeating: VTLine(cols: c), count: r)
        alt = Array(repeating: VTLine(cols: c), count: r)
        bottom = r - 1
        resetTabs()
    }

    // MARK: - Reading

    /// Scrollback plus the screen.
    var lineCount: Int { history.count + rows }

    func line(_ index: Int) -> VTLine? {
        if index < 0 { return nil }
        if index < history.count { return history[index] }
        let i = index - history.count
        guard i < rows else { return nil }
        return usingAlt ? alt[i] : main[i]
    }

    /// Index (in `line(_:)` space) of the cursor's line.
    var cursorLineIndex: Int { history.count + cursorY }

    /// Plain text of the screen (or of everything), soft-wrapped lines joined.
    func text(includeHistory: Bool) -> String {
        let start = includeHistory ? 0 : history.count
        var out: [String] = []
        var carry = ""
        for i in start..<lineCount {
            guard let l = line(i) else { continue }
            if l.wrapped {
                var u = String.UnicodeScalarView()
                for c in l.cells where c.width != 0 {
                    u.append(c.code == 0 ? " " : (Unicode.Scalar(c.code) ?? " "))
                }
                carry += String(u)
            } else {
                out.append(carry + l.text)
                carry = ""
            }
        }
        if !carry.isEmpty { out.append(carry) }
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    // MARK: - Size / reset

    /// Sets the grid size. The host follows every size change with a full
    /// snapshot, so this only keeps the state consistent (no reflow).
    func resize(cols newCols: Int, rows newRows: Int) {
        let c = max(1, min(newCols, 1000)), r = max(1, min(newRows, 500))
        if c == cols && r == rows { return }
        func fit(_ lines: inout [VTLine], keepHistory: Bool) {
            for i in lines.indices {
                if lines[i].cells.count > c {
                    lines[i].cells.removeLast(lines[i].cells.count - c)
                    if let last = lines[i].cells.last, last.width == 2 {
                        lines[i].cells[c - 1] = .blank
                    }
                } else if lines[i].cells.count < c {
                    lines[i].cells.append(contentsOf: Array(repeating: VTCell.blank, count: c - lines[i].cells.count))
                }
            }
            if lines.count > r {
                // Keep the cursor's line on screen: move lines above into the scrollback.
                let shift = max(0, min(lines.count - r, cursorY - r + 1))
                if shift > 0 {
                    if keepHistory { pushHistory(Array(lines[0..<shift])) }
                    lines.removeFirst(shift)
                }
                if lines.count > r { lines.removeLast(lines.count - r) }
            } else if lines.count < r {
                lines.append(contentsOf: Array(repeating: VTLine(cols: c), count: r - lines.count))
            }
        }
        let oldRows = rows
        fit(&main, keepHistory: !usingAlt)
        fit(&alt, keepHistory: false)
        if cursorY >= r { cursorY -= max(0, min(oldRows - r, cursorY - r + 1)) }
        cols = c
        rows = r
        top = 0
        bottom = r - 1
        cursorX = min(cursorX, c - 1)
        cursorY = max(0, min(cursorY, r - 1))
        pendingWrap = false
        resetTabs()
        version += 1
    }

    /// Full reset (RIS), including the scrollback.
    func reset() {
        main = Array(repeating: VTLine(cols: cols), count: rows)
        alt = Array(repeating: VTLine(cols: cols), count: rows)
        usingAlt = false
        clearHistory()
        cursorX = 0
        cursorY = 0
        pendingWrap = false
        cursorVisible = true
        appCursorKeys = false
        bracketedPaste = false
        pen = VTCell()
        top = 0
        bottom = rows - 1
        autowrap = true
        originMode = false
        insertMode = false
        g0Graphics = false
        savedMain = Saved()
        savedAlt = Saved()
        state = .ground
        utf8Left = 0
        resetTabs()
        version += 1
    }

    private func resetTabs() {
        tabStops = Set(stride(from: 8, to: cols, by: 8))
    }

    private func clearHistory() {
        if !history.isEmpty {
            droppedLines += history.count
            history.removeAll()
        }
        historyEpoch += 1
    }

    private func pushHistory(_ lines: [VTLine]) {
        for l in lines { history.append(l.trimmed()) }
        if history.count > maxHistory {
            let n = history.count - maxHistory
            history.removeFirst(n)
            droppedLines += n
        }
    }

    // MARK: - Input

    func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { step(b) }
        }
        version += 1
    }

    func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    private func step(_ b: UInt8) {
        switch state {
        case .ground:
            ground(b)
        case .escape:
            escape(b)
        case .escSkip:
            state = .ground
        case .charset(let g):
            if g == 0 { g0Graphics = (b == 0x30) }
            state = .ground
        case .csi:
            csi(b)
        case .osc:
            if b == 0x07 {
                finishOSC()
            } else if b == 0x1B {
                state = .oscEsc
            } else if b == 0x18 || b == 0x1A {
                state = .ground
            } else if oscBytes.count < 4096 {
                oscBytes.append(b)
            }
        case .oscEsc:
            finishOSC()
            if b != 0x5C {
                state = .escape
                escape(b)
            }
        case .string:
            if b == 0x1B { state = .stringEsc } else if b == 0x18 || b == 0x1A { state = .ground }
        case .stringEsc:
            if b == 0x5C {
                state = .ground
            } else {
                state = .escape
                escape(b)
            }
        }
    }

    private func ground(_ b: UInt8) {
        if utf8Left > 0 {
            if b & 0xC0 == 0x80 {
                utf8 = (utf8 << 6) | UInt32(b & 0x3F)
                utf8Left -= 1
                if utf8Left == 0 { put(utf8) }
                return
            }
            utf8Left = 0
            put(0xFFFD)
        }
        if b < 0x20 {
            control(b)
        } else if b == 0x7F {
            return
        } else if b < 0x80 {
            put(UInt32(b))
        } else if b & 0xE0 == 0xC0 {
            utf8 = UInt32(b & 0x1F); utf8Left = 1
        } else if b & 0xF0 == 0xE0 {
            utf8 = UInt32(b & 0x0F); utf8Left = 2
        } else if b & 0xF8 == 0xF0 {
            utf8 = UInt32(b & 0x07); utf8Left = 3
        } else {
            put(0xFFFD)
        }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x08:
            if pendingWrap { pendingWrap = false } else if cursorX > 0 { cursorX -= 1 }
        case 0x09:
            tab(1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            cursorX = 0
            pendingWrap = false
        case 0x1B:
            state = .escape
            intermediate = 0
        default:
            break
        }
    }

    private func escape(_ b: UInt8) {
        state = .ground
        switch b {
        case 0x5B: // [
            params.removeAll(keepingCapacity: true)
            colonParams.removeAll(keepingCapacity: true)
            current = -1
            currentColon = false
            privateMarker = 0
            intermediate = 0
            state = .csi
        case 0x5D: // ]
            oscBytes.removeAll(keepingCapacity: true)
            state = .osc
        case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _
            state = .string
        case 0x28: state = .charset(0)
        case 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F: state = .charset(1)
        case 0x23, 0x25, 0x20: state = .escSkip
        case 0x37: saveCursor()
        case 0x38: restoreCursor()
        case 0x44: index()
        case 0x45: cursorX = 0; index()
        case 0x4D: reverseIndex()
        case 0x48: tabStops.insert(cursorX)
        case 0x63: reset()
        case 0x1B: state = .escape
        default: break
        }
    }

    private func csi(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            current = (current < 0 ? 0 : min(current, 100_000) * 10) + Int(b - 0x30)
        case 0x3B, 0x3A:
            params.append(current)
            colonParams.append(currentColon)
            current = -1
            currentColon = (b == 0x3A)
        case 0x3C...0x3F:
            if params.isEmpty && current < 0 { privateMarker = b }
        case 0x20...0x2F:
            intermediate = b
        case 0x40...0x7E:
            if current >= 0 || !params.isEmpty {
                params.append(current)
                colonParams.append(currentColon)
            }
            state = .ground
            dispatchCSI(b)
        case 0x1B:
            state = .escape
        case 0x18, 0x1A:
            state = .ground
        case 0x00...0x1F:
            control(b)
        default:
            break
        }
    }

    private func p(_ i: Int, _ def: Int = 1) -> Int {
        guard i < params.count, params[i] > 0 else { return def }
        return params[i]
    }

    private func p0(_ i: Int) -> Int {
        guard i < params.count, params[i] >= 0 else { return 0 }
        return params[i]
    }

    private func dispatchCSI(_ final: UInt8) {
        if intermediate != 0 {
            if intermediate == 0x21 && final == 0x70 { softReset() } // CSI ! p
            return
        }
        if privateMarker == 0x3F { // ?
            if final == 0x68 || final == 0x6C { setPrivateModes(final == 0x68) }
            return
        }
        if privateMarker != 0 { return }
        switch final {
        case 0x40: insertChars(p(0))
        case 0x41: moveUp(p(0))
        case 0x42, 0x65: moveDown(p(0))
        case 0x43, 0x61: cursorX = min(cols - 1, cursorX + p(0)); pendingWrap = false
        case 0x44: cursorX = max(0, cursorX - p(0)); pendingWrap = false
        case 0x45: moveDown(p(0)); cursorX = 0
        case 0x46: moveUp(p(0)); cursorX = 0
        case 0x47, 0x60: cursorX = min(cols - 1, p(0) - 1); pendingWrap = false
        case 0x48, 0x66: setCursor(row: p(0) - 1, col: p(1) - 1)
        case 0x64: setCursor(row: p(0) - 1, col: cursorX)
        case 0x49: tab(p(0))
        case 0x5A: backTab(p(0))
        case 0x4A: eraseDisplay(p0(0))
        case 0x4B: eraseLine(p0(0))
        case 0x4C: insertLines(p(0))
        case 0x4D: deleteLines(p(0))
        case 0x50: deleteChars(p(0))
        case 0x58: eraseChars(p(0))
        case 0x53: scrollUp(p(0))
        case 0x54: if params.count <= 1 { scrollDown(p(0)) }
        case 0x62: if lastPrinted != 0 { for _ in 0..<min(p(0), 2000) { put(lastPrinted) } }
        case 0x6D: sgr()
        case 0x72: setMargins(p(0), p(1, rows))
        case 0x73: saveCursor()
        case 0x75: restoreCursor()
        case 0x67: if p0(0) == 3 { tabStops.removeAll() } else if p0(0) == 0 { tabStops.remove(cursorX) }
        case 0x68, 0x6C:
            for v in params where v == 4 { insertMode = (final == 0x68) }
        default:
            break // n (DSR), c (DA), t (window ops): never answered here
        }
    }

    private func setPrivateModes(_ on: Bool) {
        for v in params {
            switch v {
            case 1: appCursorKeys = on
            case 6: originMode = on; setCursor(row: 0, col: 0)
            case 7: autowrap = on; if !on { pendingWrap = false }
            case 25: cursorVisible = on
            case 47, 1047: switchScreen(alt: on, saveCursor: false, clear: on && v == 1047)
            case 1049: switchScreen(alt: on, saveCursor: true, clear: on)
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private func softReset() {
        pen = VTCell()
        top = 0
        bottom = rows - 1
        originMode = false
        autowrap = true
        insertMode = false
        cursorVisible = true
        appCursorKeys = false
        g0Graphics = false
        pendingWrap = false
    }

    private func finishOSC() {
        state = .ground
        guard let s = String(bytes: oscBytes, encoding: .utf8) else { return }
        let parts = s.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" {
            title = String(parts[1])
        }
    }

    // MARK: - Grid operations

    private func withLines(_ body: (inout [VTLine]) -> Void) {
        if usingAlt { body(&alt) } else { body(&main) }
    }

    private var eraseCell: VTCell {
        var c = VTCell()
        c.bg = pen.bg
        return c
    }

    private func blankLine() -> VTLine {
        VTLine(cols: cols, fill: eraseCell)
    }

    private func put(_ scalar: UInt32) {
        var code = scalar
        if g0Graphics, code >= 0x60, code <= 0x7E, let m = VTEmulator.decGraphics[code] {
            code = m
        }
        let w = VTEmulator.width(code)
        if w == 0 { return }
        lastPrinted = code
        if pendingWrap && autowrap {
            withLines { $0[cursorY].wrapped = true }
            cursorX = 0
            pendingWrap = false
            lineFeed()
        }
        if w == 2 && cursorX >= cols - 1 {
            if autowrap && cols > 1 {
                withLines { $0[cursorY].wrapped = true }
                cursorX = 0
                lineFeed()
            } else {
                return
            }
        }
        let x = cursorX, y = cursorY
        let cc = cols
        let cellPen = pen
        withLines { ls in
            if insertMode {
                ls[y].cells.insert(contentsOf: Array(repeating: VTCell.blank, count: w), at: x)
                ls[y].cells.removeLast(w)
            }
            VTEmulator.clearWide(&ls[y].cells, at: x)
            if w == 2 { VTEmulator.clearWide(&ls[y].cells, at: x + 1) }
            var cell = cellPen
            cell.code = code
            cell.width = UInt8(w)
            ls[y].cells[x] = cell
            if w == 2 && x + 1 < cc {
                var cont = cellPen
                cont.code = 0
                cont.width = 0
                ls[y].cells[x + 1] = cont
            }
        }
        cursorX += w
        if cursorX >= cols {
            cursorX = cols - 1
            pendingWrap = autowrap
        }
    }

    /// Overwriting half of a wide character blanks the other half.
    private static func clearWide(_ cells: inout [VTCell], at x: Int) {
        guard x >= 0, x < cells.count else { return }
        if cells[x].width == 0, x > 0 {
            cells[x - 1].code = 0
            cells[x - 1].width = 1
        } else if cells[x].width == 2, x + 1 < cells.count {
            cells[x + 1].code = 0
            cells[x + 1].width = 1
        }
    }

    private func lineFeed() {
        pendingWrap = false
        index()
    }

    private func index() {
        pendingWrap = false
        if cursorY == bottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorY == top {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        let toHistory = !usingAlt && top == 0
        var gone: [VTLine] = []
        let t = top, b = bottom
        let blank = blankLine()
        withLines { ls in
            for _ in 0..<count {
                let l = ls.remove(at: t)
                if toHistory { gone.append(l) }
                ls.insert(blank, at: b)
            }
        }
        if toHistory { pushHistory(gone) }
    }

    private func scrollDown(_ n: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        let t = top, b = bottom
        let blank = blankLine()
        withLines { ls in
            for _ in 0..<count {
                ls.remove(at: b)
                ls.insert(blank, at: t)
            }
        }
    }

    private func moveUp(_ n: Int) {
        let limit = cursorY >= top ? top : 0
        cursorY = max(limit, cursorY - n)
        pendingWrap = false
    }

    private func moveDown(_ n: Int) {
        let limit = cursorY <= bottom ? bottom : rows - 1
        cursorY = min(limit, cursorY + n)
        pendingWrap = false
    }

    private func setCursor(row: Int, col: Int) {
        var r = row
        if originMode {
            r += top
            r = max(top, min(r, bottom))
        }
        cursorY = max(0, min(r, rows - 1))
        cursorX = max(0, min(col, cols - 1))
        pendingWrap = false
    }

    private func setMargins(_ t: Int, _ b: Int) {
        let tt = max(1, t) - 1
        let bb = min(rows, max(1, b)) - 1
        guard tt < bb else { return }
        top = tt
        bottom = bb
        setCursor(row: 0, col: 0)
    }

    private func tab(_ n: Int) {
        for _ in 0..<n {
            var x = cursorX + 1
            while x < cols - 1 && !tabStops.contains(x) { x += 1 }
            cursorX = min(x, cols - 1)
        }
        pendingWrap = false
    }

    private func backTab(_ n: Int) {
        for _ in 0..<n {
            var x = cursorX - 1
            while x > 0 && !tabStops.contains(x) { x -= 1 }
            cursorX = max(0, x)
        }
        pendingWrap = false
    }

    private func eraseDisplay(_ mode: Int) {
        let y = cursorY, x = cursorX
        let blank = blankLine()
        let e = eraseCell
        switch mode {
        case 0:
            withLines { ls in
                for i in x..<ls[y].cells.count { ls[y].cells[i] = e }
                ls[y].wrapped = false
                for r in (y + 1)..<max(y + 1, ls.count) { ls[r] = blank }
            }
        case 1:
            withLines { ls in
                for r in 0..<y { ls[r] = blank }
                for i in 0...min(x, ls[y].cells.count - 1) { ls[y].cells[i] = e }
            }
        case 2:
            withLines { ls in
                for r in ls.indices { ls[r] = blank }
            }
        case 3:
            clearHistory()
        default:
            break
        }
        pendingWrap = false
    }

    private func eraseLine(_ mode: Int) {
        let y = cursorY, x = cursorX
        let e = eraseCell
        withLines { ls in
            let n = ls[y].cells.count
            switch mode {
            case 0:
                for i in x..<n { ls[y].cells[i] = e }
                ls[y].wrapped = false
            case 1:
                for i in 0...min(x, n - 1) { ls[y].cells[i] = e }
            case 2:
                for i in 0..<n { ls[y].cells[i] = e }
                ls[y].wrapped = false
            default:
                break
            }
        }
        pendingWrap = false
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= top && cursorY <= bottom else { return }
        let count = min(n, bottom - cursorY + 1)
        let y = cursorY, b = bottom
        let blank = blankLine()
        withLines { ls in
            for _ in 0..<count {
                ls.remove(at: b)
                ls.insert(blank, at: y)
            }
        }
        cursorX = 0
        pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= top && cursorY <= bottom else { return }
        let count = min(n, bottom - cursorY + 1)
        let y = cursorY, b = bottom
        let blank = blankLine()
        withLines { ls in
            for _ in 0..<count {
                ls.remove(at: y)
                ls.insert(blank, at: b)
            }
        }
        cursorX = 0
        pendingWrap = false
    }

    private func insertChars(_ n: Int) {
        let y = cursorY, x = cursorX
        let count = min(n, cols - x)
        let e = eraseCell
        withLines { ls in
            ls[y].cells.insert(contentsOf: Array(repeating: e, count: count), at: x)
            ls[y].cells.removeLast(count)
        }
        pendingWrap = false
    }

    private func deleteChars(_ n: Int) {
        let y = cursorY, x = cursorX
        let count = min(n, cols - x)
        let e = eraseCell
        withLines { ls in
            ls[y].cells.removeSubrange(x..<(x + count))
            ls[y].cells.append(contentsOf: Array(repeating: e, count: count))
        }
        pendingWrap = false
    }

    private func eraseChars(_ n: Int) {
        let y = cursorY, x = cursorX
        let count = min(n, cols - x)
        let e = eraseCell
        withLines { ls in
            for i in x..<(x + count) { ls[y].cells[i] = e }
        }
        pendingWrap = false
    }

    private func switchScreen(alt on: Bool, saveCursor save: Bool, clear: Bool) {
        if on == usingAlt { return }
        if on {
            if save { savedMain = currentSaved() }
            usingAlt = true
            if clear {
                alt = Array(repeating: VTLine(cols: cols), count: rows)
            }
        } else {
            usingAlt = false
            if save { apply(savedMain) }
        }
        pendingWrap = false
    }

    private func currentSaved() -> Saved {
        Saved(x: cursorX, y: cursorY, pen: pen, origin: originMode, autowrap: autowrap, graphics: g0Graphics)
    }

    private func apply(_ s: Saved) {
        cursorX = min(s.x, cols - 1)
        cursorY = min(s.y, rows - 1)
        pen = s.pen
        originMode = s.origin
        autowrap = s.autowrap
        g0Graphics = s.graphics
        pendingWrap = false
    }

    private func saveCursor() {
        if usingAlt { savedAlt = currentSaved() } else { savedMain = currentSaved() }
    }

    private func restoreCursor() {
        apply(usingAlt ? savedAlt : savedMain)
    }

    // MARK: - SGR

    private func sgr() {
        if params.isEmpty {
            pen = VTCell()
            return
        }
        var i = 0
        while i < params.count {
            let v = max(0, params[i])
            switch v {
            case 0: pen.fg = 0; pen.bg = 0; pen.attr = 0
            case 1: pen.attr |= VTAttr.bold
            case 2: pen.attr |= VTAttr.dim
            case 3: pen.attr |= VTAttr.italic
            case 4:
                // 4:0 = no underline (colon sub-parameter).
                if i + 1 < params.count, colonParams[i + 1] {
                    if params[i + 1] == 0 { pen.attr &= ~VTAttr.underline } else { pen.attr |= VTAttr.underline }
                    i += 1
                } else {
                    pen.attr |= VTAttr.underline
                }
            case 7: pen.attr |= VTAttr.inverse
            case 8: pen.attr |= VTAttr.invisible
            case 9: pen.attr |= VTAttr.strike
            case 21: pen.attr |= VTAttr.underline
            case 22: pen.attr &= ~(VTAttr.bold | VTAttr.dim)
            case 23: pen.attr &= ~VTAttr.italic
            case 24: pen.attr &= ~VTAttr.underline
            case 27: pen.attr &= ~VTAttr.inverse
            case 28: pen.attr &= ~VTAttr.invisible
            case 29: pen.attr &= ~VTAttr.strike
            case 30...37: pen.fg = VTColor.palette(v - 30)
            case 39: pen.fg = 0
            case 40...47: pen.bg = VTColor.palette(v - 40)
            case 49: pen.bg = 0
            case 90...97: pen.fg = VTColor.palette(v - 90 + 8)
            case 100...107: pen.bg = VTColor.palette(v - 100 + 8)
            case 38, 48, 58:
                let (color, used) = extendedColor(at: i)
                if let color = color {
                    if v == 38 { pen.fg = color } else if v == 48 { pen.bg = color }
                }
                i += used
            default:
                break
            }
            i += 1
        }
    }

    /// Parses `38;5;n`, `38;2;r;g;b` and the colon forms (`38:2::r:g:b`).
    /// Returns the colour and how many extra parameters it used.
    private func extendedColor(at i: Int) -> (UInt32?, Int) {
        var j = i + 1
        if j < params.count, colonParams[j] {
            var group: [Int] = []
            while j < params.count, colonParams[j] {
                group.append(params[j])
                j += 1
            }
            let used = group.count
            guard let kind = group.first else { return (nil, used) }
            if kind == 5, group.count >= 2 { return (VTColor.palette(max(0, group[1])), used) }
            if kind == 2 {
                let c = group.count >= 5 ? Array(group.suffix(3)) : Array(group.dropFirst().prefix(3))
                if c.count == 3 { return (VTColor.rgb(max(0, c[0]), max(0, c[1]), max(0, c[2])), used) }
            }
            return (nil, used)
        }
        guard j < params.count else { return (nil, 0) }
        let kind = params[j]
        j += 1
        if kind == 5 {
            guard j < params.count else { return (nil, 1) }
            return (VTColor.palette(max(0, params[j])), 2)
        }
        if kind == 2 {
            guard j + 2 < params.count else { return (nil, params.count - i - 1) }
            return (VTColor.rgb(max(0, params[j]), max(0, params[j + 1]), max(0, params[j + 2])), 4)
        }
        return (nil, 1)
    }

    // MARK: - Character tables

    private static let decGraphics: [UInt32: UInt32] = [
        0x60: 0x25C6, 0x61: 0x2592, 0x66: 0x00B0, 0x67: 0x00B1, 0x6A: 0x2518, 0x6B: 0x2510,
        0x6C: 0x250C, 0x6D: 0x2514, 0x6E: 0x253C, 0x6F: 0x23BA, 0x70: 0x23BB, 0x71: 0x2500,
        0x72: 0x23BC, 0x73: 0x23BD, 0x74: 0x251C, 0x75: 0x2524, 0x76: 0x2534, 0x77: 0x252C,
        0x78: 0x2502, 0x79: 0x2264, 0x7A: 0x2265, 0x7B: 0x03C0, 0x7C: 0x2260, 0x7D: 0x00A3,
        0x7E: 0x00B7,
    ]

    /// Display width of a scalar: 0 (combining / zero width), 1 or 2.
    static func width(_ c: UInt32) -> Int {
        if c < 0x300 { return 1 }
        switch c {
        case 0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x0610...0x061A, 0x064B...0x065F,
             0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x20D0...0x20FF, 0xFE00...0xFE0F,
             0xFE20...0xFE2F, 0xFEFF, 0xE0100...0xE01EF:
            return 0
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB,
             0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA,
             0x26FD, 0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757,
             0x2795...0x2797, 0x27B0, 0x27BF, 0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A,
             0x1F200...0x1F251, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB,
             0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
