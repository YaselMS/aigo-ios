import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the activity) and the widget
/// extension (which renders it on the Lock Screen and in the Dynamic Island).
struct AigoActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var working: Int
        var needsYou: Int
        /// First needs-you item's title (its session), or the busiest session's title.
        var headline: String
        /// The command or question of the first needs-you item, or what the
        /// session is working on.
        var detail: String
        /// Set when the first needs-you item is a plain approve/deny that is safe
        /// to answer from the Lock Screen (not destructive, not a question).
        var actionId: String
        var updatedAt: Date
        /// "Codex · project" of the headline item.
        var context: String = ""
        /// The app's font (AigoFontFamily raw value) and text size, so the
        /// widget matches Settings → Appearance.
        var fontFamily: String = AigoFontFamily.defaultFamily.rawValue
        var textSize: String = AigoTextSize.medium.rawValue

        var appearance: AigoAppearance {
            AigoAppearance(family: AigoFontFamily(rawValue: fontFamily) ?? .defaultFamily,
                           size: AigoTextSize(rawValue: textSize) ?? .medium)
        }

        /// Equal ignoring the timestamp (used to skip redundant updates).
        func sameContent(as other: ContentState) -> Bool {
            working == other.working && needsYou == other.needsYou &&
                headline == other.headline && detail == other.detail && actionId == other.actionId &&
                context == other.context && fontFamily == other.fontFamily && textSize == other.textSize
        }
    }

    var hostName: String
}

extension AigoActivityAttributes.ContentState {
    private enum Keys: String, CodingKey {
        case working, needsYou, headline, detail, actionId, updatedAt, context, fontFamily, textSize
    }

    /// Tolerates states written by v0.2 (no context / font fields).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        working = try c.decodeIfPresent(Int.self, forKey: .working) ?? 0
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        actionId = try c.decodeIfPresent(String.self, forKey: .actionId) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? AigoFontFamily.defaultFamily.rawValue
        textSize = try c.decodeIfPresent(String.self, forKey: .textSize) ?? AigoTextSize.medium.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(working, forKey: .working)
        try c.encode(needsYou, forKey: .needsYou)
        try c.encode(headline, forKey: .headline)
        try c.encode(detail, forKey: .detail)
        try c.encode(actionId, forKey: .actionId)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(context, forKey: .context)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(textSize, forKey: .textSize)
    }
}
