import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner + Dynamic Island for the Aigo Live Activity.
/// Tapping anywhere opens the app at Home (aigo://home).
struct AigoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AigoActivityAttributes.self) { context in
            AigoLockScreenView(state: context.state,
                               hostName: context.attributes.hostName,
                               isStale: context.isStale)
                .activityBackgroundTint(AigoPalette.background)
                .activitySystemActionForegroundColor(AigoPalette.text)
                .widgetURL(URL(string: "aigo://home"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AigoSignalDot(needsYou: context.state.needsYou > 0, size: 10)
                        Text("aigo")
                            .font(.system(.headline, design: .monospaced).weight(.bold))
                            .foregroundStyle(AigoPalette.text)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(AigoActivityText.summary(context.state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.needsYou > 0 ? AigoPalette.coral : AigoPalette.lime)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AigoPalette.text)
                            .lineLimit(1)
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.caption)
                                .foregroundStyle(AigoPalette.secondary)
                                .lineLimit(2)
                        }
                        Text(context.attributes.hostName)
                            .font(.caption2)
                            .foregroundStyle(AigoPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                AigoSignalDot(needsYou: context.state.needsYou > 0, size: 10)
            } compactTrailing: {
                Text(AigoActivityText.compact(context.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(context.state.needsYou > 0 ? AigoPalette.coral : AigoPalette.lime)
            } minimal: {
                AigoSignalDot(needsYou: context.state.needsYou > 0, size: 10)
            }
            .widgetURL(URL(string: "aigo://home"))
            .keylineTint(context.state.needsYou > 0 ? AigoPalette.coral : AigoPalette.lime)
        }
    }
}

struct AigoSignalDot: View {
    let needsYou: Bool
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(needsYou ? AigoPalette.coral : AigoPalette.lime)
            .frame(width: size, height: size)
    }
}

enum AigoActivityText {
    static func compact(_ s: AigoActivityAttributes.ContentState) -> String {
        if s.needsYou > 0 { return "needs you" }
        return "\(s.working) working"
    }

    static func summary(_ s: AigoActivityAttributes.ContentState) -> String {
        var parts: [String] = []
        if s.needsYou > 0 { parts.append("\(s.needsYou) need you") }
        if s.working > 0 { parts.append("\(s.working) working") }
        return parts.isEmpty ? "all quiet" : parts.joined(separator: " · ")
    }
}

struct AigoLockScreenView: View {
    let state: AigoActivityAttributes.ContentState
    let hostName: String
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AigoSignalDot(needsYou: state.needsYou > 0, size: 12)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("aigo")
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(AigoPalette.text)
                    Text(hostName)
                        .font(.caption)
                        .foregroundStyle(AigoPalette.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(AigoActivityText.summary(state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.needsYou > 0 ? AigoPalette.coral : AigoPalette.lime)
                }
                if !state.headline.isEmpty {
                    Text(state.headline)
                        .font(.headline)
                        .foregroundStyle(AigoPalette.text)
                        .lineLimit(1)
                }
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.footnote)
                        .foregroundStyle(AigoPalette.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(isStale ? "Last update" : "Updated")
                    Text(state.updatedAt, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(AigoPalette.secondary.opacity(0.8))
            }
        }
        .padding(14)
    }
}
