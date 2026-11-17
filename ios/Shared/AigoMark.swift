import SwiftUI

/// The app icon drawn in SwiftUI: a rounded square, a lowercase "a" and an
/// accent dot.
struct AigoIconMark: View {
    var size: CGFloat = 20
    var appearance: AigoAppearance = .current

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 5 / 18, style: .continuous)
                .fill(AigoPalette.iconSquare)
            Text("a")
                .font(.system(size: size * 11 / 18, weight: .semibold))
                .foregroundStyle(Color(aigoHex: 0xE7E8EC))
                .frame(width: size * 9 / 18, height: size, alignment: .center)
                .offset(x: size * 3.6 / 18, y: -size * 0.5 / 18)
            Circle()
                .fill(AigoPalette.accent)
                .frame(width: size * 4 / 18, height: size * 4 / 18)
                .offset(x: size * 11.2 / 18, y: size * 9.6 / 18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Lowercase "aigo" with an accent dot.
struct AigoWordmark: View {
    var size: CGFloat = 17
    var appearance: AigoAppearance = .current

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("aigo")
                .font(.system(size: size * appearance.size.scale, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(AigoPalette.text)
            Circle()
                .fill(AigoPalette.accent)
                .frame(width: size * 0.32, height: size * 0.32)
                .padding(.bottom, size * 0.12)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aigo"))
    }
}
