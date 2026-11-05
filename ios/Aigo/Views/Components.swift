import SwiftUI

/// Lime = working, coral = needs you, ice = done, grey outline = idle.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            if let color = status.color {
                Circle()
                    .fill(color)
                    .shadow(color: status == .working ? color.opacity(0.55) : .clear, radius: 4)
            } else {
                Circle().strokeBorder(Theme.idle, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(status.label))
    }
}

/// Lowercase monospaced "aigo" with a glowing lime dot. Never truncates.
struct Wordmark: View {
    var size: CGFloat = 21

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("aigo")
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .tracking(-0.8)
                .foregroundStyle(Theme.text)
            Circle()
                .fill(Theme.lime)
                .frame(width: size * 0.34, height: size * 0.34)
                .shadow(color: Theme.lime.opacity(0.6), radius: 5)
                .padding(.bottom, size * 0.14)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aigo"))
        .accessibilityAddTraits(.isHeader)
    }
}

extension ConnectionState {
    var dotColor: Color {
        switch self {
        case .online: return Theme.lime
        case .connecting: return Theme.secondary
        case .offline: return Theme.coral
        case .unpaired: return Theme.idle
        }
    }

    var label: String {
        switch self {
        case .online: return "connected"
        case .connecting: return "connecting…"
        case .offline: return "offline"
        case .unpaired: return "not paired"
        }
    }
}

/// Host name pill: a menu to switch PCs, see the connection and pair another PC.
struct HostSwitcher: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Menu {
            Section("Paired PCs") {
                ForEach(store.hosts) { host in
                    Button {
                        Haptics.selection()
                        store.activate(host.id)
                    } label: {
                        if host.id == store.activeHostID {
                            Label(hostName(host), systemImage: "checkmark")
                        } else {
                            Label(hostName(host), systemImage: "desktopcomputer")
                        }
                        Text(host.id == store.activeHostID ? "\(host.addr) · \(store.connection.label)" : host.addr)
                    }
                }
            }
            Section {
                if store.connectionProblem != nil {
                    Button {
                        store.retry()
                    } label: {
                        Label("Retry connection", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    store.openPairSheet()
                } label: {
                    Label("Pair another PC", systemImage: "plus.viewfinder")
                }
                Button {
                    store.path.append(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.connection.dotColor)
                    .frame(width: 7, height: 7)
                Text(store.hostLabel)
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("\(store.hostLabel), \(store.connection.label). Switch PC"))
    }

    private func hostName(_ host: HostCredentials) -> String {
        host.hostName.isEmpty ? host.addr : host.hostName
    }
}

/// Monospaced section label, e.g. "NEEDS YOU 2".
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var tint: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.monoLabel)
                .tracking(1.0)
                .foregroundStyle(tint)
            if let count = count {
                Text("\(count)")
                    .font(Theme.monoLabel)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Inline message strip (server errors).
struct InlineBanner: View {
    let text: String
    var tint: Color = Theme.coral
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
                .padding(.top, 2)
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
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, onClose == nil ? 10 : 0)
        .padding(.trailing, onClose == nil ? 12 : 0)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// Connection failure with its plain cause and the action that fixes it.
struct ConnectionProblemCard: View {
    let problem: ConnectionProblem
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: problem.needsRepair ? "lock.trianglebadge.exclamationmark" : "wifi.exclamationmark")
                    .foregroundStyle(Theme.coral)
                Text(problem.needsRepair ? "Pairing needed" : "Not connected")
                    .font(Theme.monoLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.coral)
                Spacer(minLength: 0)
                if store.connection == .connecting {
                    ProgressView().controlSize(.small).tint(Theme.secondary)
                }
            }
            Text(problem.message)
                .font(.callout)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if problem.needsRepair {
                    Button("Pair again") {
                        store.repairActiveHost()
                    }
                    .buttonStyle(FilledButtonStyle(fill: Theme.coral, foreground: Theme.onCoral))
                }
                Button {
                    Haptics.tap()
                    store.retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(14)
        .aigoCard(border: Theme.coral.opacity(0.45), fill: Theme.coralWash)
    }
}

/// Tiny activity sparkline for one session: how many updates arrived in each
/// of the last 12 five-second buckets.
struct ActivityPulse: View {
    let stamps: [Date]
    let status: SessionStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let buckets = ActivityPulse.buckets(stamps, now: context.date)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<buckets.count, id: \.self) { i in
                    Capsule()
                        .fill(color.opacity(buckets[i] > 0 ? 1.0 : 0.28))
                        .frame(width: 2.5, height: 3 + CGFloat(min(buckets[i], 4)) * 3.2)
                }
            }
            .frame(height: 16, alignment: .bottom)
            .animation(.easeOut(duration: 0.3), value: buckets)
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .working, .stalled: return Theme.lime
        case .needsYou: return Theme.coral
        case .done: return Theme.ice
        default: return Theme.idle
        }
    }

    static func buckets(_ stamps: [Date], now: Date) -> [Int] {
        var out = [Int](repeating: 0, count: 12)
        for d in stamps {
            let age = now.timeIntervalSince(d)
            guard age >= 0, age < 60 else { continue }
            let i = 11 - Int(age / 5)
            if i >= 0 && i < 12 { out[i] += 1 }
        }
        return out
    }
}

/// Placeholder rows while the first snapshot loads.
struct SkeletonRows: View {
    var count = 3

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(Theme.surface2).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surface2).frame(width: 170, height: 13)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surface2.opacity(0.7)).frame(width: 120, height: 10)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surface2.opacity(0.5)).frame(maxWidth: .infinity).frame(height: 10)
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .modifier(Shimmer())
        .accessibilityLabel(Text("Loading"))
    }
}

/// Gentle opacity pulse for loading placeholders.
struct Shimmer: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
