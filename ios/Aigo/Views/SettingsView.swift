import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showPair = false
    @State private var forgetting: HostCredentials?
    /// Version label next to the wordmark on Home (#67).
    @AppStorage("showVersionLabel") private var showVersion = true

    var body: some View {
        Form {
            Section {
                ForEach(store.hosts) { host in
                    Button {
                        store.activate(host.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.hostName.isEmpty ? "PC" : host.hostName)
                                    .foregroundStyle(Theme.text)
                                Text(host.addr)
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if host.id == store.activeHostID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) {
                            forgetting = host
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            forgetting = host
                        } label: {
                            Label("Forget this PC", systemImage: "trash")
                        }
                    }
                }
                Button {
                    showPair = true
                } label: {
                    Label("Pair a new PC", systemImage: "plus")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("Paired PCs")
            } footer: {
                Text("Wi-Fi and Tailscale use the same pairing; no need to revoke this phone to switch networks. Tap a PC to switch to it. Swipe left to forget it.")
            }
            .listRowBackground(Theme.panel)

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(store.connection.dotColor).frame(width: 7, height: 7)
                        Text(connectionText)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if store.connectionProblem != nil {
                    if store.connectionProblem?.needsRepair != true {
                    Button {
                        Haptics.tap()
                        store.retry()
                    } label: {
                        Label("Retry now", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    }
                    if store.connectionProblem?.needsRepair == true {
                        Button {
                            store.repairActiveHost()
                        } label: {
                            Label("Pair again", systemImage: "qrcode.viewfinder")
                                .frame(minHeight: 44)
                        }
                    }
                }
                if let host = store.activeHost {
                    LabeledContent("Address in use") {
                        Text(store.activeAddress ?? host.addr)
                            .font(Theme.small)
                            .multilineTextAlignment(.trailing)
                    }
                    let others = host.endpoints.filter { $0 != (store.activeAddress ?? host.addr) }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Other addresses (tried in order if this one stops answering)")
                                .font(.aigo(.footnote))
                                .foregroundStyle(Theme.muted)
                            ForEach(others, id: \.self) { a in
                                HStack(spacing: 6) {
                                    Text(a).font(Theme.small).foregroundStyle(Theme.text)
                                    if HostAddress.isTailscale(a) {
                                        Text("Tailscale")
                                            .font(.aigo(size: 10, .semibold))
                                            .foregroundStyle(Theme.review)
                                    } else if HostAddress.isLAN(a) {
                                        Text("local network")
                                            .font(.aigo(size: 10))
                                            .foregroundStyle(Theme.muted)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    LabeledContent("Fingerprint") {
                        Text(String(host.fingerprint.prefix(16)) + "…").font(Theme.small)
                    }
                    Button {
                        Haptics.tap()
                        store.showDesktop = true
                    } label: {
                        Label("View screen", systemImage: "display")
                            .frame(minHeight: 44)
                    }
                    .disabled(store.client == nil)
                }
            }
            .listRowBackground(Theme.panel)

            appearanceSection

            Section("Alerts") {
                Text("Aigo shows banners and a Live Activity while the app is open or was used recently. iOS pauses the connection after that.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
                Text("For alerts when the app is closed, turn on the ntfy notifications on your PC (Aigo → Settings → Notifications) and install the ntfy app on this iPhone, subscribed to the same topic.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.panel)

            Section("About") {
                LabeledContent("Version", value: SettingsView.versionString)
                if updates.updateAvailable {
                    UpdateNotice()
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } else {
                    Button {
                        Task { await updates.checkIfDue(force: true) }
                    } label: {
                        HStack {
                            Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if updates.checking {
                                ProgressView().controlSize(.small)
                            } else if updates.latestTag != nil {
                                Text("Up to date")
                                    .font(.aigo(.footnote))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(updates.checking)
                    if let err = updates.lastError {
                        Text(err)
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Text("Aigo controls the coding agents and terminals running on your PC.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .sheet(isPresented: $showPair) {
            NavigationStack {
                PairView(draft: nil, onDone: {
                    showPair = false
                })
                .navigationTitle("Pair a PC")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showPair = false }
                    }
                }
            }
            .environmentObject(store)
            .preferredColorScheme(appearance.colorScheme)
        }
        .confirmationDialog("Forget this PC?",
                            isPresented: Binding(get: { forgetting != nil },
                                                 set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let host = forgetting {
                    store.forget(host.id)
                }
                forgetting = nil
            }
        } message: {
            Text("You will need a new pairing code to connect to it again.")
        }
    }

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(AigoThemeID.allCases) { t in
                    ThemeSwatch(theme: t, selected: t == appearance.theme) {
                        Haptics.selection()
                        appearance.setTheme(t)
                    }
                }
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 8) {
                Text("Text size")
                    .foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    ForEach(AigoTextSize.allCases) { size in
                        let on = size == appearance.size
                        Button {
                            Haptics.selection()
                            appearance.size = size
                        } label: {
                            Text(size.label)
                                .font(.aigo(.footnote, on ? .medium : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.muted)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(on ? Theme.sel : Theme.tint,
                                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(size.label))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 6)
            Picker(selection: Binding(get: { appearance.family }, set: { appearance.family = $0 })) {
                ForEach(AigoFontFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            } label: {
                Text("Code font")
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.muted)
            Toggle(isOn: $showVersion) {
                Text("Show version")
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.accentBg)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The code font is used for code, diffs, tool output and the terminal. Show version puts the app version next to the name on Home; tap it there to hide it again.")
        }
        .listRowBackground(Theme.panel)
    }

    private var connectionText: String {
        switch store.connection {
        case .unpaired: return "Not paired"
        case .connecting: return "Connecting…"
        case .online: return "Connected"
        case .offline(let problem): return problem.message
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// A theme choice in Settings → Appearance: a tiny preview in the theme's
/// own colours (background, a panel row, the accent) and its name.
struct ThemeSwatch: View {
    let theme: AigoThemeID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let t = theme.tokens
        Button(action: action) {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(aigoHex: t.ask)).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Color(aigoHex: t.text, opacity: 0.8)).frame(width: 30, height: 4)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color(aigoHex: t.work)).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Color(aigoHex: t.muted, opacity: 0.8)).frame(width: 22, height: 4)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(aigoHex: t.accentBg))
                        .frame(width: 26, height: 8)
                        .padding(.top, 2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 54)
                .background(Color(aigoHex: t.panel), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(5)
                .background(Color(aigoHex: t.bg), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
                Text(theme.displayName)
                    .font(.aigo(.footnote, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text("\(theme.displayName) theme"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
