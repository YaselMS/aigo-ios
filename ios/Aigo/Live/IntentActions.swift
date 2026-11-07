import ActivityKit
import Foundation

/// App-side work of DecideApprovalIntent (Approve / Deny in the Live Activity).
/// Runs in the app process, possibly while the app is in the background, so
/// it uses its own short-lived client instead of the UI store.
enum IntentActions {
    static let decidedNotification = Notification.Name("dev.aigo.intentDecided")

    static func decide(actionId: String, approve: Bool) async {
        guard !actionId.isEmpty else { return }
        let hosts = HostVault.load()
        let saved = UserDefaults.standard.string(forKey: "activeHostID")
        guard let host = hosts.first(where: { $0.id == saved }) ?? hosts.first else { return }
        let client = APIClient(credentials: host)
        var failure: String?
        do {
            try await client.decide(actionId: actionId, approve: approve, choice: nil)
        } catch {
            failure = client.problem(for: error).message
        }
        client.invalidate()
        for activity in Activity<AigoActivityAttributes>.activities {
            var state = activity.content.state
            guard state.actionId == actionId else { continue }
            state.actionId = ""
            if let failure = failure {
                state.headline = "Couldn't answer from here"
                state.detail = failure
                state.context = ""
            } else {
                state.needsYou = max(0, state.needsYou - 1)
                state.headline = approve ? "Approved" : "Denied"
                state.detail = state.needsYou > 0 ? "Open Aigo for the next one." : "Nothing else needs you."
                state.context = ""
            }
            state.updatedAt = Date()
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)))
        }
        await MainActor.run {
            NotificationCenter.default.post(name: decidedNotification, object: nil)
        }
    }
}
