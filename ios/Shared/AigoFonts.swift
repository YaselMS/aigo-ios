import SwiftUI

/// Bundled monospace fonts (Shared/Fonts, registered through UIAppFonts in
/// both the app and the widget extension). Share Tech Mono is the default.
enum AigoFontFamily: String, CaseIterable, Identifiable, Codable {
    case shareTech = "ShareTechMono"
    case jetBrains = "JetBrainsMono"
    case victor = "VictorMono"
    case geist = "GeistMono"
    case ubuntu = "UbuntuSansMono"
    case plex = "IBMPlexMono"

    static let defaultFamily: AigoFontFamily = .shareTech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shareTech: return "Share Tech Mono"
        case .jetBrains: return "JetBrains Mono"
        case .victor: return "Victor Mono"
        case .geist: return "Geist Mono"
        case .ubuntu: return "Ubuntu Sans Mono"
        case .plex: return "IBM Plex Mono"
        }
    }

    /// Share Tech Mono ships a single weight; the others have Regular,
    /// Medium, SemiBold and Bold files.
    var hasWeights: Bool { self != .shareTech }

    /// Box-drawing and other terminal glyphs. Share Tech Mono lacks them, so
    /// the terminal uses JetBrains Mono instead.
    var terminalFamily: AigoFontFamily { self == .shareTech ? .jetBrains : self }

    /// PostScript name of the face for `weight`. The weights are separate
    /// families in these files, so the face is picked by name rather than
    /// with `Font.weight(_:)`.
    func postScriptName(_ weight: Font.Weight = .regular) -> String {
        guard hasWeights else { return "ShareTechMono-Regular" }
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

/// The chosen font and size. The app keeps it in UserDefaults; the widget
/// extension receives it through the Live Activity content state.
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

    /// Compact base sizes (points at text size M) for each text style; the
    /// fonts still follow Dynamic Type through `relativeTo:`.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 30
        case .title: return 22
        case .title2: return 19
        case .title3: return 17
        case .headline: return 15
        case .body: return 14.5
        case .callout: return 14
        case .subheadline: return 13.5
        case .footnote: return 12.5
        case .caption: return 11.5
        case .caption2: return 10.5
        @unknown default: return 14.5
        }
    }

    func font(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let w: Font.Weight = (style == .headline && weight == .regular) ? .semibold : weight
        return .custom(family.postScriptName(w), size: AigoAppearance.baseSize(style) * size.scale, relativeTo: style)
    }

    func font(size points: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(family.postScriptName(weight), size: points * size.scale, relativeTo: style)
    }
}

extension Font {
    /// The app font for a text style, in the chosen family and size.
    static func aigo(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        AigoAppearance.current.font(style, weight)
    }

    /// The app font at a point size (scaled by the text size setting).
    static func aigo(size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AigoAppearance.current.font(size: size, weight)
    }
}
