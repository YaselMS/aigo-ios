import SwiftUI

@main
struct AigoApp: App {
    @StateObject private var store = AppStore()

    init() {
        NotificationManager.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
                .onOpenURL { url in
                    store.handleURL(url)
                }
                .onAppear {
                    store.start()
                }
        }
    }
}
