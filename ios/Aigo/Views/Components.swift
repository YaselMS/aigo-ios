import SwiftUI

/// Lime = working, coral = needs you, ice = done, grey outline = idle.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            if let color = status.color {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Theme.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(status.label))
    }
}

/// Lowercase monospaced "aigo" with a small lime dot.
struct Wordmark: View {
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("aigo")
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(Theme.text)
            Circle()
                .fill(Theme.lime)
                .frame(width: 6, height: 6)
                .padding(.bottom, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aigo"))
    }
}

/// Host name + connection indicator for the toolbar.
struct HostBadge: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(store.hostLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(store.hostLabel), \(stateText)"))
    }

    private var color: Color {
        switch store.connection {
        case .online: return Theme.lime
        case .connecting: return Theme.secondary
        case .offline: return Theme.coral
        case .unpaired: return Theme.secondary
        }
    }

    private var stateText: String {
        switch store.connection {
        case .online: return "connected"
        case .connecting: return "connecting"
        case .offline: return "offline"
        case .unpaired: return "not paired"
        }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .tracking(0.8)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            if let count = count {
                Text("\(count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
    }
}

/// Inline message strip (server errors, connection problems).
struct InlineBanner: View {
    let text: String
    var tint: Color = Theme.coral
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}
