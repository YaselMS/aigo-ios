import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.hosts.isEmpty {
                NavigationStack {
                    PairView(draft: nil, onDone: nil)
                        .navigationTitle("Pair your PC")
                }
            } else {
                NavigationStack(path: $store.path) {
                    HomeView()
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .session(let id):
                                SessionView(sessionID: id)
                            case .settings:
                                SettingsView()
                            }
                        }
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $store.showPairSheet) {
            NavigationStack {
                PairView(draft: store.pairDraft, onDone: {
                    store.showPairSheet = false
                })
                .navigationTitle("Pair a PC")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { store.showPairSheet = false }
                    }
                }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            store.scenePhaseChanged(phase)
        }
    }
}
