import SwiftUI

extension InboxItem {
    var isCommand: Bool {
        let tool = (toolName ?? "").lowercased()
        return ["bash", "shell", "powershell", "exec", "exec_command", "local_shell", "run_command"].contains(tool)
    }

    /// The short "what it wants" line of a card.
    var askLine: String {
        switch kind ?? "" {
        case "question": return "Has a question"
        case "plan": return "Wants you to approve a plan"
        case "ask": return "Wants you to choose"
        default: return isCommand ? "Wants to run a command" : "Wants your approval"
        }
    }
}

/// Shared frame of a board card: coral for needs you, plain otherwise.
private struct BoardCardFrame: ViewModifier {
    let needsYou: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aigoCard(border: needsYou ? Theme.coral : Color(aigoHex: 0x2A2D31),
                      fill: needsYou ? Theme.coralWash : Theme.surface)
    }
}

/// Title, "agent · project · age" and one line; tapping opens the conversation.
private struct CardHead: View {
    let title: String
    let meta: String
    let line: String
    let lineColor: Color
    let sessionID: String?
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button {
            if let sid = sessionID, !sid.isEmpty { store.openSession(sid) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !line.isEmpty {
                    Text(line)
                        .font(.aigo(.footnote))
                        .foregroundStyle(lineColor)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(sessionID == nil ? "" : "Opens the conversation"))
    }
}

/// A pending approval or question, answered on the card (Home and the
/// conversation).
struct AttentionCard: View {
    let item: InboxItem
    var session: SessionInfo? = nil
    /// Inside the conversation: no title row, it is the header already.
    var inSession: Bool = false
    var position: String? = nil

    @EnvironmentObject private var store: AppStore
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if inSession {
                HStack {
                    Text("\(store.agentName(item.agent)) is asking")
                        .font(.aigo(.footnote))
                        .foregroundStyle(Theme.coralText)
                    Spacer(minLength: 4)
                    if let position = position {
                        Text(position)
                            .font(.aigo(.caption2))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Text(item.title ?? "Needs your answer")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CardHead(title: session?.displayTitle ?? item.title ?? "Needs your answer",
                         meta: meta,
                         line: session != nil ? (item.title ?? item.askLine) : item.askLine,
                         lineColor: Theme.coralText,
                         sessionID: item.sessionId)
            }

            if let message = item.message, !message.isEmpty {
                Text(message)
                    .font(.aigo(.caption2))
                    .foregroundStyle(item.isCommand ? Theme.coralCode : Theme.text.opacity(0.92))
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .textSelection(.enabled)
            }

            if let error = error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            actions
        }
        .modifier(BoardCardFrame(needsYou: true))
        .disabled(busy)
        .opacity(busy ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: confirming)
        .animation(.easeInOut(duration: 0.2), value: error)
        .accessibilityElement(children: .contain)
    }

    private var meta: String {
        var parts = [store.agentName(item.agent)]
        let place = (item.project?.isEmpty == false) ? item.project! : folderName(item.cwd ?? session?.cwd)
        if !place.isEmpty { parts.append(place) }
        if (item.sessionId ?? "").isEmpty { parts.append("outside Aigo") }
        let age = Age.short(AigoDate.parse(item.createdAt))
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        let options = item.options ?? []
        if item.kind == "ask" && !options.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { pair in
                    Button(pair.element) {
                        Haptics.approve()
                        run { await store.decide(item, approve: true, choice: pair.element) }
                    }
                    .buttonStyle(SecondaryButtonStyle(alignment: .leading))
                }
                Button("Deny") { denyTapped() }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.secondary))
            }
        } else if item.kind == "question" {
            if !options.isEmpty && !(item.sessionId ?? "").isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { pair in
                        Button(pair.element) {
                            Haptics.approve()
                            run { await store.answerQuestion(item, number: pair.offset + 1, label: pair.element) }
                        }
                        .buttonStyle(SecondaryButtonStyle(alignment: .leading))
                    }
                }
            } else if let sid = item.sessionId, !sid.isEmpty, !inSession {
                Button("Answer in the conversation") {
                    store.openSession(sid)
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.coral, text: Theme.coralButtonText))
            } else if inSession {
                Text("Answer it in the terminal.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("This agent runs outside Aigo. Answer it in its own terminal.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
            }
        } else if confirming {
            VStack(alignment: .leading, spacing: 8) {
                Label("This looks destructive. Run it anyway?", systemImage: "exclamationmark.triangle.fill")
                    .font(.aigo(.footnote, .semibold))
                    .foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Yes, run it") {
                        confirming = false
                        Haptics.approve()
                        run { await store.decide(item, approve: true) }
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.coral, text: Theme.coralButtonText))
                    Button("Cancel") {
                        Haptics.tap()
                        confirming = false
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                Button(item.kind == "plan" ? "Approve plan" : "Approve") { approveTapped() }
                    .buttonStyle(SoftButtonStyle(tint: Theme.coral, text: Theme.coralButtonText))
                Button("Deny") { denyTapped() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func approveTapped() {
        if item.looksDestructive {
            // A destructive command always needs the explicit "Yes, run it".
            Haptics.warning()
            confirming = true
            return
        }
        Haptics.approve()
        run { await store.decide(item, approve: true) }
    }

    private func denyTapped() {
        Haptics.deny()
        run { await store.decide(item, approve: false) }
    }

    private func run(_ op: @escaping () async -> String?) {
        busy = true
        error = nil
        Task {
            let result = await op()
            busy = false
            if let result = result {
                Haptics.error()
                error = result
            }
        }
    }
}

/// A session on the board. Blocked sessions without an inbox item show the
/// options of the menu on their screen; Review cards have "Looks good".
struct SessionCard: View {
    let session: SessionInfo
    let column: BoardColumn
    var onError: (String) -> Void = { _ in }

    @EnvironmentObject private var store: AppStore
    @State private var menu: ScreenMenu?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHead(title: session.displayTitle, meta: meta, line: line,
                     lineColor: column == .ask ? Theme.coralText : Theme.secondary,
                     sessionID: session.id)
            switch column {
            case .ask:
                if let menu = menu, let options = menu.options, !options.isEmpty {
                    if let note = menu.guidance {
                        MenuNote(text: note)
                    }
                    VStack(spacing: 6) {
                        ForEach(options) { option in
                            Button {
                                choose(option)
                            } label: {
                                MenuOptionLabel(label: option.label, recommended: menu.isRecommended(option))
                            }
                            .buttonStyle(SecondaryButtonStyle(alignment: .leading))
                            .accessibilityHint(menu.isRecommended(option) ? Text("Recommended") : Text(""))
                        }
                    }
                } else {
                    Button("Open to answer") { store.openSession(session.id) }
                        .buttonStyle(SoftButtonStyle(tint: Theme.coral, text: Theme.coralButtonText))
                }
            case .review:
                Button("Looks good") {
                    Haptics.success()
                    Task {
                        if let err = await store.markSeen(session.id) { onError(err) }
                    }
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.ice, text: Theme.iceText))
            case .work, .done:
                EmptyView()
            }
        }
        .modifier(BoardCardFrame(needsYou: column == .ask))
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
        .task(id: column == .ask ? (session.statusChangedAt ?? "ask") : "") {
            guard column == .ask, session.isRunning, let c = store.client else { return }
            menu = (try? await c.screen(session.id))?.menu
        }
    }

    private var meta: String {
        var parts = [session.isAgent ? store.agentName(session.agent) : "Terminal"]
        let folder = folderName(session.cwd)
        if session.isExternal {
            parts.append("outside Aigo")
        } else if !folder.isEmpty {
            parts.append(folder)
        }
        let age = Age.short(session.activityDate)
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    private var line: String {
        let prompt = (session.lastPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch column {
        case .ask:
            return (menu?.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting for your answer"
        case .work:
            return session.status == .stalled ? "Quiet for a while" : (prompt.isEmpty ? "Working…" : prompt)
        case .review:
            return prompt.isEmpty ? "Finished. Have a look." : "Finished: \(prompt)"
        case .done:
            if !session.isRunning { return session.nowLine }
            return prompt.isEmpty ? "Reviewed" : prompt
        }
    }

    private func choose(_ option: MenuOption) {
        Haptics.approve()
        busy = true
        Task {
            let err = await store.chooseMenu(session.id, number: option.number, label: option.label)
            busy = false
            if let err {
                Haptics.error()
                onError(err)
            } else {
                menu = nil
            }
        }
    }
}
