import SwiftUI
import UIKit

/// Bundled monospace fonts for code, diffs, tool output and the terminal
/// (Shared/Fonts, registered through UIAppFonts in both the app and the widget
/// extension). The UI itself uses the system font (round 3 look).
enum AigoFontFamily: String, CaseIterable, Identifiable, Codable {
    case jetBrains = "JetBrainsMono"
    case victor = "VictorMono"
    case geist = "GeistMono"
    case ubuntu = "UbuntuSansMono"
    case plex = "IBMPlexMono"

    static let defaultFamily: AigoFontFamily = .jetBrains

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jetBrains: return "JetBrains Mono"
        case .victor: return "Victor Mono"
        case .geist: return "Geist Mono"
        case .ubuntu: return "Ubuntu Sans Mono"
        case .plex: return "IBM Plex Mono"
        }
    }

    /// Every bundled family has the box-drawing glyphs terminals need.
    var terminalFamily: AigoFontFamily { self }

    /// PostScript name of the face for `weight`. The weights are separate
    /// families in these files, so the face is picked by name rather than
    /// with `Font.weight(_:)`.
    func postScriptName(_ weight: Font.Weight = .regular) -> String {
        if weight == .bold || weight == .heavy || weight == .black { return rawValue + "-Bold" }
        if weight == .semibold { return rawValue + "-SemiBold" }
        if weight == .medium { return rawValue + "-Medium" }
        return rawValue + "-Regular"
    }
}

/// S / M / L text size.
enum AigoTextSize: String, CaseIterable, Identifiable, Codable {
    case small = "S"
    case medium = "M"
    case large = "L"

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.15
        }
    }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// The chosen code font and text size. The app keeps it in UserDefaults; the
/// widget extension receives it through the Live Activity content state.
struct AigoAppearance: Equatable {
    var family: AigoFontFamily
    var size: AigoTextSize

    static let familyKey = "appearance.fontFamily"
    static let sizeKey = "appearance.textSize"

    static func load() -> AigoAppearance {
        let d = UserDefaults.standard
        return AigoAppearance(
            family: AigoFontFamily(rawValue: d.string(forKey: familyKey) ?? "") ?? .defaultFamily,
            size: AigoTextSize(rawValue: d.string(forKey: sizeKey) ?? "") ?? .medium
        )
    }

    /// Read by `Font.aigo(...)`. Updated by the app's AppearanceStore.
    static var current = AigoAppearance.load()

    /// Compact base sizes (points at text size M) for each text style.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 30
        case .title: return 22
        case .title2: return 19
        case .title3: return 17
        case .headline: return 15
        case .body: return 15
        case .callout: return 14.5
        case .subheadline: return 14
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 15
        }
    }

    static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// Points for `base` at this text size, following Dynamic Type.
    func points(_ base: CGFloat, relativeTo style: Font.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: AigoAppearance.uiStyle(style)).scaledValue(for: base * size.scale)
    }

    /// The UI font (system) for a text style.
    func font(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let w: Font.Weight = (style == .headline && weight == .regular) ? .semibold : weight
        return .system(size: points(AigoAppearance.baseSize(style), relativeTo: style), weight: w)
    }

    func font(size base: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: points(base, relativeTo: style), weight: weight)
    }

    /// The code font (the chosen monospace family).
    func mono(size base: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(family.postScriptName(weight), size: base * size.scale, relativeTo: style)
    }
}

extension Font {
    /// The app font for a text style at the chosen size.
    static func aigo(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        AigoAppearance.current.font(style, weight)
    }

    /// The app font at a point size (scaled by the text size setting).
    static func aigo(size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AigoAppearance.current.font(size: size, weight)
    }

    /// Code, paths and tool output in the chosen monospace family.
    static func aigoMono(size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AigoAppearance.current.mono(size: size, weight)
    }
}
