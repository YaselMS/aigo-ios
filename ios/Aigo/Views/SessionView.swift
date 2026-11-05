import SwiftUI
import UIKit

enum SessionTab: Hashable {
    case chat
    case terminal
}

struct SessionView: View {
    let sessionID: String

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transcript = TranscriptModel()
    @StateObject private var terminal = TerminalModel()
    @State private var tab: SessionTab = .chat
    @State private var draft = ""
    @State private var termLine = ""
    @State private var sending = false
    @State private var banner: String?
    @State private var confirmKill = false
    @State private var confirmRemove = false
    @State private var pickedDefaultTab = false
    @AppStorage("terminalFontSize") private var termFont: Double = 12
    @AppStorage("terminalFit") private var termFit = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case chat
        case terminal
    }

    private var session: SessionInfo? {
        store.session(id: sessionID)
    }

    private var screen: ScreenState? {
        terminal.screen
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
                        TerminalPane(model: terminal, fontSize: $termFont, fit: fitBinding)
                            .onTapGesture {
                                focus = .terminal
                            }
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
                    Button("Back to Home") { dismiss() }
                        .buttonStyle(FilledButtonStyle())
                        .frame(maxWidth: 240)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(session?.displayTitle ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu
            }
        }
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
            terminal.debounceNanos = newTab == .terminal ? 150_000_000 : 600_000_000
            terminal.setFit(newTab == .terminal && termFit)
            focus = nil
            Haptics.selection()
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

    private var fitBinding: Binding<Bool> {
        Binding(get: { termFit }, set: { on in
            termFit = on
            terminal.setFit(on)
        })
    }

    private func startStreams() {
        guard let c = store.client else { return }
        let running = session?.isRunning ?? false
        terminal.debounceNanos = tab == .terminal ? 150_000_000 : 600_000_000
        terminal.start(client: c, sessionID: sessionID, running: running)
        if tab == .terminal && termFit {
            terminal.setFit(true)
        }
        if session?.isAgent ?? true {
            transcript.start(client: c, sessionID: sessionID)
        }
    }

    // MARK: - Pieces

    private func statusStrip(_ s: SessionInfo) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: s.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.subtitle)
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(nowText(s))
                    .font(.footnote)
                    .foregroundStyle(s.status == .needsYou ? Theme.coralText : Theme.text)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            if s.isRunning && (s.status == .working || s.status == .stalled) {
                Button {
                    Haptics.tap()
                    act { await store.interrupt(sessionID) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel(Text("Stop turn"))
            } else if !s.isRunning {
                Button {
                    Haptics.tap()
                    act { await store.restart(sessionID) }
                } label: {
                    Label(s.isAgent ? "Resume" : "Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ChipButtonStyle(fill: Theme.lime, foreground: Theme.onAccent))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: s.status)
    }

    private func nowText(_ s: SessionInfo) -> String {
        if let w = screen?.working, !w.isEmpty, s.status == .working {
            return w
        }
        return s.nowLine
    }

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
                AttentionCard(item: item, swipeEnabled: false,
                              position: pending.count > 1 ? "1 of \(pending.count)" : nil,
                              inSession: true)
                    .id(item.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let menu = screen?.menu, let options = menu.options, !options.isEmpty, s.isRunning,
               !pending.contains(where: { $0.kind == "question" && !($0.options ?? []).isEmpty }) {
                MenuChoices(title: menu.title, options: options) { option in
                    Haptics.approve()
                    act {
                        let err = await store.chooseMenu(sessionID, number: option.number, label: option.label)
                        terminal.scheduleRefresh(immediate: true)
                        return err
                    }
                }
                .transition(.opacity)
            }
            if s.isRunning {
                if tab == .terminal || !s.isAgent {
                    KeyBar { key in
                        Haptics.tap()
                        act { await terminal.send(key.bytes) }
                    }
                    terminalField
                } else {
                    composer
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .animation(.easeInOut(duration: 0.25), value: pending.map { $0.id })
        .animation(.easeInOut(duration: 0.2), value: screen?.menu?.options?.count ?? 0)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focus, equals: .chat)
                .submitLabel(.send)
                .textInputAutocapitalization(.sentences)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
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
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline.weight(.bold))
                    }
                }
                .frame(width: 46, height: 46)
                .background(canSend ? Theme.lime : Theme.surface2, in: Circle())
                .foregroundStyle(canSend ? Theme.onAccent : Theme.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
        }
    }

    /// One line of shell input; Return sends it (plus Enter) as raw bytes.
    private var terminalField: some View {
        HStack(spacing: 8) {
            Text("›")
                .font(.system(.body, design: .monospaced).weight(.bold))
                .foregroundStyle(Theme.lime)
            TextField("Type and press Return", text: $termLine)
                .focused($focus, equals: .terminal)
                .font(Theme.mono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.send)
                .foregroundStyle(Theme.text)
                .onSubmit {
                    sendTerminalLine()
                }
            Button {
                sendTerminalLine()
            } label: {
                Image(systemName: "return")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 40)
                    .background(Theme.lime, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Send line"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
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
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
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

    private func sendTerminalLine() {
        let line = termLine
        termLine = ""
        focus = .terminal
        act { await terminal.send(line + "\r") }
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

/// Options of a menu the agent shows in its terminal.
struct MenuChoices: View {
    let title: String?
    let options: [MenuOption]
    let onChoose: (MenuOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.coral).frame(width: 8, height: 8)
                Text((title ?? "").isEmpty ? "The agent is asking" : title!)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.coralText)
                    .lineLimit(3)
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
        .padding(12)
        .aigoCard(border: Theme.coral.opacity(0.6), fill: Theme.coralWash)
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
                .buttonStyle(OutlineButtonStyle(border: Theme.coralLine))
            }
        }
    }
}

/// Terminal keys for shells and TUIs, sent as raw bytes.
struct KeyBar: View {
    let onKey: (TerminalKeys.Key) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TerminalKeys.bar) { k in
                    Button {
                        onKey(k)
                    } label: {
                        Text(k.label)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(k.accessibility))
                }
            }
        }
    }
}
