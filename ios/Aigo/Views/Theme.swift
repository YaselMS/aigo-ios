import SwiftUI

/// v0.3 style: graphite with lime / coral / ice signals, one monospace font
/// for all UI (Settings → Appearance), soft tinted buttons, sharp corners.
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
    static let coralButtonText = AigoPalette.coralButtonText
    static let iceText = AigoPalette.iceText
    /// Faint white tint of secondary buttons.
    static let softWhite = Color.white.opacity(0.05)
    static let codeBg = Color(aigoHex: 0x08090A)

    // Fonts are computed so a change in Settings → Appearance applies when
    // the view tree is rebuilt.
    static var mono: Font { .aigo(.callout) }
    static var monoSmall: Font { .aigo(.footnote) }
    static var monoCaption: Font { .aigo(.caption) }
    static var monoLabel: Font { .aigo(.caption, .semibold) }
    static var display: Font { .aigo(.title, .semibold) }
    static var cardTitle: Font { .aigo(.headline, .semibold) }

    static let gutter: CGFloat = 16
    /// Buttons.
    static let radius: CGFloat = 4
    /// Cards, inputs.
    static let cardRadius: CGFloat = 6
    /// Minimum button height on iPhone.
    static let buttonHeight: CGFloat = 40
}

/// Soft button: the colour at about 15% opacity behind coloured text. Used for
/// primary actions (lime), approvals (coral) and "Looks good" (ice).
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.lime
    var text: Color? = nil
    var fullWidth = true
    var minHeight: CGFloat = Theme.buttonHeight
    var alignment: Alignment = .center
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aigo(.callout, .bold))
            .lineLimit(3)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight, alignment: alignment)
            .background(tint.opacity(configuration.isPressed ? 0.26 : 0.15),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle((text ?? tint).opacity(isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Secondary button: faint white tint, no border.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    var fullWidth = true
    var minHeight: CGFloat = Theme.buttonHeight
    var alignment: Alignment = .center
    var weight: Font.Weight = .regular
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aigo(.callout, weight))
            .lineLimit(4)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight, alignment: alignment)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : 0.05),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Former names, kept so older call sites read naturally.
typealias FilledButtonStyle = SoftButtonStyle
typealias OutlineButtonStyle = SecondaryButtonStyle

extension SoftButtonStyle {
    init(fill: Color, foreground: Color) {
        self.init(tint: fill)
    }
}

extension SecondaryButtonStyle {
    init(tint: Color = Theme.text, border: Color) {
        self.init(tint: tint)
    }
}

/// Small inline button (Stop turn, Resume, Retry).
struct ChipButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aigo(.footnote, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.buttonHeight)
            .background((tint ?? .white).opacity(tint == nil ? (configuration.isPressed ? 0.11 : 0.05)
                                                             : (configuration.isPressed ? 0.26 : 0.15)),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(tint ?? Theme.text)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    /// Standard card frame (6 pt corners, 1 pt border).
    func aigoCard(border: Color = Theme.line, fill: Color = Theme.surface) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1))
    }
}
