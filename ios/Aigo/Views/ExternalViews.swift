import SwiftUI

/// An agent started outside Aigo, on the board while it is active (Needs you
/// while blocked, Working while busy). Its conversation opens read-only.
struct ExternalCard: View {
    let session: ExternalSession
    let column: BoardColumn

    @EnvironmentObject private var store: AppStore

    var body: some View {
        let needs = column == .ask
        Button {
            if let target = store.externalTarget(session.key) {
                store.openExternal(target)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meta)
                    .font(.aigo(.caption2))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(line)
                    .font(.aigo(.footnote))
                    .foregroundStyle(needs ? Theme.coralText : Theme.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aigoCard(border: needs ? Theme.coral : Color(aigoHex: 0x2A2D31),
                      fill: needs ? Theme.coralWash : Theme.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the conversation, read-only"))
    }

    private var meta: String {
        var parts = [store.agentName(session.agent), "outside Aigo"]
        let folder = folderName(session.cwd)
        if !folder.isEmpty { parts.insert(folder, at: 1) }
        let age = Age.short(session.activityDate)
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    private var line: String {
        if column == .ask { return "Waiting in its own terminal" }
        let prompt = (session.lastPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if (session.title ?? "").isEmpty || prompt.isEmpty { return "Working…" }
        return prompt
    }
}

/// Read-only conversation of an outside-Aigo session or of a conversation
/// file found by search (WS /api/v1/external/{key}/transcript).
struct ExternalConversationView: View {
    let key: String

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transcript = TranscriptModel()

    var body: some View {
        let target = store.externalTarget(key)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back to the board"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(target?.title ?? "Conversation")
                        .font(.aigo(.callout, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(target?.subtitle ?? "outside Aigo")
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Read-only")
                    .font(.aigo(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.lineSoft).frame(height: 1)
            }

            ChatView(model: transcript)
                .frame(maxHeight: .infinity)

            Text("Started outside Aigo. Answer it in its own terminal on the PC.")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(target?.title ?? "Conversation")
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let c = store.client {
                transcript.start(client: c, key: key, path: target?.stream ?? "/api/v1/external/\(key)/transcript")
            }
        }
        .onDisappear {
            transcript.stop()
        }
    }
}
