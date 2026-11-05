import SwiftUI

struct ChatView: View {
    @ObservedObject var model: TranscriptModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.hasMore {
                        Button("Load earlier messages") {
                            model.loadOlder()
                        }
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    let items = model.visible
                    if items.isEmpty {
                        Text(model.waiting ? "Waiting for the conversation to start…" : "No messages yet.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(items) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let error = model.error, items.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.coral)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.bottomTick) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }
}

struct MessageRow: View {
    let message: TranscriptMessage

    var body: some View {
        switch message.kind ?? "text" {
        case "tool_use":
            ToolCallRow(message: message)
        case "tool_result":
            ToolResultRow(message: message)
        case "image":
            Label("Image", systemImage: "photo")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
        default:
            textRow
        }
    }

    @ViewBuilder
    private var textRow: some View {
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.role ?? "assistant" {
        case "user":
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.lime.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.lime.opacity(0.35), lineWidth: 1))
                    .textSelection(.enabled)
            }
        case "system":
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        default:
            Text(MessageRow.markdown(text))
                .font(.body)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }
        return AttributedString(text)
    }
}

/// Compact row: tool name + one line of its input.
struct ToolCallRow: View {
    let message: TranscriptMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Text(message.toolName ?? "tool")
                .font(Theme.monoSmall.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(oneLine)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var oneLine: String {
        let raw = (message.toolInput ?? message.text ?? "")
        return raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
    }
}

/// Collapsed tool output; tap to expand.
struct ToolResultRow: View {
    let message: TranscriptMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text(message.isError == true ? "Tool error" : "Tool output")
                        .font(.footnote)
                    Spacer()
                }
                .foregroundStyle(message.isError == true ? Theme.coral : Theme.secondary)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(message.text ?? "")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 10)
    }
}
