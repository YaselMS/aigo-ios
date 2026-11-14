import SwiftUI

/// The plain-language status shown for a session.
enum SessionStatus: Int, Comparable {
    case needsYou = 0
    case working
    case stalled
    case done
    case idle
    case exited

    static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .needsYou: return "needs you"
        case .working: return "working"
        case .stalled: return "quiet"
        case .done: return "done"
        case .idle: return "idle"
        case .exited: return "exited"
        }
    }

    /// nil = draw a grey outline dot (idle).
    var color: Color? {
        switch self {
        case .needsYou: return AigoPalette.coral
        case .working: return AigoPalette.lime
        case .stalled: return AigoPalette.lime.opacity(0.45)
        case .done: return AigoPalette.ice
        case .idle: return nil
        case .exited: return AigoPalette.secondary.opacity(0.35)
        }
    }
}

enum AgentNames {
    static func display(_ id: String?) -> String {
        switch id ?? "" {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "gentle-shell": return "gentle-shell"
        case "terminal": return "Terminal"
        case "command": return "Command"
        case "gemini": return "Gemini CLI"
        case "aider": return "Aider"
        case "": return "Terminal"
        default: return id ?? "Agent"
        }
    }
}

/// Last path component of a Windows or POSIX path.
func folderName(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "" }
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
    let parts = trimmed.split(whereSeparator: { $0 == "\\" || $0 == "/" })
    return parts.last.map(String.init) ?? path
}

extension SessionInfo {
    var isRunning: Bool { (state ?? "running") != "exited" }
    var isAgent: Bool { kind == "agent" || !(agent ?? "").isEmpty }

    var status: SessionStatus {
        if !isRunning { return .exited }
        if !(pendingActionId ?? "").isEmpty { return .needsYou }
        switch agentStatus ?? "" {
        case "blocked": return .needsYou
        case "working": return .working
        case "stalled": return .stalled
        case "done": return .done
        case "exited": return .exited
        default: return .idle
        }
    }

    var displayTitle: String {
        if let t = convTitle, !t.isEmpty { return t }
        if let t = title, !t.isEmpty { return t }
        return AgentNames.display(agent)
    }

    var subtitle: String {
        let who = isAgent ? AgentNames.display(agent) : "Terminal"
        let folder = folderName(cwd)
        return folder.isEmpty ? who : "\(who) · \(folder)"
    }

    /// One plain sentence about what is happening now.
    var nowLine: String {
        let prompt = (lastPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case .needsYou: return "Waiting for your answer"
        case .working: return prompt.isEmpty ? "Working…" : "Working on: \(prompt)"
        case .stalled: return "Working, but quiet for a while"
        case .done: return prompt.isEmpty ? "Finished. Tap to review." : "Finished: \(prompt)"
        case .idle:
            if !isAgent { return "Terminal open" }
            return prompt.isEmpty ? "Ready for a message" : "Last: \(prompt)"
        case .exited:
            if let note = exitNote, !note.isEmpty { return "Exited: \(note)" }
            if let code = exitCode { return "Exited (code \(code))" }
            return "Exited"
        }
    }
}

extension InboxItem {
    var isPendingApproval: Bool { pending == true && !(actionId ?? "").isEmpty }

    var contextLine: String {
        let who = AgentNames.display(agent)
        let place = (project?.isEmpty == false) ? project! : folderName(cwd)
        return place.isEmpty ? who : "\(who) · \(place)"
    }

    /// Commands that deserve a second confirming tap.
    var looksDestructive: Bool {
        let s = ((title ?? "") + " " + (toolName ?? "") + " " + (message ?? "")).lowercased()
        let patterns = [
            "git clean", "rm -rf", "rm -fr", "rm -r ", "del /s", "del /q", "rd /s", "rmdir /s",
            "format ", "format.com", "git reset --hard", "git push --force", "git push -f",
            "drop table", "drop database", "mkfs", "diskpart",
        ]
        if patterns.contains(where: { s.contains($0) }) { return true }
        if s.contains("remove-item") && s.contains("-recurse") { return true }
        return false
    }
}

// MARK: - Board (v0.3)

/// The four columns of the board (iPhone: tabs).
enum BoardColumn: String, CaseIterable, Identifiable {
    case ask, work, review, done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Needs you"
        case .work: return "Working"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .ask: return AigoPalette.coral
        case .work: return AigoPalette.lime
        case .review: return AigoPalette.ice
        case .done: return AigoPalette.idle
        }
    }

    var emptyText: String {
        switch self {
        case .ask: return "Nothing needs you."
        case .work: return "Nothing running."
        case .review: return "All reviewed."
        case .done: return "Nothing yet today."
        }
    }
}

extension SessionInfo {
    /// Most recent sign of life.
    var activityDate: Date? {
        AigoDate.parse(lastActivity) ?? AigoDate.parse(lastActivityAt) ?? AigoDate.parse(lastOutputAt) ??
            AigoDate.parse(statusChangedAt) ?? AigoDate.parse(startedAt) ?? AigoDate.parse(createdAt)
    }

    var isExternal: Bool { external == true }

    /// Board column. Uses the host's `board` field when the host sends one
    /// (`hostHasBoard`: any session carried the field, so a missing value
    /// means off the board); otherwise it is computed from the status:
    /// needs you = blocked, working = active in the last 30 minutes,
    /// review = finished a turn and not seen yet, done = touched today.
    func boardColumn(hostHasBoard: Bool, now: Date = Date()) -> BoardColumn? {
        if hostHasBoard {
            if status == .needsYou { return .ask }
            return BoardColumn(rawValue: board ?? "")
        }
        let last = activityDate
        let today = last.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
        switch status {
        case .needsYou:
            return .ask
        case .working, .stalled:
            guard let last else { return .work }
            return now.timeIntervalSince(last) < 30 * 60 ? .work : nil
        case .done:
            return .review
        case .idle, .exited:
            guard isAgent, today else { return nil }
            // Opened but never given a task: not part of the board.
            if (lastPrompt ?? "").isEmpty && (convTitle ?? "").isEmpty { return nil }
            return .done
        }
    }
}

/// "now", "4m", "3h", "2d".
enum Age {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }
}

/// One card on the board: a pending approval/question, or a session.
struct BoardCard: Identifiable, Equatable {
    let id: String
    let column: BoardColumn
    let item: InboxItem?
    let session: SessionInfo?
    let date: Date?
    var external: ExternalSession? = nil
}

extension ExternalSession {
    var activityDate: Date? {
        AigoDate.parse(lastActivity) ?? AigoDate.parse(updatedAt) ?? AigoDate.parse(statusChangedAt)
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
        let folder = folderName(cwd)
        return folder.isEmpty ? AgentNames.display(agent) : "\(AgentNames.display(agent)) · \(folder)"
    }

    var transcriptStream: String { "/api/v1/external/\(key)/transcript" }

    /// Outside-Aigo sessions are only on the board while active: ask while
    /// blocked, work while busy (host `board`, or computed for older hosts).
    func boardColumn(now: Date = Date()) -> BoardColumn? {
        if let b = board {
            return b == "ask" ? .ask : (b == "work" ? .work : nil)
        }
        guard ended != true, stale != true, let last = activityDate, now.timeIntervalSince(last) < 30 * 60 else { return nil }
        switch status ?? "" {
        case "blocked": return .ask
        case "working": return .work
        default: return nil
        }
    }
}

extension SessionInfo {
    /// Case-insensitive match on what a person would search for.
    func matches(_ query: String) -> Bool {
        let fields = [title, convTitle, lastPrompt, cwd, agent, AgentNames.display(agent), model]
        return fields.contains { ($0 ?? "").localizedCaseInsensitiveContains(query) }
    }
}
