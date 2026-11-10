import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showPair = false
    @State private var forgetting: HostCredentials?

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
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if host.id == store.activeHostID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.lime)
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
                Text("Tap a PC to switch to it. Swipe left to forget it. To fully revoke this phone, remove it on the PC under Settings → Devices.")
            }
            .listRowBackground(Theme.surface)

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(store.connection.dotColor).frame(width: 7, height: 7)
                        Text(connectionText)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if store.connectionProblem != nil {
                    Button {
                        Haptics.tap()
                        store.retry()
                    } label: {
                        Label("Retry now", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
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
                            .font(Theme.monoSmall)
                            .multilineTextAlignment(.trailing)
                    }
                    let others = host.endpoints.filter { $0 != (store.activeAddress ?? host.addr) }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Other addresses (tried in order if this one stops answering)")
                                .font(.aigo(.footnote))
                                .foregroundStyle(Theme.secondary)
                            ForEach(others, id: \.self) { a in
                                HStack(spacing: 6) {
                                    Text(a).font(Theme.monoSmall).foregroundStyle(Theme.text)
                                    if HostAddress.isTailscale(a) {
                                        Text("Tailscale")
                                            .font(.aigo(size: 10, .semibold))
                                            .foregroundStyle(Theme.iceText)
                                    } else if HostAddress.isLAN(a) {
                                        Text("local network")
                                            .font(.aigo(size: 10))
                                            .foregroundStyle(Theme.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    LabeledContent("Fingerprint") {
                        Text(String(host.fingerprint.prefix(16)) + "…").font(Theme.monoSmall)
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
            .listRowBackground(Theme.surface)

            Section {
                ForEach(AigoFontFamily.allCases) { family in
                    Button {
                        Haptics.selection()
                        appearance.family = family
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(family.displayName)
                                    .font(.custom(family.postScriptName(.regular), size: 15 * appearance.size.scale))
                                    .foregroundStyle(Theme.text)
                                Text("2 need you · 3 working")
                                    .font(.custom(family.postScriptName(.regular), size: 12 * appearance.size.scale))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if family == appearance.family {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.lime)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(family == appearance.family ? .isSelected : [])
                }
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
                                Text(size.rawValue)
                                    .font(.aigo(.callout, on ? .bold : .regular))
                                    .foregroundStyle(on ? Theme.bg : Theme.text)
                                    .frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
                                    .background(on ? Theme.text : Theme.softWhite,
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
            } header: {
                Text("Appearance")
            } footer: {
                Text("Used everywhere in the app, the Live Activity and the Dynamic Island. The terminal uses JetBrains Mono when Share Tech Mono is picked, for its box-drawing characters.")
            }
            .listRowBackground(Theme.surface)

            Section("Alerts") {
                Text("Aigo shows banners and a Live Activity while the app is open or was used recently. iOS pauses the connection after that.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
                Text("For alerts when the app is closed, turn on the ntfy notifications on your PC (Aigo → Settings → Notifications) and install the ntfy app on this iPhone, subscribed to the same topic.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.surface)

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
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(updates.checking)
                    if let err = updates.lastError {
                        Text(err)
                            .font(.aigo(.footnote))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Text("Aigo controls the coding agents and terminals running on your PC.")
                    .font(.aigo(.footnote))
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.surface)
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
            .preferredColorScheme(.dark)
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
