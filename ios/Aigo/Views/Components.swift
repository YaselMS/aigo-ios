import SwiftUI

/// Status dot: work = working, ask = needs you, review = finished, faint
/// outline = idle.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            if let color = status.color {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Theme.faint, lineWidth: 1.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(status.label))
    }
}

/// Glyph of a sub-agent or task (session `children`): pending ring, working
/// dot, done check, failed cross.
struct ChildGlyph: View {
    let status: String?

    var body: some View {
        Group {
            switch status ?? "" {
            case "working":
                Circle().fill(Theme.work).frame(width: 6, height: 6)
            case "done":
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.done)
            case "failed":
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.danger)
            default:
                Circle().strokeBorder(Theme.faint, lineWidth: 1).frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(Text(status ?? "pending"))
    }
}

/// Lowercase "aigo" with an accent dot.
struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        AigoWordmark(size: size)
            .accessibilityAddTraits(.isHeader)
    }
}

extension ConnectionState {
    var dotColor: Color {
        switch self {
        case .online: return Theme.add
        case .connecting: return Theme.muted
        case .offline: return Theme.danger
        case .unpaired: return Theme.faint
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

/// Compact PC switcher ("● kdrewpc ▾", no box): the paired PCs with their
/// status, Add a PC, the PC's screen and Settings.
struct HostSwitcher: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Menu {
            Section("PCs") {
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
                        Text(host.id == store.activeHostID ? store.connection.label.capitalizedFirst : "Paired · tap to switch")
                    }
                }
                Button {
                    store.openPairSheet()
                } label: {
                    Label("Add a PC", systemImage: "plus")
                }
            }
            Section {
                Button {
                    Haptics.tap()
                    store.showDesktop = true
                } label: {
                    Label("View screen", systemImage: "display")
                }
                .disabled(store.client == nil)
                if store.connectionProblem != nil {
                    Button {
                        store.retry()
                    } label: {
                        Label("Retry connection", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    store.path.append(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.connection.dotColor)
                    .frame(width: 6, height: 6)
                Text(store.hostLabel)
                    .font(.aigo(.footnote, .medium))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("\(store.hostLabel), \(store.connection.label). Switch PC"))
    }

    private func hostName(_ host: HostCredentials) -> String {
        host.hostName.isEmpty ? host.addr : host.hostName
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Quiet group label, e.g. "Needs you 2" (sentence case, muted).
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var tint: Color = Theme.muted

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(tint)
            if let count = count, count > 0 {
                Text("\(count)")
                    .font(Theme.label)
                    .foregroundStyle(Theme.faint)
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
    var tint: Color = Theme.danger
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.aigo(.footnote))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.aigo(.footnote, .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, onClose == nil ? 10 : 0)
        .padding(.trailing, onClose == nil ? 12 : 0)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
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
                    .foregroundStyle(Theme.danger)
                Text(problem.needsRepair ? "Pairing needed" : "Not connected")
                    .font(Theme.label)
                    .foregroundStyle(Theme.danger)
                Spacer(minLength: 0)
                if store.connection == .connecting {
                    ProgressView().controlSize(.small).tint(Theme.muted)
                }
            }
            Text(problem.message)
                .font(.aigo(.callout))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if problem.needsRepair {
                    Button("Pair again") {
                        store.repairActiveHost()
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.danger, text: Theme.danger))
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
        .aigoCard(border: Theme.danger.opacity(0.35), fill: Theme.danger.opacity(0.08))
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
        case .working, .stalled: return Theme.work
        case .needsYou: return Theme.ask
        case .done: return Theme.review
        default: return Theme.faint
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
                    Circle().fill(Theme.raised).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(width: 170, height: 13)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.raised.opacity(0.7)).frame(width: 120, height: 10)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.raised.opacity(0.5)).frame(maxWidth: .infinity).frame(height: 10)
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
