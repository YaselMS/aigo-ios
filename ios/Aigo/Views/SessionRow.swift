import SwiftUI

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        let status = session.status
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: status)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.color ?? Theme.secondary)
                }
                Text(session.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(session.nowLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineLimit(2)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondary.opacity(0.6))
                .padding(.top, 6)
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
