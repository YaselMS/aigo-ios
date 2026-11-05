import ActivityKit
import Foundation

/// Keeps one Live Activity (Lock Screen + Dynamic Island) in sync with the
/// connected host while the app runs. Updates are local (pushType: nil).
@MainActor
final class LiveActivityController {
    private var current: Activity<AigoActivityAttributes>?
    private var last: AigoActivityAttributes.ContentState?

    func update(hostName: String, working: Int, needsYou: Int, headline: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if working == 0 && needsYou == 0 {
            end()
            return
        }
        let state = AigoActivityAttributes.ContentState(
            working: working,
            needsYou: needsYou,
            headline: String(headline.prefix(120)),
            detail: String(detail.prefix(200)),
            updatedAt: Date()
        )
        if current == nil {
            current = Activity<AigoActivityAttributes>.activities.first
        }
        if let activity = current {
            if activity.activityState == .ended || activity.activityState == .dismissed {
                current = nil
                last = nil
            } else if activity.attributes.hostName != hostName {
                end()
            }
        }
        if let previous = last, current != nil, previous.sameContent(as: state) {
            return
        }
        last = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        if let activity = current {
            Task {
                await activity.update(content)
            }
        } else {
            do {
                current = try Activity<AigoActivityAttributes>.request(
                    attributes: AigoActivityAttributes(hostName: hostName),
                    content: content,
                    pushType: nil
                )
            } catch {
                // Not allowed right now (e.g. app in background); try again on the next event.
                last = nil
            }
        }
    }

    func end() {
        last = nil
        current = nil
        for activity in Activity<AigoActivityAttributes>.activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
