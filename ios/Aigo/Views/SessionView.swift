import SwiftUI
import UIKit

enum SessionTab: String, Hashable, CaseIterable {
    case chat = "Chat"
    case terminal = "Terminal"
    case changes = "Changes"
}

/// The conversation: "‹" back, title and one muted state line, the ⋯ menu
/// (views Chat / Terminal / Changes and actions), agent questions as option
/// buttons, composer.
struct SessionView: View {
    let sessionID: String

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transcript = TranscriptModel()
    @StateObject private var terminal = TerminalModel()
    /// Structured chat of a chat-mode session (host API §7k).
    @StateObject private var chat = ChatModel()
    @State private var switchingMode = false
    @State private var confirmTerminal = false
    @State private var tab: SessionTab = .chat
    @State private var draft = ""
    @State private var sending = false
    @State private var banner: String?
    @State private var confirmKill = false
    @State private var confirmRemove = false
    @State private var pickedDefaultTab = false
    @AppStorage("terminalFontSize") private var termFont: Double = 12
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case chat
    }

    private var session: SessionInfo? {
        store.session(id: sessionID)
    }

    private var screen: ScreenState? {
        terminal.screen
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let s = session {
                statusStrip(s)

                Group {
                    switch tab {
                    case .chat where s.isChat:
                        ChatThreadView(model: chat)
                    case .chat where s.isAgent:
                        ChatView(model: transcript)
                    case .changes:
                        ChangesView(cwd: s.cwd ?? "")
                    default:
                        // Tap the terminal for the keyboard; keys go straight to it (#78).
                        TerminalPane(model: terminal, fontSize: $termFont, interactive: s.isRunning)
                    }
                }
                .frame(maxHeight: .infinity)

                bottomArea(s)
            } else {
                ContentUnavailableView {
                    Label("Session ended", systemImage: "moon.zzz")
                } description: {
                    Text("This session was removed on the PC.")
                } actions: {
                    Button("Back to the board") { dismiss() }
                        .buttonStyle(SoftButtonStyle())
                        .frame(maxWidth: 240)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(session?.displayTitle ?? "Session")
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            store.sendViewing(sessionID)
            if !pickedDefaultTab {
                pickedDefaultTab = true
                // Continue opens the harness's terminal straight away (#95).
                if store.takeTerminalFirst(sessionID) || !(session?.isAgent ?? true) {
                    tab = .terminal
                }
            }
            startStreams()
        }
        .onDisappear {
            transcript.stop()
            terminal.stop()
            chat.stop()
        }
        .onChange(of: tab) { _, newTab in
            terminal.debounceNanos = newTab == .terminal ? 400_000_000 : 800_000_000
            terminal.setVisible(newTab == .terminal)
            terminal.setKeyboard(false)
            focus = nil
            Haptics.selection()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
            case .active:
                if wasInBackground {
                    // iOS suspended the sockets: attach again for a fresh snapshot
                    // (chat: replay what was missed from the last seq).
                    wasInBackground = false
                    if session?.isChat ?? false {
                        chat.resync()
                    } else {
                        terminal.resume()
                    }
                }
            default:
                break
            }
        }
        .onChange(of: store.clientGeneration) { _, _ in
            // The app switched to another address of this PC.
            transcript.stop()
            terminal.stop()
            chat.stop()
            startStreams()
        }
        .onChange(of: session?.isChat ?? false) { _, nowChat in
            // Switched between chat and terminal (here or on another device).
            transcript.stop()
            terminal.stop()
            chat.stop()
            tab = nowChat ? .chat : .terminal
            startStreams()
        }
        .onChange(of: session?.isRunning ?? false) { wasRunning, running in
            if session?.isChat ?? false {
                if running && !wasRunning { chat.resync() }
                return
            }
            if running && !wasRunning {
                terminal.reconnect()
                if let c = store.client, session?.isAgent ?? false {
                    transcript.stop()
                    transcript.start(client: c, sessionID: sessionID)
                }
            }
        }
        .confirmationDialog("Kill this session?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Kill", role: .destructive) {
                Haptics.warning()
                act { await store.kill(sessionID) }
            }
        } message: {
            Text("The process on your PC is stopped. You can restart or resume it later.")
        }
        .confirmationDialog("Remove this session?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    if let err = await store.remove(sessionID) {
                        banner = err
                    } else {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("It disappears from Aigo on every device.")
        }
        .confirmationDialog("Open in the terminal?", isPresented: $confirmTerminal, titleVisibility: .visible) {
            Button("Stop the turn and open the terminal") {
                switchMode("terminal")
            }
        } message: {
            Text("A turn is running. Switching stops it, then the same conversation continues in a terminal.")
        }
    }

    private func startStreams() {
        guard let c = store.client else { return }
        if session?.isChat ?? false {
            // A chat session has no PTY: no attach, no transcript file stream.
            chat.start(client: c, sessionID: sessionID)
            return
        }
        let running = session?.isRunning ?? false
        terminal.debounceNanos = tab == .terminal ? 400_000_000 : 800_000_000
        terminal.setVisible(tab == .terminal)
        terminal.start(client: c, sessionID: sessionID, running: running)
        if session?.isAgent ?? true {
            transcript.start(client: c, sessionID: sessionID)
        }
    }

    // MARK: - Header

    /// Calm header: back (with how many others need you), title, one muted
    /// line (state dot · state · agent · folder) and the ⋯ menu, which also
    /// holds the views (Chat / Terminal / Changes).
    private var header: some View {
        let others = othersNeedingYou
        return HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: Theme.iconWeight))
                    if others > 0 {
                        Text("\(others)")
                            .font(.aigo(size: 12, .medium))
                            .foregroundStyle(Theme.ask)
                    }
                }
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, others > 0 ? 6 : 0)
                .frame(minWidth: 40, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietPressStyle())
            .accessibilityLabel(Text(others > 0 ? "Back, \(others) more need you" : "Back"))

            VStack(alignment: .leading, spacing: 2) {
                Text(session?.displayTitle ?? "Session")
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let s = session {
                    HStack(spacing: 6) {
                        StatusDot(status: dotStatus(s), size: 6)
                        Text(metaLine(s))
                            .font(.aigo(.caption))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.2), value: metaLine(s))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let s = session, tab != mainTab(s) {
                QuietIconButton(symbol: mainTab(s) == .terminal ? "terminal" : "bubble.left",
                                label: "Back to \(mainTab(s).rawValue)") {
                    tab = mainTab(s)
                }
            }
            if switchingMode {
                ProgressView().controlSize(.small).tint(Theme.muted)
                    .frame(width: 32, height: 40)
            }
            actionsMenu
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var othersNeedingYou: Int {
        let cards = store.board[.ask] ?? []
        return cards.filter { ($0.item?.sessionId ?? $0.session?.id) != sessionID }.count
    }

    /// The view a session opens on: chat for agents, the terminal otherwise.
    private func mainTab(_ s: SessionInfo) -> SessionTab {
        (s.isChat || s.isAgent) ? .chat : .terminal
    }

    /// Views offered in the ⋯ menu (Terminal on a chat session switches its mode).
    private func tabs(_ s: SessionInfo) -> [SessionTab] {
        if s.isChat {
            return store.canSwitchMode ? [.chat, .terminal, .changes] : [.chat, .changes]
        }
        return s.isAgent ? [.chat, .terminal, .changes] : [.terminal, .changes]
    }

    private func stateWord(_ s: SessionInfo) -> String {
        if !store.pendingItems(for: sessionID).isEmpty || s.status == .needsYou { return "Needs you" }
        switch s.status {
        case .working, .stalled: return "Working"
        case .exited: return "Exited"
        default: break
        }
        if store.column(of: s) == .review { return "To review" }
        return s.isAgent ? "Idle" : "Terminal"
    }

    private func dotStatus(_ s: SessionInfo) -> SessionStatus {
        store.pendingItems(for: sessionID).isEmpty ? s.status : .needsYou
    }

    private func metaLine(_ s: SessionInfo) -> String {
        var parts = [stateWord(s), s.isExternal ? "\(s.subtitle) · outside Aigo" : s.subtitle]
        if tab != mainTab(s) { parts.append(tab.rawValue) }
        return parts.joined(separator: " · ")
    }

    /// Picks a view from the ⋯ menu.
    private func choose(_ t: SessionTab, _ s: SessionInfo) {
        if s.isChat && t == .terminal {
            Haptics.tap()
            if chat.isRunning {
                confirmTerminal = true
            } else {
                switchMode("terminal")
            }
        } else {
            tab = t
        }
    }

    /// One line: what it is doing now, with Stop (working) or Resume (exited).
    @ViewBuilder
    private func statusStrip(_ s: SessionInfo) -> some View {
        // Chat sessions: Stop sits in the composer while a turn runs.
        let active = !s.isChat && s.isRunning && (s.status == .working || s.status == .stalled)
        if active || !s.isRunning {
            HStack(spacing: 8) {
                StatusDot(status: s.status, size: 8)
                Text(active ? nowText(s) : s.nowLine)
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                Spacer(minLength: 4)
                if active {
                    Button {
                        Haptics.tap()
                        act { await store.interrupt(sessionID) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityLabel(Text("Stop turn"))
                } else {
                    Button {
                        Haptics.tap()
                        act { await store.restart(sessionID) }
                    } label: {
                        Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ChipButtonStyle(tint: Theme.accent))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .animation(.easeInOut(duration: 0.2), value: s.status)
        }
    }

    private func nowText(_ s: SessionInfo) -> String {
        if let w = screen?.working, !w.isEmpty, s.status == .working {
            return w
        }
        return s.nowLine
    }

    // MARK: - Bottom: questions, composer

    @ViewBuilder
    private func bottomArea(_ s: SessionInfo) -> some View {
        if s.isChat {
            chatBottom(s)
        } else {
            terminalBottom(s)
        }
    }

    /// Chat: requests are answered inline in the timeline; the composer
    /// sends (a stopped chat resumes on the next message).
    private func chatBottom(_ s: SessionInfo) -> some View {
        VStack(spacing: 8) {
            if let banner = banner {
                InlineBanner(text: banner) {
                    withAnimation { self.banner = nil }
                }
                .transition(.opacity)
            }
            if tab == .chat {
                ChatComposer(model: chat, placeholder: "Message \(store.agentName(s.agent))…") { err in
                    withAnimation { banner = err }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    @ViewBuilder
    private func terminalBottom(_ s: SessionInfo) -> some View {
        let pending = store.pendingItems(for: sessionID)
        VStack(spacing: 8) {
            if let banner = banner {
                InlineBanner(text: banner) {
                    withAnimation { self.banner = nil }
                }
                .transition(.opacity)
            }
            if let item = pending.first {
                AttentionCard(item: item, session: s, inSession: true,
                              position: pending.count > 1 ? "1 of \(pending.count)" : nil)
                    .id(item.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let menu = screen?.menu, let options = menu.options, !options.isEmpty, s.isRunning,
               !pending.contains(where: { $0.kind == "question" && !($0.options ?? []).isEmpty }) {
                MenuChoices(menu: menu, options: options) { option in
                    Haptics.approve()
                    act {
                        let err = await store.chooseMenu(sessionID, number: option.number, label: option.label)
                        terminal.scheduleRefresh(immediate: true)
                        return err
                    }
                }
                .transition(.opacity)
            }
            if s.isRunning && tab != .changes {
                if tab == .terminal || !s.isAgent {
                    // No compose box here: the terminal itself takes the keys (#78).
                    KeyBar(keyboardShown: terminal.keyboardShown, ctrl: terminal.ctrlLatched,
                           alt: terminal.altLatched,
                           onKeyboard: {
                               Haptics.tap()
                               terminal.setKeyboard(!terminal.keyboardShown)
                           },
                           onCtrl: {
                               Haptics.selection()
                               terminal.toggleCtrl()
                           },
                           onAlt: {
                               Haptics.selection()
                               terminal.toggleAlt()
                           }) { key in
                        Haptics.tap()
                        terminal.press(key.key)
                    }
                } else {
                    composer
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .animation(.easeInOut(duration: 0.25), value: pending.map { $0.id })
        .animation(.easeInOut(duration: 0.2), value: screen?.menu?.options?.count ?? 0)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text("›")
                .font(.aigo(.body, .medium))
                .foregroundStyle(Theme.faint)
                .frame(minHeight: 42)
            TextField("Message \(store.agentName(session?.agent))…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focus, equals: .chat)
                .submitLabel(.send)
                .textInputAutocapitalization(.sentences)
                .font(.aigo(.footnote))
                .padding(.vertical, 12)
                .foregroundStyle(Theme.text)
                .onChange(of: draft) { _, value in
                    // Return sends (the multi-line field would otherwise insert a newline).
                    if value.hasSuffix("\n") {
                        draft = String(value.dropLast())
                        send()
                    }
                }
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Group {
                    if sending {
                        ProgressView().tint(Theme.muted)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .regular))
                    }
                }
                .frame(width: 40, height: 40)
                .background(canSend ? Theme.accentBg : Theme.tint,
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .foregroundStyle(canSend ? Theme.accentInk : Theme.faint)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
            .padding(.bottom, 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .padding(.vertical, 1)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionsMenu: some View {
        Menu {
            if let s = session {
                Section("View") {
                    ForEach(tabs(s), id: \.self) { t in
                        Button {
                            choose(t, s)
                        } label: {
                            if t == tab {
                                Label(t.rawValue, systemImage: "checkmark")
                            } else if s.isChat && t == .terminal {
                                Label("Open in terminal", systemImage: "terminal")
                            } else {
                                Label(t.rawValue, systemImage: t == .terminal ? "terminal" : (t == .changes ? "arrow.triangle.branch" : "bubble.left"))
                            }
                        }
                    }
                }
                if s.isChat {
                    if chat.isRunning {
                        Button {
                            act { await chat.interrupt() }
                        } label: {
                            Label("Stop", systemImage: "stop")
                        }
                    }
                } else if store.canSwitchMode && s.canChat && !(s.agentSessionId ?? "").isEmpty {
                    Button {
                        switchMode("chat")
                    } label: {
                        Label("Back to chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                if s.isRunning && s.isChat {
                    Button(role: .destructive) {
                        confirmKill = true
                    } label: {
                        Label("Stop the harness…", systemImage: "xmark.octagon")
                    }
                } else if s.isRunning {
                    Button {
                        act { await store.stop(sessionID) }
                    } label: {
                        Label("Stop", systemImage: "stop")
                    }
                    Button {
                        act { await terminal.send("\u{03}") }
                    } label: {
                        Label("Send Ctrl-C", systemImage: "keyboard")
                    }
                    Button(role: .destructive) {
                        confirmKill = true
                    } label: {
                        Label("Kill…", systemImage: "xmark.octagon")
                    }
                } else {
                    Button {
                        act { await store.restart(sessionID) }
                    } label: {
                        Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
                    }
                }
                if store.column(of: s) == .review {
                    Button {
                        act { await store.markSeen(sessionID) }
                    } label: {
                        Label("Mark reviewed", systemImage: "checkmark")
                    }
                }
                if let cwd = s.cwd, !cwd.isEmpty {
                    Button {
                        UIPasteboard.general.string = cwd
                        Haptics.success()
                    } label: {
                        Label("Copy folder path", systemImage: "doc.on.doc")
                    }
                }
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove session…", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: Theme.iconWeight))
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Views and session actions"))
    }

    // MARK: - Behaviour

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        banner = nil
        Haptics.tap()
        Task {
            if let err = await store.sendPrompt(sessionID, text) {
                Haptics.error()
                withAnimation { banner = err }
            } else {
                draft = ""
            }
            sending = false
            terminal.scheduleRefresh()
        }
    }

    /// POST /sessions/{id}/mode; the view follows the session's new mode.
    private func switchMode(_ mode: String) {
        guard !switchingMode else { return }
        switchingMode = true
        banner = nil
        Task {
            if let err = await store.setMode(sessionID, mode) {
                Haptics.error()
                withAnimation { banner = err }
            }
            switchingMode = false
        }
    }

    private func act(_ op: @escaping () async -> String?) {
        banner = nil
        Task {
            if let err = await op() {
                Haptics.error()
                withAnimation { banner = err }
            }
        }
    }
}

/// Options of a menu the agent shows in its terminal, as buttons.
struct MenuChoices: View {
    let menu: ScreenMenu
    let options: [MenuOption]
    let onChoose: (MenuOption) -> Void

    private var title: String? { menu.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text((title ?? "").isEmpty ? "The agent is asking" : title!)
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.ask)
                    .lineLimit(3)
                if let note = menu.guidance {
                    MenuNote(text: note)
                }
            }
            if options.count > 4 {
                ScrollView {
                    optionList
                }
                .frame(maxHeight: 220)
            } else {
                optionList
            }
        }
        .padding(10)
        .aigoCard(border: Theme.askLine, fill: Theme.askSoft)
    }

    private var optionList: some View {
        VStack(spacing: 6) {
            ForEach(options) { option in
                Button {
                    onChoose(option)
                } label: {
                    MenuOptionLabel(label: option.label, recommended: menu.isRecommended(option))
                }
                .buttonStyle(SecondaryButtonStyle(alignment: .leading))
                .accessibilityHint(menu.isRecommended(option) ? Text("Recommended") : Text(""))
            }
        }
    }
}

/// Terminal keys for shells and TUIs (encoded by SwiftTerm), plus the
/// keyboard toggle and Ctrl / Alt latches that apply to the next key, from
/// this bar or the keyboard.
struct KeyBar: View {
    var keyboardShown = false
    var ctrl = false
    var alt = false
    var onKeyboard: () -> Void = {}
    var onCtrl: () -> Void = {}
    var onAlt: () -> Void = {}
    let onKey: (TerminalKeys.Key) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onKeyboard) {
                Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 16, weight: Theme.iconWeight))
                    .foregroundStyle(keyboardShown ? Theme.accentInk : Theme.accentText)
                    .frame(width: 44, height: 40)
                    .background(keyboardShown ? Theme.accentBg : Theme.accentSoft,
                                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(keyboardShown ? "Hide keyboard" : "Type in the terminal"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    latch("Ctrl", on: ctrl, accessibility: "Control, applies to the next key", action: onCtrl)
                    latch("Alt", on: alt, accessibility: "Alt, applies to the next key", action: onAlt)
                    ForEach(TerminalKeys.bar) { k in
                        Button {
                            onKey(k)
                        } label: {
                            Text(k.label)
                                .font(.aigoMono(size: 14, .medium))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 10)
                                .frame(minWidth: 40, minHeight: 40)
                                .background(Theme.tint, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(k.accessibility))
                    }
                }
            }
        }
    }

    private func latch(_ title: String, on: Bool, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.aigo(.callout, .medium))
                .foregroundStyle(on ? Theme.accentInk : Theme.text)
                .padding(.horizontal, 10)
                .frame(minWidth: 40, minHeight: 40)
                .background(on ? Theme.accentBg : Theme.tint,
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Changes tab: `git status` of the session's folder; tap a file for its diff.
struct ChangesView: View {
    let cwd: String

    @EnvironmentObject private var store: AppStore
    @State private var status: GitStatus?
    @State private var problem: String?
    @State private var loading = false
    @State private var expandedPath: String?
    @State private var diffs: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if cwd.isEmpty {
                    note("No folder for this session.")
                } else if let problem = problem {
                    note(problem)
                } else if let status = status {
                    summary(status)
                    let files = status.files ?? []
                    if files.isEmpty {
                        note("No changes yet.")
                    }
                    ForEach(files) { file in
                        fileRow(file)
                    }
                } else {
                    ProgressView().tint(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .refreshable { await load() }
        .task(id: cwd) { await load() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.aigo(.footnote))
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }

    private func summary(_ s: GitStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Text(s.branch ?? "")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            let n = s.files?.count ?? 0
            Text(n == 1 ? "1 file" : "\(n) files")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.muted)
            Text("+\(s.added ?? 0)").font(.aigo(.caption)).foregroundStyle(Theme.add)
            Text("−\(s.deleted ?? 0)").font(.aigo(.caption)).foregroundStyle(Theme.danger)
        }
        .padding(.bottom, 4)
    }

    private func fileRow(_ file: GitFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                if expandedPath == file.path {
                    expandedPath = nil
                } else {
                    expandedPath = file.path
                    if diffs[file.path] == nil {
                        Task { await loadDiff(file.path) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(file.letter)
                        .font(.aigo(.caption, .medium))
                        .foregroundStyle(file.letter == "D" ? Theme.danger : (file.letter == "?" || file.letter == "A" ? Theme.add : Theme.review))
                        .frame(width: 14)
                    Text(file.path)
                        .font(.aigo(.caption))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if file.binary != true {
                        Text("+\(file.added ?? 0)").font(.aigo(.caption2)).foregroundStyle(Theme.add)
                        Text("−\(file.deleted ?? 0)").font(.aigo(.caption2)).foregroundStyle(Theme.danger)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: Theme.buttonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedPath == file.path {
                diffView(diffs[file.path])
            }
        }
        .aigoCard()
    }

    @ViewBuilder
    private func diffView(_ diff: String?) -> some View {
        if let diff = diff {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ChangesView.lines(diff).enumerated()), id: \.offset) { pair in
                        Text(pair.element.isEmpty ? " " : pair.element)
                            .font(.custom(TerminalScreen.fontName, fixedSize: 11))
                            .foregroundStyle(ChangesView.color(pair.element))
                            .fixedSize()
                    }
                }
                .padding(10)
            }
            .background(Theme.term)
            .textSelection(.enabled)
        } else {
            ProgressView().tint(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(10)
        }
    }

    static func lines(_ diff: String) -> [String] {
        let all = diff.components(separatedBy: "\n")
        let body = all.drop { !$0.hasPrefix("@@") }
        let shown = body.isEmpty ? Array(all) : Array(body)
        return Array(shown.prefix(400))
    }

    static func color(_ line: String) -> Color {
        if line.hasPrefix("+") { return Theme.add }
        if line.hasPrefix("-") { return Theme.danger }
        if line.hasPrefix("@@") { return Theme.review }
        return Theme.muted
    }

    private func load() async {
        guard !cwd.isEmpty, let c = store.client else { return }
        loading = true
        do {
            status = try await c.gitStatus(cwd: cwd)
            problem = nil
            diffs = [:]
            if let o = expandedPath { await loadDiff(o) }
        } catch let e as APIError where e.status == 422 {
            problem = "This folder is not a git repository."
        } catch {
            problem = c.problem(for: error).message
        }
        loading = false
    }

    private func loadDiff(_ path: String) async {
        guard let c = store.client else { return }
        let d = (try? await c.gitDiff(cwd: cwd, path: path)) ?? ""
        diffs[path] = d.isEmpty ? "(no textual diff — new or binary file)" : d
    }
}

/// One muted line of guidance under a menu's question (issue #6).
struct MenuNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.aigo(.caption))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(Text("Note: \(text)"))
    }
}

/// A menu option's label, with a small "recommended" tag (never preselected).
struct MenuOptionLabel: View {
    let label: String
    let recommended: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            if recommended {
                Text("recommended")
                    .font(.aigo(size: 10, .medium))
                    .foregroundStyle(Theme.accentText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.accentLine, lineWidth: 1))
            }
        }
    }
}
