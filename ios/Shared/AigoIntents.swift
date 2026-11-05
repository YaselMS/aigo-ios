import AppIntents
import Foundation

/// Approve / Deny buttons in the expanded Live Activity. A LiveActivityIntent
/// runs in the app's process, so the network call is made by the app target
/// (compiled with AIGO_APP); the widget extension only references the type.
struct DecideApprovalIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer an agent"
    static var description = IntentDescription("Approves or denies what an agent asked for on your PC.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action ID")
    var actionId: String

    @Parameter(title: "Approve")
    var approve: Bool

    init() {}

    init(actionId: String, approve: Bool) {
        self.actionId = actionId
        self.approve = approve
    }

    func perform() async throws -> some IntentResult {
        #if AIGO_APP
        await IntentActions.decide(actionId: actionId, approve: approve)
        #endif
        return .result()
    }
}
