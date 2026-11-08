// Self-test of ios/Aigo/Terminal/VTEmulator.swift (run in CI on macOS):
//   swiftc -O -o vt-selftest ios/Aigo/Terminal/VTEmulator.swift scripts/vt-selftest/main.swift && ./vt-selftest
import Foundation

var failures = 0
func check(_ cond: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if !cond {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func screenLines(_ e: VTEmulator) -> [String] {
    (e.history.count..<e.lineCount).map { e.line($0)?.text ?? "?" }
}

let ESC = "\u{1B}"

// 1. A host snapshot (docs/API.md §6): reset, clear incl. scrollback,
//    history lines, screen rows, state, cursor.
do {
    let e = VTEmulator(cols: 20, rows: 4)
    e.feed("old stuff\r\nmore\r\n\r\n\r\n\r\nscrolled")
    let epoch = e.historyEpoch
    var snap = "\(ESC)[?1049l\(ESC)[r\(ESC)[?6l\(ESC)[4l\(ESC)[?7h\(ESC)[0m\(ESC)[H\(ESC)[2J\(ESC)[3J"
    snap += "h1\r\nh2\r\n"                              // 2 scrollback lines
    snap += "row1\r\n\(ESC)[31mrow2\(ESC)[0m\r\n\r\nrow4"  // 4 screen rows
    snap += "\(ESC)[?1l\(ESC)>\(ESC)[2;3H\(ESC)[0m\(ESC)[?25h"
    e.feed(snap)
    check(e.historyEpoch != epoch, "ED 3 clears the scrollback")
    check(e.history.map { $0.text } == ["h1", "h2"], "history = \(e.history.map { $0.text })")
    check(screenLines(e) == ["row1", "row2", "", "row4"], "screen = \(screenLines(e))")
    check(e.cursorX == 2 && e.cursorY == 1, "cursor \(e.cursorX),\(e.cursorY)")
    check(e.line(e.history.count + 1)?.cells[0].fg == VTColor.palette(1), "row2 is red")
    check(e.line(e.history.count + 1)?.cells[0].code == UInt32(("r" as Unicode.Scalar).value), "row2 text")
}

// 2. Autowrap marks the line wrapped and pushes the top line to history.
do {
    let e = VTEmulator(cols: 5, rows: 2)
    e.feed("abcdefgh\r\nxy")
    check(e.history.count == 1 && e.history[0].text == "abcde" && e.history[0].wrapped, "wrap into history")
    check(screenLines(e) == ["fgh", "xy"], "after wrap \(screenLines(e))")
    check(e.text(includeHistory: true) == "abcdefgh\nxy", "joined text \(e.text(includeHistory: true))")
}

// 3. Writing the last column does not wrap until the next character.
do {
    let e = VTEmulator(cols: 4, rows: 2)
    e.feed("abcd")
    check(e.cursorY == 0 && e.cursorX == 3, "pending wrap keeps the cursor")
    e.feed("\r\n")
    check(e.cursorY == 1 && e.history.isEmpty, "CRLF after a full line moves one line")
}

// 4. Erase in line / display, insert / delete characters.
do {
    let e = VTEmulator(cols: 10, rows: 3)
    e.feed("0123456789\r\nabcdefghij\r\nABCDEFGHIJ")
    e.feed("\(ESC)[2;5H\(ESC)[K")
    check(screenLines(e)[1] == "abcd", "EL 0: \(screenLines(e)[1])")
    e.feed("\(ESC)[1;3H\(ESC)[2P")
    check(screenLines(e)[0] == "01456789", "DCH: \(screenLines(e)[0])")
    e.feed("\(ESC)[1;1H\(ESC)[2@")
    check(screenLines(e)[0] == "  01456789", "ICH: \(screenLines(e)[0])")
    e.feed("\(ESC)[3;4H\(ESC)[1J")
    check(screenLines(e) == ["", "", "    EFGHIJ"], "ED 1: \(screenLines(e))")
}

// 5. Scroll region: lines scroll inside it and not into history.
do {
    let e = VTEmulator(cols: 6, rows: 4)
    e.feed("top\r\na\r\nb\r\nbottom")
    e.feed("\(ESC)[2;3r\(ESC)[3;1H\nnew")
    check(screenLines(e) == ["top", "b", "new", "bottom"], "region scroll \(screenLines(e))")
    check(e.history.isEmpty, "no history from a partial region")
    e.feed("\(ESC)[r\(ESC)[2;1H\(ESC)[L")
    check(screenLines(e) == ["top", "", "b", "new"], "IL \(screenLines(e))")
}

// 6. Alternate screen keeps the main screen and the cursor.
do {
    let e = VTEmulator(cols: 8, rows: 3)
    e.feed("shell$ ")
    e.feed("\(ESC)[?1049h\(ESC)[H\(ESC)[2Jvim")
    check(e.usingAlt && screenLines(e)[0] == "vim", "alt screen")
    e.feed("\(ESC)[?1049l")
    check(!e.usingAlt && screenLines(e)[0] == "shell$" && e.cursorX == 7, "back to main \(screenLines(e)) \(e.cursorX)")
}

// 7. SGR: 256 colours, truecolor (semicolon and colon forms), reset.
do {
    let e = VTEmulator(cols: 10, rows: 1)
    e.feed("\(ESC)[38;5;208ma\(ESC)[48;2;1;2;3mb\(ESC)[38:2::10:20:30mc\(ESC)[0;1md")
    let cells = e.line(0)!.cells
    check(cells[0].fg == VTColor.palette(208), "256 colour")
    check(cells[1].bg == VTColor.rgb(1, 2, 3), "truecolor bg")
    check(cells[2].fg == VTColor.rgb(10, 20, 30), "colon truecolor")
    check(cells[3].fg == 0 && cells[3].bg == 0 && cells[3].attr == VTAttr.bold, "reset + bold")
}

// 8. UTF-8 split across feeds, wide characters, box drawing.
do {
    let e = VTEmulator(cols: 10, rows: 1)
    let bytes = Array("╭─日x".utf8)
    e.feed(Data(bytes[0..<2]))
    e.feed(Data(bytes[2...]))
    let cells = e.line(0)!.cells
    check(cells[0].code == 0x256D && cells[1].code == 0x2500, "box drawing")
    check(cells[2].code == 0x65E5 && cells[2].width == 2 && cells[3].width == 0, "wide char")
    check(cells[4].code == UInt32(("x" as Unicode.Scalar).value) && e.cursorX == 5, "after wide char")
}

// 9. Resize, then a snapshot at the new size.
do {
    let e = VTEmulator(cols: 80, rows: 24)
    e.feed("hello")
    e.resize(cols: 40, rows: 10)
    check(e.cols == 40 && e.rows == 10, "resize")
    e.feed("\(ESC)[H\(ESC)[2J\(ESC)[3Jnew screen")
    check(screenLines(e)[0] == "new screen" && e.history.isEmpty, "snapshot after resize")
}

// 10. Scrollback cap counts dropped lines.
do {
    let e = VTEmulator(cols: 5, rows: 2)
    e.maxHistory = 10
    for i in 0..<30 { e.feed("\(i)\r\n") }
    check(e.history.count == 10, "history capped at \(e.history.count)")
    check(e.droppedLines == 19, "dropped \(e.droppedLines)")
}

// 11. OSC title and unknown sequences are swallowed.
do {
    let e = VTEmulator(cols: 20, rows: 1)
    e.feed("\(ESC)]0;my title\u{07}\(ESC)P1$r\(ESC)\\\(ESC)[>4;1m\(ESC)[?2004hok")
    check(e.title == "my title", "title \(e.title)")
    check(screenLines(e)[0] == "ok" && e.bracketedPaste, "swallowed: \(screenLines(e)[0])")
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("VTEmulator self-test passed")
