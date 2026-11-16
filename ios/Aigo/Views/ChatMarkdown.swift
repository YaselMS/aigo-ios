import SwiftUI
import UIKit

/// Block markdown for chat replies: headings, paragraphs, lists, quotes,
/// tables (as mono text), rules and fenced code with Copy. Inline styles
/// come from AttributedString. Re-parsed as text streams in; an open fence
/// renders as code until it closes.
struct ChatMarkdown: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { pair in
                block(pair.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: MarkdownBlocks.Block) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(MarkdownBlocks.inline(t))
                .font(.aigo(MarkdownBlocks.headingStyle(level), .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 2)
                .textSelection(.enabled)
        case .paragraph(let t):
            Text(MarkdownBlocks.inline(t))
                .font(.aigo(.callout))
                .lineSpacing(5)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .item(let marker, let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.aigo(.callout))
                    .foregroundStyle(Theme.secondary)
                Text(MarkdownBlocks.inline(t))
                    .font(.aigo(.callout))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.line).frame(width: 2)
                Text(MarkdownBlocks.inline(t))
                    .font(.aigo(.callout))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t)
                    .font(.custom(TerminalScreen.fontName, fixedSize: 11))
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                    .padding(8)
            }
            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .textSelection(.enabled)
        case .code(let lang, let code):
            ChatCodeBlock(language: lang, code: code)
        case .rule:
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
        }
    }
}

/// Fenced code with the language and a Copy button.
struct ChatCodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.aigo(.caption2))
                        .foregroundStyle(copied ? Theme.lime : Theme.secondary)
                        .frame(minWidth: 40, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Copy code"))
            }
            .padding(.horizontal, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.custom(TerminalScreen.fontName, fixedSize: 12))
                    .foregroundStyle(Theme.text.opacity(0.92))
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .textSelection(.enabled)
        }
        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
    }
}

enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case item(String, String, Int)
        case quote(String)
        case table(String)
        case code(String, String)
        case rule
    }

    static func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .callout
        }
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]? = nil
        var lang = ""

        func flush() {
            if !para.isEmpty {
                out.append(.paragraph(para.joined(separator: "\n")))
                para = []
            }
            if !quote.isEmpty {
                out.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if !table.isEmpty {
                out.append(.table(table.joined(separator: "\n")))
                table = []
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    out.append(.code(lang, (code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix("|") {
                if !para.isEmpty || !quote.isEmpty { flush() }
                table.append(trimmed)
                continue
            } else if !table.isEmpty {
                flush()
            }
            if let h = heading(trimmed) {
                flush()
                out.append(h)
                continue
            }
            if isRule(trimmed) {
                flush()
                out.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = leadingSpaces(line) / 2
            if let rest = bullet(trimmed) {
                flush()
                out.append(.item("•", rest, min(indent, 4)))
                continue
            }
            if let o = ordered(trimmed) {
                flush()
                out.append(.item(o.0, o.1, min(indent, 4)))
                continue
            }
            if !quote.isEmpty { flush() }
            para.append(trimmed)
        }
        if let code {
            out.append(.code(lang, code.joined(separator: "\n")))
        }
        flush()
        return out
    }

    private static func heading(_ s: String) -> Block? {
        var level = 0
        for ch in s {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = s.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func bullet(_ s: String) -> String? {
        for p in ["- [ ] ", "- [x] ", "- [X] "] where s.hasPrefix(p) {
            let mark: String = (p.contains("x") || p.contains("X")) ? "☑ " : "☐ "
            return mark + String(s.dropFirst(p.count))
        }
        for p in ["- ", "* ", "+ "] where s.hasPrefix(p) {
            return String(s.dropFirst(2))
        }
        return nil
    }

    private static func ordered(_ s: String) -> (String, String)? {
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber, digits.count < 4 {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let after = s.index(after: idx)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return ("\(digits).", String(s[s.index(after: after)...]))
    }

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    /// Inline markdown (bold, italic, code, links); inline code gets a tint.
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: s, options: options) else {
            return AttributedString(s)
        }
        let codeRanges = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map { $0.range }
        for r in codeRanges {
            attributed[r].swiftUI.foregroundColor = Theme.iceText
            attributed[r].swiftUI.backgroundColor = Theme.codeBg
        }
        return attributed
    }
}
