import SwiftUI

/// One row of "Everyone": status dot, title, who/where, what is happening now,
/// and a tiny activity pulse.
struct SessionRow: View {
    let session: SessionInfo
    var activity: [Date] = []

    var body: some View {
        let status = session.status
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: status)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle)
                        .font(.aigo(.body, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(status.label)
                        .font(Theme.monoCaption)
                        .foregroundStyle(status.color ?? Theme.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(session.subtitle)
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(alignment: .bottom, spacing: 10) {
                    Text(session.nowLine)
                        .font(.aigo(.footnote))
                        .foregroundStyle(status == .needsYou ? Theme.coralText : Theme.text.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.isRunning {
                        ActivityPulse(stamps: activity, status: status)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the session"))
    }
}
