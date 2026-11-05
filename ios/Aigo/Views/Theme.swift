import SwiftUI

/// Style A ("Lanes"): graphite, lime / coral / ice signals, system sans for
/// UI text and the monospaced system design for structure and code.
enum Theme {
    static let bg = AigoPalette.background
    static let surface = AigoPalette.surface
    static let surface2 = AigoPalette.surfaceRaised
    static let line = AigoPalette.line
    static let lineSoft = AigoPalette.lineSoft
    static let text = AigoPalette.text
    static let secondary = AigoPalette.secondary
    static let idle = AigoPalette.idle
    static let lime = AigoPalette.lime
    static let coral = AigoPalette.coral
    static let ice = AigoPalette.ice
    static let coralWash = AigoPalette.coralWash
    static let coralText = AigoPalette.coralText
    static let coralCode = AigoPalette.coralCode
    static let coralLine = AigoPalette.coralLine
    static let onAccent = AigoPalette.onAccent
    static let onCoral = AigoPalette.onCoral

    // Monospaced structure (scales with Dynamic Type).
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.footnote, design: .monospaced)
    static let monoCaption = Font.system(.caption, design: .monospaced)
    static let monoLabel = Font.system(.caption, design: .monospaced).weight(.semibold)

    // UI text.
    static let display = Font.system(.title, design: .default).weight(.semibold)
    static let cardTitle = Font.system(.headline, design: .default)

    static let gutter: CGFloat = 18
    static let radius: CGFloat = 14
    static let cardRadius: CGFloat = 16
}

/// Lime, full-width, 46pt+ primary button.
struct FilledButtonStyle: ButtonStyle {
    var fill: Color = Theme.lime
    var foreground: Color = Theme.onAccent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(fill.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1.0) : 0.35),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Outlined, full-width, 46pt+ secondary button.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    var border: Color = Theme.line
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .lineLimit(4)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(configuration.isPressed ? Theme.surface2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border, lineWidth: 1))
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small capsule button (Stop turn, Resume, Retry).
struct ChipButtonStyle: ButtonStyle {
    var fill: Color = Theme.surface2
    var foreground: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1.0), in: Capsule())
            .foregroundStyle(foreground)
            .contentShape(Capsule())
    }
}

extension View {
    /// Standard card frame.
    func aigoCard(border: Color = Theme.line, fill: Color = Theme.surface) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1))
    }
}
