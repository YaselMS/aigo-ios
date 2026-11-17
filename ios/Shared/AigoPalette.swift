import SwiftUI

extension Color {
    /// 0xRRGGBB sRGB color.
    init(aigoHex hex: UInt32, opacity: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: opacity)
    }
}

/// The three looks of round 3 (host `docs/design/r3`, R3Main mock):
/// Slate (dark, default), Porcelain (light) and Dusk (dark, warm).
enum AigoThemeID: String, CaseIterable, Identifiable, Codable {
    case slate
    case porcelain
    case dusk

    static let key = "appearance.theme"
    static let defaultTheme: AigoThemeID = .slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slate: return "Slate"
        case .porcelain: return "Porcelain"
        case .dusk: return "Dusk"
        }
    }

    var isDark: Bool { self != .porcelain }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static func load() -> AigoThemeID {
        AigoThemeID(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? defaultTheme
    }

    /// Read by `AigoPalette`. Updated by the app's AppearanceStore; the
    /// widget extension cannot read the app's defaults and stays on Slate.
    static var current: AigoThemeID = load()

    var tokens: AigoTokens {
        switch self {
        case .slate:
            return AigoTokens(bg: 0x16171B, panel: 0x1C1E23, raised: 0x24262D, line: 0x2C2F37, line2: 0x3A3D47,
                              hover: 0x24262D, sel: 0x2A2C35, text: 0xE7E8EC, text2: 0xC3C6CF, muted: 0x8C909B,
                              faint: 0x80848F, accent: 0xA594FF, accentBg: 0xA594FF, accentInk: 0x16171B,
                              accentText: 0xB5A8FF, ask: 0xF2A35E, work: 0x5FC8D5, review: 0x8BAAFF,
                              done: 0x93AA9C, add: 0x7FCB9C, danger: 0xEF8A80, term: 0x121317, dark: true)
        case .porcelain:
            return AigoTokens(bg: 0xF3F4F6, panel: 0xFFFFFF, raised: 0xECEEF2, line: 0xE2E4E9, line2: 0xD2D5DC,
                              hover: 0xF1F2F5, sel: 0xEBEDF1, text: 0x1A1C21, text2: 0x3D424C, muted: 0x69707D,
                              faint: 0x6E7480, accent: 0xE2603E, accentBg: 0xC44E2C, accentInk: 0xFFFFFF,
                              accentText: 0xB5462A, ask: 0xB05A06, work: 0x0A7A80, review: 0x4F55CF,
                              done: 0x5B7666, add: 0x1D7F4E, danger: 0xC23E2C, term: 0xF7F8FA, dark: false)
        case .dusk:
            return AigoTokens(bg: 0x1B1A21, panel: 0x221F2A, raised: 0x2C2935, line: 0x34303F, line2: 0x443F51,
                              hover: 0x2A2733, sel: 0x302C3B, text: 0xEDE9F2, text2: 0xCDC7D7, muted: 0x9A94A6,
                              faint: 0x8C869A, accent: 0xEDB46A, accentBg: 0xEDB46A, accentInk: 0x1B1A21,
                              accentText: 0xF0BE7E, ask: 0xF48D66, work: 0x6CCBC0, review: 0xA6ABFF,
                              done: 0xA0B2A3, add: 0x8FCE9F, danger: 0xF28C80, term: 0x17161C, dark: true)
        }
    }
}

/// Raw colour values of one theme (names follow the mock's CSS variables).
struct AigoTokens {
    let bg, panel, raised, line, line2, hover, sel: UInt32
    let text, text2, muted, faint: UInt32
    let accent, accentBg, accentInk, accentText: UInt32
    let ask, work, review, done, add, danger, term: UInt32
    let dark: Bool
}

/// Aigo colours of the current theme, shared by the app and the widget
/// extension. Every colour in the UI comes from here (through `Theme`).
enum AigoPalette {
    private static var t: AigoTokens { AigoThemeID.current.tokens }

    static var bg: Color { Color(aigoHex: t.bg) }
    static var panel: Color { Color(aigoHex: t.panel) }
    static var raised: Color { Color(aigoHex: t.raised) }
    static var line: Color { Color(aigoHex: t.line) }
    static var line2: Color { Color(aigoHex: t.line2) }
    static var hover: Color { Color(aigoHex: t.hover) }
    static var sel: Color { Color(aigoHex: t.sel) }
    /// Faint wash behind quiet buttons and chips.
    static var tint: Color { t.dark ? Color.white.opacity(0.045) : Color(aigoHex: 0x141821, opacity: 0.045) }
    static var text: Color { Color(aigoHex: t.text) }
    static var text2: Color { Color(aigoHex: t.text2) }
    static var muted: Color { Color(aigoHex: t.muted) }
    static var faint: Color { Color(aigoHex: t.faint) }
    static var accent: Color { Color(aigoHex: t.accent) }
    /// Fill of the one filled primary button per view.
    static var accentBg: Color { Color(aigoHex: t.accentBg) }
    /// Text on `accentBg`.
    static var accentInk: Color { Color(aigoHex: t.accentInk) }
    /// Accent as text on panels (contrast-tuned).
    static var accentText: Color { Color(aigoHex: t.accentText) }
    static var accentSoft: Color { Color(aigoHex: t.accent, opacity: t.dark ? 0.13 : 0.10) }
    static var accentLine: Color { Color(aigoHex: t.accent, opacity: 0.45) }
    /// Needs you.
    static var ask: Color { Color(aigoHex: t.ask) }
    static var askSoft: Color { Color(aigoHex: t.ask, opacity: t.dark ? 0.11 : 0.08) }
    static var askLine: Color { Color(aigoHex: t.ask, opacity: t.dark ? 0.34 : 0.32) }
    /// Working.
    static var work: Color { Color(aigoHex: t.work) }
    /// To review.
    static var review: Color { Color(aigoHex: t.review) }
    /// Done.
    static var done: Color { Color(aigoHex: t.done) }
    /// Added lines, success.
    static var add: Color { Color(aigoHex: t.add) }
    /// Removed lines, kill, errors.
    static var danger: Color { Color(aigoHex: t.danger) }
    /// Code blocks and tool output.
    static var term: Color { Color(aigoHex: t.term) }
    /// Background of the app icon mark.
    static var iconSquare: Color { Color(aigoHex: t.dark ? t.raised : 0x1C1E23) }
    static var isDark: Bool { t.dark }
}
