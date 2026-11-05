import SwiftUI

enum Theme {
    static let bg = AigoPalette.background
    static let surface = AigoPalette.surface
    static let surface2 = AigoPalette.surfaceRaised
    static let line = AigoPalette.line
    static let text = AigoPalette.text
    static let secondary = AigoPalette.secondary
    static let lime = AigoPalette.lime
    static let coral = AigoPalette.coral
    static let ice = AigoPalette.ice

    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.footnote, design: .monospaced)
}

/// Filled, full-width, 44pt+ button.
struct FilledButtonStyle: ButtonStyle {
    var fill: Color = Theme.lime
    var foreground: Color = Theme.bg

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1.0),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Outlined, full-width, 44pt+ button.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.surface2.opacity(configuration.isPressed ? 1.0 : 0.6),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .foregroundStyle(tint)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
