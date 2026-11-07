import Combine
import SwiftUI
import UIKit

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
                        .font(.aigo(.footnote, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    let items = model.visible
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            if model.waiting && model.error == nil {
                                ProgressView().tint(Theme.secondary)
                            }
                            Text(model.waiting ? "Waiting for the conversation to start…" : "No messages yet. Say what it should do.")
                                .font(.aigo(.callout))
                                .foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                    }
                    ForEach(items) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let error = model.error, items.isEmpty {
                        Text(error)
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.coral)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
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
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
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
                .font(.aigo(.footnote))
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
                    .font(.aigo(.callout))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(aigoHex: 0x1B1E22), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Color(aigoHex: 0x2A2D31), lineWidth: 1))
                    .textSelection(.enabled)
            }
        case "system":
            Text(text)
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        default:
            Text(MessageRow.markdown(text))
                .font(.aigo(.callout))
                .lineSpacing(5)
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
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Text(message.toolName ?? "tool")
                .font(.aigo(.caption, .semibold))
                .foregroundStyle(Theme.text)
            Text(oneLine)
                .font(.aigo(.caption))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
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
                        .font(.system(size: 10, weight: .semibold))
                    Text(message.isError == true ? "Tool error" : "Tool output")
                        .font(.aigo(.caption))
                    Spacer()
                }
                .foregroundStyle(message.isError == true ? Theme.coral : Theme.secondary)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(message.text ?? "")
                    .font(.aigo(.caption))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 10)
    }
}
