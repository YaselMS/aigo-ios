import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
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
            .preferredColorScheme(.dark)
            .tint(Theme.lime)
        }
        .sheet(isPresented: $store.showNewWork) {
            NewWorkView(preferredAgent: store.newWorkAgent)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            store.scenePhaseChanged(phase)
        }
    }
}
