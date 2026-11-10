import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.hosts.isEmpty {
                NavigationStack {
                    PairView(draft: store.pairDraft, onDone: nil)
                        .navigationTitle("Pair your PC")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(Theme.bg, for: .navigationBar)
                }
            } else {
                NavigationStack(path: $store.path) {
                    HomeView()
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .session(let id):
                                SessionView(sessionID: id)
                            case .external(let key):
                                ExternalConversationView(key: key)
                            case .settings:
                                SettingsView()
                            }
                        }
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { store.showPairSheet && !store.hosts.isEmpty },
                                    set: { store.showPairSheet = $0 })) {
            NavigationStack {
                PairView(draft: store.pairDraft, onDone: {
                    store.showPairSheet = false
                })
                .navigationTitle("Pair a PC")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { store.showPairSheet = false }
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(appearance)
            .environment(\.font, .aigo(.body))
            .preferredColorScheme(.dark)
            .tint(Theme.lime)
        }
        .sheet(isPresented: $store.showNewWork) {
            NewWorkView(preferredAgent: store.newWorkAgent)
                .environmentObject(store)
                .environmentObject(appearance)
                .environment(\.font, .aigo(.body))
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $store.showSearch) {
            SearchView()
                .environmentObject(store)
                .environmentObject(appearance)
                .environment(\.font, .aigo(.body))
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: Binding(get: { store.showDesktop && !store.hosts.isEmpty },
                                              set: { store.showDesktop = $0 })) {
            DesktopView()
                .environmentObject(store)
                .environmentObject(appearance)
                .environment(\.font, .aigo(.body))
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
        }
        .onChange(of: scenePhase) { _, phase in
            store.scenePhaseChanged(phase)
            if phase == .active {
                Task { await updates.checkIfDue() }
            }
        }
    }
}
