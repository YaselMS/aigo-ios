import SwiftUI

/// Search: every session on the PC, including older chats and chats started
/// outside Aigo (host v0.3), by title, prompt, folder or agent.
struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchItem] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    TextField("Search chats", text: $query)
                        .focused($focused)
                        .font(.aigo(.callout))
                        .foregroundStyle(Theme.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)
                    if searching {
                        ProgressView().controlSize(.small).tint(Theme.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color(aigoHex: 0x2A2D31), lineWidth: 1))
                Button("Close") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: false))
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if results.isEmpty && !searching {
                        Text(query.isEmpty ? "No chats yet." : "Nothing matches \"\(query)\".")
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, 40)
                    } else if query.isEmpty && !results.isEmpty {
                        // Empty search lists the recent sessions, like the desktop (#95).
                        Text("Recent sessions")
                            .font(.aigo(.caption, .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(results) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { focused = true }
        .task(id: query) {
            // Debounce typing, then ask the host.
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            searching = true
            let found = await store.search(query)
            if !Task.isCancelled {
                results = found
                searching = false
            }
        }
    }

    private func row(_ item: SearchItem) -> some View {
        let col = BoardColumn(rawValue: item.board ?? "")
        let line = [item.lastMessage, item.lastPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != item.title }
        let running = store.liveLabel(item.live)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                dismiss()
                store.open(item)
            } label: {
                content(item, col: col, line: line, running: running)
            }
            .buttonStyle(.plain)
            if store.canContinue && item.resumable == true {
                ContinueControl(id: item.id, label: item.live?.`where` == "aigo" ? "Open" : "Continue")
                    .padding(.leading, 18)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aigoCard()
    }

    private func content(_ item: SearchItem, col: BoardColumn?, line: String?, running: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(col?.color ?? Theme.idle)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text((item.title ?? "").isEmpty ? AgentNames.display(item.agent) : item.title!)
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meta(item, col))
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let running {
                    Text(running)
                        .font(.aigo(.caption2, .semibold))
                        .foregroundStyle(item.live?.`where` == "aigo" ? Theme.lime : Theme.ice)
                        .lineLimit(1)
                }
                if let line {
                    Text(line)
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func meta(_ item: SearchItem, _ col: BoardColumn?) -> String {
        // The harness (Claude Code, Codex, Pi, gentle-shell, Terminal) when the host sends it.
        var parts = [item.harness.map { AgentNames.display($0) } ?? store.agentName(item.agent)]
        let place = (item.project ?? "").isEmpty ? folderName(item.cwd) : item.project!
        if !place.isEmpty { parts.append(place) }
        if item.external == true { parts.append("outside Aigo") }
        if let col { parts.append(col.label) }
        let age = Age.short(AigoDate.parse(item.lastActivity))
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }
}
