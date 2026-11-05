import SwiftUI

/// One entry of the "Since you left" digest, kept in memory from the
/// /events stream and the initial snapshot.
struct TimelineEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case needsYou
        case working
        case done
        case exited
        case approved
        case denied
        case answered
        case problem
        case notice
    }

    var id: String
    var date: Date
    var kind: Kind
    var sessionId: String?
    var lane: String
    var text: String
    var detail: String?

    var color: Color {
        switch kind {
        case .needsYou, .problem: return AigoPalette.coral
        case .working, .approved, .answered: return AigoPalette.lime
        case .done: return AigoPalette.ice
        case .denied, .notice: return AigoPalette.secondary
        case .exited: return AigoPalette.idle
        }
    }
}

enum Clock {
    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayHM: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    /// "18:11" today, "Tue 18:11" otherwise.
    static func short(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? hm.string(from: date) : dayHM.string(from: date)
    }

    /// "just now", "12 minutes ago", "3 hours ago", "2 days ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        let m = Int(s / 60)
        if m < 60 { return m == 1 ? "1 minute ago" : "\(m) minutes ago" }
        let h = m / 60
        if h < 24 { return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = h / 24
        return d == 1 ? "yesterday" : "\(d) days ago"
    }
}
