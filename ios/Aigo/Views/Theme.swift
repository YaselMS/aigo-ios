import SwiftUI

/// Round 3 look (host `docs/design/r3`): three themes (Slate, Porcelain,
/// Dusk; Settings → Appearance), system font, calm tinted controls, thin
/// icons. Every colour goes through these tokens; they are computed so a
/// theme change applies when the view tree is rebuilt.
enum Theme {
    static var bg: Color { AigoPalette.bg }
    /// Cards, rows, inputs.
    static var panel: Color { AigoPalette.panel }
    /// Raised chips, skeletons.
    static var raised: Color { AigoPalette.raised }
    static var line: Color { AigoPalette.line }
    static var line2: Color { AigoPalette.line2 }
    static var hover: Color { AigoPalette.hover }
    static var sel: Color { AigoPalette.sel }
    /// Faint wash behind quiet buttons.
    static var tint: Color { AigoPalette.tint }
    static var text: Color { AigoPalette.text }
    static var text2: Color { AigoPalette.text2 }
    static var muted: Color { AigoPalette.muted }
    static var faint: Color { AigoPalette.faint }
    static var accent: Color { AigoPalette.accent }
    static var accentBg: Color { AigoPalette.accentBg }
    static var accentInk: Color { AigoPalette.accentInk }
    static var accentText: Color { AigoPalette.accentText }
    static var accentSoft: Color { AigoPalette.accentSoft }
    static var accentLine: Color { AigoPalette.accentLine }
    static var ask: Color { AigoPalette.ask }
    static var askSoft: Color { AigoPalette.askSoft }
    static var askLine: Color { AigoPalette.askLine }
    static var work: Color { AigoPalette.work }
    static var review: Color { AigoPalette.review }
    static var done: Color { AigoPalette.done }
    static var add: Color { AigoPalette.add }
    static var danger: Color { AigoPalette.danger }
    /// Code blocks, tool output, diffs.
    static var term: Color { AigoPalette.term }

    // Fonts are computed so a change in Settings → Appearance applies when
    // the view tree is rebuilt.
    static var body: Font { .aigo(.callout) }
    static var small: Font { .aigo(.footnote) }
    static var caption: Font { .aigo(.caption) }
    static var label: Font { .aigo(.caption, .medium) }
    static var display: Font { .aigo(.title, .semibold) }
    static var cardTitle: Font { .aigo(.headline, .semibold) }

    static let gutter: CGFloat = 16
    /// Controls.
    static let radius: CGFloat = 6
    /// Cards, panels, inputs.
    static let cardRadius: CGFloat = 8
    /// Minimum button height on iPhone.
    static let buttonHeight: CGFloat = 40
    /// SF Symbols weight of the thin icon set (Lucide-like).
    static let iconWeight: Font.Weight = .light
}

/// Tinted button: the colour at a low opacity behind coloured text. Used for
/// answers (ask), "Looks good" (review) and quiet accents.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var text: Color? = nil
    var fullWidth = true
    var minHeight: CGFloat = Theme.buttonHeight
    var alignment: Alignment = .center
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aigo(.callout, .medium))
            .lineLimit(3)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight, alignment: alignment)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle((text ?? tint).opacity(isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The one filled primary action of a view (New chat, Pair).
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    var minHeight: CGFloat = Theme.buttonHeight
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aigo(.callout, .medium))
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
            .background(Theme.accentBg.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(Theme.accentInk)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Secondary button: faint tint, no border.
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
            .background(configuration.isPressed ? Theme.hover : Theme.tint,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Former names, kept so older call sites read naturally.
typealias FilledButtonStyle = PrimaryButtonStyle
typealias OutlineButtonStyle = SecondaryButtonStyle

/// Small inline button (Stop turn, Resume, Retry).
struct ChipButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aigo(.footnote, .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(background(configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(tint ?? Theme.text2)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func background(_ pressed: Bool) -> Color {
        if let tint { return tint.opacity(pressed ? 0.22 : 0.12) }
        return pressed ? Theme.hover : Theme.tint
    }
}

/// Icon button without a box: muted thin glyph, a soft wash only while pressed.
struct QuietIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.muted
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: Theme.iconWeight))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPressStyle())
        .accessibilityLabel(Text(label))
    }
}

/// Pressed state of borderless controls: a faint rounded wash.
struct QuietPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// The glyph of a quiet icon in menus and labels (thin weight).
struct ThinIcon: View {
    let symbol: String
    var size: CGFloat = 15
    var tint: Color = Theme.muted

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: Theme.iconWeight))
            .foregroundStyle(tint)
    }
}

extension View {
    /// Standard card frame (8 pt corners, 1 pt border).
    func aigoCard(border: Color = Theme.line, fill: Color = Theme.panel) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1))
    }
}
