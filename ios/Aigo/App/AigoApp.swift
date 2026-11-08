import SwiftUI

@main
struct AigoApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var appearance = AppearanceStore()
    @StateObject private var updates = UpdateChecker()

    init() {
        NotificationManager.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(appearance.revision)
                .environment(\.font, .aigo(.body))
                .environmentObject(store)
                .environmentObject(appearance)
                .environmentObject(updates)
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
                .onOpenURL { url in
                    store.handleURL(url)
                }
                .onAppear {
                    store.start()
                }
                .task {
                    await updates.checkIfDue()
                }
                .onChange(of: appearance.revision) { _, _ in
                    // The Live Activity uses the same font.
                    store.refreshLiveActivity()
                }
        }
    }
}
