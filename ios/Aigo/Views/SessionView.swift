import SwiftUI

enum SessionTab: Hashable {
    case chat
    case terminal
}

struct SessionView: View {
    let sessionID: String

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transcript = TranscriptModel()
    @State private var tab: SessionTab = .chat
    @State private var screen: ScreenState?
    @State private var draft = ""
    @State private var sending = false
    @State private var banner: String?
    @State private var confirmKill = false
    @State private var confirmRemove = false
    @State private var pickedDefaultTab = false

    private var session: SessionInfo? {
        store.session(id: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let s = session {
                statusStrip(s)
                if s.isAgent {
                    Picker("View", selection: $tab) {
                        Text("Chat").tag(SessionTab.chat)
                        Text("Terminal").tag(SessionTab.terminal)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                Rectangle().fill(Theme.line).frame(height: 1)

                Group {
                    if tab == .chat && s.isAgent {
                        ChatView(model: transcript)
                    } else {
                        TerminalView(text: screen?.text ?? "")
                    }
                }
                .frame(maxHeight: .infinity)

                bottomArea(s)
            } else {
                ContentUnavailableView("Session ended",
                                       systemImage: "moon.zzz",
                                       description: Text("This session was removed on the PC."))
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(session?.displayTitle ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu
            }
        }
        .task(id: sessionID) {
            await pollScreen()
        }
        .onAppear {
            store.sendViewing(sessionID)
            if !pickedDefaultTab {
                pickedDefaultTab = true
                if let s = session, !s.isAgent {
                    tab = .terminal
                }
            }
            if let c = store.client, session?.isAgent ?? true {
                transcript.start(client: c, sessionID: sessionID)
            }
        }
        .onDisappear {
            transcript.stop()
        }
        .confirmationDialog("Kill this session?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Kill", role: .destructive) {
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

    // MARK: - Pieces

    private func statusStrip(_ s: SessionInfo) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: s.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(nowText(s))
                    .font(.footnote)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer()
            if s.isRunning && (s.status == .working || s.status == .stalled) {
                Button {
                    act { await store.interrupt(sessionID) }
                } label: {
                    Label("Stop turn", systemImage: "stop.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Theme.surface2, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
            } else if !s.isRunning {
                Button {
                    act { await store.restart(sessionID) }
                } label: {
                    Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Theme.lime, in: Capsule())
                        .foregroundStyle(Theme.bg)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func nowText(_ s: SessionInfo) -> String {
        if let w = screen?.working, !w.isEmpty, s.status == .working {
            return w
        }
        return s.nowLine
    }

    @ViewBuilder
    private func bottomArea(_ s: SessionInfo) -> some View {
        VStack(spacing: 8) {
            if let banner = banner {
                InlineBanner(text: banner) {
                    self.banner = nil
                }
            }
            if let menu = screen?.menu, let options = menu.options, !options.isEmpty, s.isRunning {
                MenuChoices(title: menu.title, options: options) { option in
                    act {
                        let err = await store.chooseMenu(sessionID, number: option.number, label: option.label)
                        await refreshScreen()
                        return err
                    }
                }
            }
            if tab == .terminal || !s.isAgent {
                KeyBar { key in
                    act { await store.sendKeys(sessionID, [key]) }
                }
            }
            if s.isRunning {
                composer
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(tab == .terminal ? "Type a command" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textInputAutocapitalization(tab == .terminal ? TextInputAutocapitalization.never : TextInputAutocapitalization.sentences)
                .autocorrectionDisabled(tab == .terminal)
                .font(tab == .terminal ? Theme.mono : .body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Theme.text)
            Button {
                send()
            } label: {
                Group {
                    if sending {
                        ProgressView().tint(Theme.bg)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                    }
                }
                .frame(width: 44, height: 44)
                .background(canSend ? Theme.lime : Theme.surface2, in: Circle())
                .foregroundStyle(canSend ? Theme.bg : Theme.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
        }
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
                    Button(role: .destructive) {
                        confirmKill = true
                    } label: {
                        Label("Kill", systemImage: "xmark.octagon")
                    }
                } else {
                    Button {
                        act { await store.restart(sessionID) }
                    } label: {
                        Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove session", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text("Session actions"))
    }

    // MARK: - Behaviour

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        banner = nil
        Task {
            if let err = await store.sendPrompt(sessionID, text) {
                banner = err
            } else {
                draft = ""
            }
            sending = false
            await refreshScreen()
        }
    }

    private func act(_ op: @escaping () async -> String?) {
        banner = nil
        Task {
            if let err = await op() {
                banner = err
            }
        }
    }

    private func refreshScreen() async {
        guard let c = store.client else { return }
        if let s = try? await c.screen(sessionID) {
            screen = s
        }
    }

    /// Polls the screen endpoint while visible: every second on the
    /// Terminal tab, every two on Chat (menu detection).
    private func pollScreen() async {
        while !Task.isCancelled {
            if session?.isRunning ?? false || screen == nil {
                await refreshScreen()
            }
            let interval: UInt64 = tab == .terminal ? 1_000_000_000 : 2_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }
}

/// Options of a menu the agent shows in its terminal.
struct MenuChoices: View {
    let title: String?
    let options: [MenuOption]
    let onChoose: (MenuOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.coral).frame(width: 7, height: 7)
                Text((title ?? "").isEmpty ? "The agent is asking" : title!)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
            }
            if options.count > 4 {
                ScrollView {
                    optionList
                }
                .frame(height: 220)
            } else {
                optionList
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.coral.opacity(0.35), lineWidth: 1))
    }

    private var optionList: some View {
        VStack(spacing: 6) {
            ForEach(options) { option in
                Button {
                    onChoose(option)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(option.number).")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.secondary)
                        Text(option.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
    }
}

/// Terminal keys for TUIs (named keys accepted by internal/sessions/keys.go).
struct KeyBar: View {
    struct KeyDef: Identifiable {
        let label: String
        let key: String
        var id: String { key }
    }

    let onKey: (String) -> Void

    private static let keys: [KeyDef] = [
        KeyDef(label: "Esc", key: "Escape"),
        KeyDef(label: "Tab", key: "Tab"),
        KeyDef(label: "↑", key: "Up"),
        KeyDef(label: "↓", key: "Down"),
        KeyDef(label: "←", key: "Left"),
        KeyDef(label: "→", key: "Right"),
        KeyDef(label: "Enter", key: "Enter"),
        KeyDef(label: "Ctrl-C", key: "C-c"),
        KeyDef(label: "1", key: "1"),
        KeyDef(label: "2", key: "2"),
        KeyDef(label: "3", key: "3"),
        KeyDef(label: "y", key: "y"),
        KeyDef(label: "n", key: "n"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(KeyBar.keys) { k in
                    Button {
                        onKey(k.key)
                    } label: {
                        Text(k.label)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 44, minHeight: 40)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
