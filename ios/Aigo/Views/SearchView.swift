import SwiftUI

/// Search: every session on the PC, including older chats and chats started
/// outside Aigo (host v0.3), by title, prompt, folder or agent.
struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SessionInfo] = []
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
                    }
                    ForEach(results) { s in
                        Button {
                            dismiss()
                            store.openSession(s.id)
                        } label: {
                            row(s)
                        }
                        .buttonStyle(.plain)
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

    private func row(_ s: SessionInfo) -> some View {
        let col = store.column(of: s)
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(col?.color ?? Theme.idle)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.displayTitle)
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meta(s, col))
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let p = s.lastPrompt, !p.isEmpty {
                    Text(p)
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aigoCard()
        .contentShape(Rectangle())
    }

    private func meta(_ s: SessionInfo, _ col: BoardColumn?) -> String {
        var parts = [s.subtitle]
        if s.isExternal { parts.append("outside Aigo") }
        parts.append(col?.label ?? s.status.label)
        let age = Age.short(s.activityDate)
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }
}
