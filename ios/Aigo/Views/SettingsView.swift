import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
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
                    LabeledContent("Address") {
                        Text(host.addr).font(Theme.monoSmall)
                    }
                    LabeledContent("Fingerprint") {
                        Text(String(host.fingerprint.prefix(16)) + "…").font(Theme.monoSmall)
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Section("Alerts") {
                Text("Aigo shows banners and a Live Activity while the app is open or was used recently. iOS pauses the connection after that.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                Text("For alerts when the app is closed, turn on the ntfy notifications on your PC (Aigo → Settings → Notifications) and install the ntfy app on this iPhone, subscribed to the same topic.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.surface)

            Section("About") {
                LabeledContent("Version", value: SettingsView.versionString)
                Text("Aigo controls the coding agents and terminals running on your PC.")
                    .font(.footnote)
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
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
