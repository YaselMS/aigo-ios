import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the activity) and the widget
/// extension (which renders it on the Lock Screen and in the Dynamic Island).
struct AigoActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var working: Int
        var needsYou: Int
        /// Top pending item title, or the busiest session's title.
        var headline: String
        /// Pending item message, or what the session is working on.
        var detail: String
        var updatedAt: Date

        /// Equal ignoring the timestamp (used to skip redundant updates).
        func sameContent(as other: ContentState) -> Bool {
            working == other.working && needsYou == other.needsYou &&
                headline == other.headline && detail == other.detail
        }
    }

    var hostName: String
}
