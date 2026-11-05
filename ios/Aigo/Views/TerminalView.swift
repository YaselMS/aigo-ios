import SwiftUI

/// Read-only view of the session's VT screen (GET /sessions/{id}/screen),
/// refreshed by SessionView. Input goes through the composer and key bar.
struct TerminalView: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(TerminalView.clean(text))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(10)
        }
        .defaultScrollAnchor(.bottomLeading)
        .background(Color.black.opacity(0.35))
    }

    /// Trims trailing spaces per line and trailing blank lines.
    static func clean(_ raw: String) -> String {
        if raw.isEmpty { return "Waiting for output…" }
        var lines = raw.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            while let last = l.last, last == " " || last == "\t" || last == "\r" {
                l = l.dropLast()
            }
            return String(l)
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
