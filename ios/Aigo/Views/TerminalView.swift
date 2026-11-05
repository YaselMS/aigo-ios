import SwiftUI
import UIKit

/// Live terminal pane: the host-rendered VT screen, refreshed from the attach
/// stream, plus a small status strip (live / reconnecting, fit, text size).
struct TerminalPane: View {
    @ObservedObject var model: TerminalModel
    @Binding var fontSize: Double
    @Binding var fit: Bool

    var body: some View {
        VStack(spacing: 0) {
            strip
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            TerminalScreen(text: model.screen?.text,
                           fontSize: CGFloat(fontSize),
                           onGrid: { cols, rows in model.setPhoneSize(cols: cols, rows: rows) })
        }
        .background(Color.black.opacity(0.45))
    }

    private var strip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.live ? Theme.lime : (model.exited ? Theme.idle : Theme.coral))
                .frame(width: 7, height: 7)
                .shadow(color: model.live ? Theme.lime.opacity(0.6) : .clear, radius: 3)
            Text(stateText)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Haptics.selection()
                fit.toggle()
            } label: {
                Label(fit ? "Fitted" : "Fit width", systemImage: fit ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square")
                    .font(Theme.monoCaption)
                    .foregroundStyle(fit ? Theme.lime : Theme.text)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.exited)
            .accessibilityHint(Text("Resizes the terminal on the PC to fit this phone"))
            Menu {
                Button {
                    fontSize = min(fontSize + 1, 18)
                } label: {
                    Label("Larger text", systemImage: "textformat.size.larger")
                }
                Button {
                    fontSize = max(fontSize - 1, 8)
                } label: {
                    Label("Smaller text", systemImage: "textformat.size.smaller")
                }
                Button {
                    fontSize = 12
                } label: {
                    Label("Default size", systemImage: "arrow.uturn.backward")
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Text size"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .background(Theme.bg)
    }

    private var stateText: String {
        if model.exited { return "exited · read-only" }
        if model.live { return "live" }
        if let p = model.problem { return "reconnecting · \(p)" }
        return "connecting…"
    }
}

/// Monospaced render of the screen text. Reports how many columns/rows of
/// the current font fit, for "Fit width".
struct TerminalScreen: View {
    let text: String?
    var fontSize: CGFloat = 12
    var onGrid: ((Int, Int) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if let text = text {
                        Text(TerminalScreen.clean(text))
                            .foregroundStyle(Theme.text)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading the screen…")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(10)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .bottomLeading)
            }
            .defaultScrollAnchor(.bottomLeading)
            .onAppear { report(geo.size) }
            .onChange(of: geo.size) { _, size in report(size) }
            .onChange(of: fontSize) { _, _ in report(geo.size) }
        }
    }

    private func report(_ size: CGSize) {
        guard let onGrid = onGrid, size.width > 40, size.height > 40 else { return }
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cell = ("M" as NSString).size(withAttributes: [.font: font])
        guard cell.width > 0, font.lineHeight > 0 else { return }
        let cols = Int((size.width - 20) / cell.width)
        let rows = Int((size.height - 20) / font.lineHeight)
        onGrid(cols, rows)
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
