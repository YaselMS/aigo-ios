import SwiftUI
import UIKit

enum SessionTab: String, Hashable, CaseIterable {
    case chat = "Chat"
    case terminal = "Terminal"
    case changes = "Changes"
}

/// The conversation: "‹" back to the board, title + state pill, Chat /
/// Terminal / Changes tabs, agent questions as option buttons, composer.
struct SessionView: View {
    let sessionID: String

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transcript = TranscriptModel()
    @StateObject private var terminal = TerminalModel()
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
                tabBar(s)
                statusStrip(s)

                Group {
                    switch tab {
                    case .chat where s.isAgent:
                        ChatView(model: transcript)
                    case .changes:
                        ChangesView(cwd: s.cwd ?? "")
                    default:
                        // Tap the terminal for the keyboard; keys go straight to it (#78).
                        TerminalPane(model: terminal, fontSize: $termFont,
                                     onInput: s.isRunning ? typeInTerminal : nil)
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
                if let s = session, !s.isAgent {
                    tab = .terminal
                }
            }
            startStreams()
        }
        .onDisappear {
            transcript.stop()
            terminal.stop()
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
                    // iOS suspended the sockets: attach again for a fresh snapshot.
                    wasInBackground = false
                    terminal.resume()
                }
            default:
                break
            }
        }
        .onChange(of: store.clientGeneration) { _, _ in
            // The app switched to another address of this PC.
            transcript.stop()
            terminal.stop()
            startStreams()
        }
        .onChange(of: session?.isRunning ?? false) { wasRunning, running in
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
    }

    private func startStreams() {
        guard let c = store.client else { return }
        let running = session?.isRunning ?? false
        terminal.debounceNanos = tab == .terminal ? 400_000_000 : 800_000_000
        terminal.setVisible(tab == .terminal)
        terminal.start(client: c, sessionID: sessionID, running: running)
        if session?.isAgent ?? true {
            transcript.start(client: c, sessionID: sessionID)
        }
    }

    // MARK: - Header

    /// "‹" back to the board (with how many others need you), title,
    /// "agent · folder", the state pill and the actions menu.
    private var header: some View {
        let others = othersNeedingYou
        return HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    if others > 0 {
                        Text("\(others)")
                            .font(.aigo(size: 12, .semibold))
                            .foregroundStyle(Theme.coral)
                    }
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, others > 0 ? 8 : 0)
                .frame(minWidth: 40, minHeight: 40)
                .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(others > 0 ? "Back to the board, \(others) more need you" : "Back to the board"))

            VStack(alignment: .leading, spacing: 2) {
                Text(session?.displayTitle ?? "Session")
                    .font(.aigo(.callout, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let s = session {
                    Text(s.isExternal ? "\(s.subtitle) · outside Aigo" : s.subtitle)
                        .font(.aigo(.caption2))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let s = session {
                statePill(s)
            }
            actionsMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
        }
    }

    private var othersNeedingYou: Int {
        let cards = store.board[.ask] ?? []
        return cards.filter { ($0.item?.sessionId ?? $0.session?.id) != sessionID }.count
    }

    private func pill(for s: SessionInfo) -> (String, Color, Color) {
        if !store.pendingItems(for: sessionID).isEmpty || s.status == .needsYou {
            return ("Needs you", Theme.coralText, Color(aigoHex: 0x2A1712))
        }
        switch s.status {
        case .working, .stalled: return ("Working", Theme.lime, Color(aigoHex: 0x1E2410))
        case .exited: return ("Exited", Theme.secondary, Theme.surface2)
        default: break
        }
        if store.column(of: s) == .review {
            return ("Review", Theme.iceText, Theme.ice.opacity(0.14))
        }
        return (s.isAgent ? "Idle" : "Terminal", Theme.secondary, Theme.surface2)
    }

    private func statePill(_ s: SessionInfo) -> some View {
        let p = pill(for: s)
        return Text(p.0)
            .font(.aigo(size: 11))
            .foregroundStyle(p.1)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(p.2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .animation(.easeInOut(duration: 0.2), value: p.0)
    }

    private func tabBar(_ s: SessionInfo) -> some View {
        let tabs: [SessionTab] = s.isAgent ? [.chat, .terminal, .changes] : [.terminal, .changes]
        return HStack(spacing: 6) {
            ForEach(tabs, id: \.self) { t in
                let on = t == tab
                Button {
                    tab = t
                } label: {
                    Text(t.rawValue)
                        .font(.aigo(.footnote, on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.bg : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
                        .background(on ? Theme.text : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(on ? Color.clear : Color(aigoHex: 0x2A2D31), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One line: what it is doing now, with Stop (working) or Resume (exited).
    @ViewBuilder
    private func statusStrip(_ s: SessionInfo) -> some View {
        let active = s.isRunning && (s.status == .working || s.status == .stalled)
        if active || !s.isRunning {
            HStack(spacing: 8) {
                StatusDot(status: s.status, size: 8)
                Text(active ? nowText(s) : s.nowLine)
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
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
                    .buttonStyle(ChipButtonStyle(tint: Theme.lime))
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
                           onKeyboard: {
                               Haptics.tap()
                               terminal.setKeyboard(!terminal.keyboardShown)
                           },
                           onCtrl: {
                               Haptics.selection()
                               terminal.ctrlLatched.toggle()
                           }) { key in
                        Haptics.tap()
                        typeInTerminal(key.bytes)
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
                .font(.aigo(.body, .bold))
                .foregroundStyle(Theme.lime)
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
                        ProgressView().tint(Theme.lime)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .frame(width: 40, height: 40)
                .background(Theme.lime.opacity(canSend ? 0.15 : 0.06),
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .foregroundStyle(canSend ? Theme.lime : Theme.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
            .padding(.bottom, 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .padding(.vertical, 1)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Color(aigoHex: 0x2A2D31), lineWidth: 1))
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionsMenu: some View {
        Menu {
            if let s = session {
                if s.isRunning {
                    Button {
                        act { await store.interrupt(sessionID) }
                    } label: {
                        Label("Stop turn", systemImage: "stop.circle")
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
                        Label("Looks good", systemImage: "checkmark")
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Session actions"))
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

    /// A keystroke typed into the terminal canvas.
    private func typeInTerminal(_ text: String) {
        let bytes = terminal.keystroke(text)
        if terminal.sendNow(bytes) { return }
        act { await terminal.send(bytes) }
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
                    .foregroundStyle(Theme.coralText)
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
        .aigoCard(border: Theme.coral, fill: Theme.coralWash)
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

/// Terminal keys for shells and TUIs, sent as raw bytes, plus the keyboard
/// toggle and a Ctrl latch for the soft keyboard.
struct KeyBar: View {
    var keyboardShown = false
    var ctrl = false
    var onKeyboard: () -> Void = {}
    var onCtrl: () -> Void = {}
    let onKey: (TerminalKeys.Key) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onKeyboard) {
                Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(keyboardShown ? Theme.bg : Theme.lime)
                    .frame(width: 44, height: 40)
                    .background(keyboardShown ? Theme.lime : Theme.lime.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(keyboardShown ? "Hide keyboard" : "Type in the terminal"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button(action: onCtrl) {
                        Text("Ctrl")
                            .font(.aigo(.callout, .semibold))
                            .foregroundStyle(ctrl ? Theme.bg : Theme.text)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 40, minHeight: 40)
                            .background(ctrl ? Theme.lime : Theme.softWhite,
                                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Control, applies to the next key"))
                    .accessibilityAddTraits(ctrl ? .isSelected : [])
                    ForEach(TerminalKeys.bar) { k in
                        Button {
                            onKey(k)
                        } label: {
                            Text(k.label)
                                .font(.aigo(.callout, .semibold))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 10)
                                .frame(minWidth: 40, minHeight: 40)
                                .background(Theme.softWhite, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(k.accessibility))
                    }
                }
            }
        }
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
                    ProgressView().tint(Theme.secondary)
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
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }

    private func summary(_ s: GitStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Text(s.branch ?? "")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            let n = s.files?.count ?? 0
            Text(n == 1 ? "1 file" : "\(n) files")
                .font(.aigo(.caption))
                .foregroundStyle(Theme.secondary)
            Text("+\(s.added ?? 0)").font(.aigo(.caption)).foregroundStyle(Theme.lime)
            Text("−\(s.deleted ?? 0)").font(.aigo(.caption)).foregroundStyle(Theme.coral)
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
                        .font(.aigo(.caption, .bold))
                        .foregroundStyle(file.letter == "D" ? Theme.coral : (file.letter == "?" || file.letter == "A" ? Theme.lime : Theme.ice))
                        .frame(width: 14)
                    Text(file.path)
                        .font(.aigo(.caption))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if file.binary != true {
                        Text("+\(file.added ?? 0)").font(.aigo(.caption2)).foregroundStyle(Theme.lime)
                        Text("−\(file.deleted ?? 0)").font(.aigo(.caption2)).foregroundStyle(Theme.coral)
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
            .background(Theme.codeBg)
            .textSelection(.enabled)
        } else {
            ProgressView().tint(Theme.secondary)
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
        if line.hasPrefix("+") { return Theme.lime }
        if line.hasPrefix("-") { return Theme.coralText }
        if line.hasPrefix("@@") { return Theme.ice }
        return Theme.secondary
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
            .foregroundStyle(Theme.secondary)
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
                    .font(.aigo(size: 10, .semibold))
                    .foregroundStyle(Theme.lime)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.lime.opacity(0.45), lineWidth: 1))
            }
        }
    }
}
