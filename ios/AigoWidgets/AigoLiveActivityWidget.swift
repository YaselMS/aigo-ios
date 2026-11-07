import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen card + Dynamic Island for the Aigo Live Activity (v0.3).
/// Compact: the icon and two counts (coral = needs you, lime = working).
/// Expanded / Lock Screen: the first needs-you item with Approve / Deny.
/// Tapping elsewhere opens the board (aigo://home).
struct AigoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AigoActivityAttributes.self) { context in
            AigoLockScreenView(state: context.state,
                               hostName: context.attributes.hostName,
                               isStale: context.isStale)
                .activityBackgroundTint(AigoPalette.background.opacity(0.94))
                .activitySystemActionForegroundColor(AigoPalette.text)
                .widgetURL(URL(string: "aigo://home"))
        } dynamicIsland: { context in
            let state = context.state
            let look = state.appearance
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AigoWordmark(size: 14, appearance: look)
                        .padding(.leading, 6)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AigoCounts(state: state, appearance: look, fontSize: 13)
                        .padding(.trailing, 6)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AigoActivityCard(state: state, hostName: context.attributes.hostName, appearance: look,
                                     buttonHeight: 40)
                        .padding(.top, 4)
                }
            } compactLeading: {
                AigoIconMark(size: 20, appearance: look)
            } compactTrailing: {
                AigoCounts(state: state, appearance: look, fontSize: 12)
            } minimal: {
                AigoMinimalCount(state: state, appearance: look)
            }
            .widgetURL(URL(string: "aigo://home"))
            .keylineTint(state.needsYou > 0 ? AigoPalette.coral : AigoPalette.lime)
        }
    }
}

/// "● 2  ● 3": coral needs-you count, lime working count (zeros hidden,
/// except a lone 0 working when nothing else is shown).
struct AigoCounts: View {
    let state: AigoActivityAttributes.ContentState
    let appearance: AigoAppearance
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            if state.needsYou > 0 {
                count(state.needsYou, dot: AigoPalette.coral, text: AigoPalette.coralText)
            }
            if state.working > 0 || state.needsYou == 0 {
                count(state.working, dot: AigoPalette.lime, text: AigoPalette.lime)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AigoActivityText.summary(state)))
    }

    private func count(_ n: Int, dot: Color, text: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text("\(n)")
                .font(.custom(appearance.family.postScriptName(.semibold), fixedSize: fontSize))
                .foregroundStyle(text)
                .monospacedDigit()
        }
    }
}

struct AigoMinimalCount: View {
    let state: AigoActivityAttributes.ContentState
    let appearance: AigoAppearance

    var body: some View {
        let needs = state.needsYou > 0
        HStack(spacing: 3) {
            Circle().fill(needs ? AigoPalette.coral : AigoPalette.lime).frame(width: 6, height: 6)
            Text("\(needs ? state.needsYou : state.working)")
                .font(.custom(appearance.family.postScriptName(.semibold), fixedSize: 12))
                .foregroundStyle(needs ? AigoPalette.coralText : AigoPalette.lime)
        }
    }
}

enum AigoActivityText {
    static func summary(_ s: AigoActivityAttributes.ContentState) -> String {
        var parts: [String] = []
        if s.needsYou > 0 { parts.append("\(s.needsYou) need you") }
        if s.working > 0 { parts.append("\(s.working) working") }
        return parts.isEmpty ? "all clear" : parts.joined(separator: " · ")
    }
}

struct AigoLockScreenView: View {
    let state: AigoActivityAttributes.ContentState
    let hostName: String
    let isStale: Bool

    var body: some View {
        let look = state.appearance
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AigoWordmark(size: 13, appearance: look)
                Text(hostName.isEmpty ? AigoActivityText.summary(state)
                                      : "\(hostName) · \(AigoActivityText.summary(state))")
                    .font(look.font(size: 12))
                    .foregroundStyle(AigoPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isStale {
                    Text(state.updatedAt, style: .time)
                        .font(look.font(size: 11))
                        .foregroundStyle(AigoPalette.secondary.opacity(0.8))
                }
            }
            AigoActivityCard(state: state, hostName: hostName, appearance: look, buttonHeight: 40)
        }
        .padding(10)
    }
}

/// The first needs-you item (coral card with Approve / Deny), or the busiest
/// working session.
struct AigoActivityCard: View {
    let state: AigoActivityAttributes.ContentState
    let hostName: String
    let appearance: AigoAppearance
    var buttonHeight: CGFloat = 40

    var body: some View {
        let needs = state.needsYou > 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !needs {
                    Circle().fill(AigoPalette.lime).frame(width: 7, height: 7)
                }
                Text(state.headline.isEmpty ? (needs ? "An agent needs you" : "Working") : state.headline)
                    .font(appearance.font(size: 13, .semibold))
                    .foregroundStyle(AigoPalette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if needs && state.needsYou > 1 {
                    Text("1 of \(state.needsYou)")
                        .font(appearance.font(size: 11))
                        .foregroundStyle(AigoPalette.secondary)
                }
            }
            if !state.context.isEmpty {
                Text(state.context)
                    .font(appearance.font(size: 11))
                    .foregroundStyle(AigoPalette.secondary)
                    .lineLimit(1)
            }
            if !state.detail.isEmpty {
                Text(state.detail)
                    .font(appearance.font(size: 11))
                    .foregroundStyle(needs ? AigoPalette.coralText : AigoPalette.secondary)
                    .lineLimit(2)
            }
            if !state.actionId.isEmpty {
                AigoDecisionButtons(actionId: state.actionId, appearance: appearance, height: buttonHeight)
            } else if needs {
                Text("Open Aigo to answer")
                    .font(appearance.font(size: 11))
                    .foregroundStyle(AigoPalette.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(needs ? AigoPalette.coralWash : AigoPalette.surface,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(needs ? AigoPalette.coral : AigoPalette.line, lineWidth: 1))
    }
}

/// Approve / Deny from the Lock Screen or the expanded Dynamic Island.
/// Shown only for plain, non-destructive approvals (the app decides).
struct AigoDecisionButtons: View {
    let actionId: String
    let appearance: AigoAppearance
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DecideApprovalIntent(actionId: actionId, approve: true)) {
                Text("Approve")
                    .font(appearance.font(size: 13, .bold))
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(AigoPalette.coral.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(AigoPalette.coralButtonText)
            }
            .buttonStyle(.plain)
            Button(intent: DecideApprovalIntent(actionId: actionId, approve: false)) {
                Text("Deny")
                    .font(appearance.font(size: 13))
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(AigoPalette.text)
            }
            .buttonStyle(.plain)
        }
    }
}
