import Foundation

// Codable mirrors of the host's JSON (protocol v1). Go omits empty fields
// (`omitempty`) and may send null for nil slices, so nearly every field is
// optional and dates are kept as the raw RFC 3339 strings.

/// sessions.Info (internal/sessions/manager.go).
struct SessionInfo: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var kind: String?          // shell | agent | command
    var agent: String?
    var argv: [String]?
    var cwd: String?
    var createdAt: String?
    var startedAt: String?
    var state: String?         // running | exited
    var exitCode: Int?
    var exitNote: String?
    var agentSessionId: String?
    var agentStatus: String?   // idle | working | blocked | done | stalled | exited | unknown
    var statusChangedAt: String?
    var model: String?
    var convTitle: String?
    var lastPrompt: String?
    var lastActivityAt: String?
    var pendingActionId: String?
    var viewed: Bool?
    var restored: Bool?
    var resumable: Bool?
    var cols: Int?
    var rows: Int?
    var lastOutputAt: String?
    // v0.3 board (host issue #27). Optional: older hosts omit them and the
    // app computes the column itself (SessionInfo.boardColumn).
    var board: String?         // ask | work | review | done | "" (off the board)
    var lastActivity: String?
    var seenAt: String?
    var finishedAt: String?
    var external: Bool?
}

/// agentevents.External: an agent started outside Aigo, known from its hooks
/// (snapshot `external`, `external.updated` events, GET /api/v1/external).
struct ExternalSession: Codable, Identifiable, Equatable {
    var key: String
    var agent: String?
    var agentSessionId: String?
    var cwd: String?
    var transcriptPath: String?
    var status: String?        // working | blocked | done | idle | exited ...
    var statusChangedAt: String?
    var lastPrompt: String?
    var model: String?
    var updatedAt: String?
    var ended: Bool?
    var external: Bool?
    var title: String?
    var board: String?         // ask | work | "" (v0.3 hosts)
    var lastActivity: String?
    var stale: Bool?
    var id: String { key }
}

/// One result of GET /api/v1/search (v0.3 host).
struct SearchItem: Codable, Identifiable, Equatable {
    var kind: String?          // session | external | history
    var id: String
    var agent: String?
    var agentSessionId: String?
    var title: String?
    var cwd: String?
    var project: String?
    var lastPrompt: String?
    var lastMessage: String?
    var status: String?
    var board: String?
    var lastActivity: String?
    var external: Bool?
    var transcript: String?
}

struct SearchResponse: Codable {
    var items: [SearchItem]?
    var nextOffset: Int?
    var total: Int?
}

/// Counts of the board (snapshot `board`, `board.updated` events).
struct BoardCounts: Codable, Equatable {
    var ask: Int?
    var work: Int?
    var review: Int?
    var done: Int?
}

/// inbox.Item (internal/inbox/inbox.go).
struct InboxItem: Codable, Identifiable, Equatable {
    var id: String
    var key: String?
    var category: String?      // approval_required | task_complete | error | ...
    var kind: String?          // permission | question | plan | ask
    var agent: String?
    var agentSessionId: String?
    var sessionId: String?
    var cwd: String?
    var project: String?
    var title: String?
    var message: String?
    var toolName: String?
    var actionId: String?
    var pending: Bool?
    var options: [String]?
    var decision: String?
    var decidedBy: String?
    var read: Bool?
    var createdAt: String?
    var updatedAt: String?
}

/// transcript.Message (internal/transcript/transcript.go).
struct TranscriptMessage: Codable, Identifiable, Equatable {
    var id: String
    var line: Int?
    var role: String?          // user | assistant | tool | system
    var kind: String?          // text | thinking | tool_use | tool_result | image | title
    var text: String?
    var toolName: String?
    var toolInput: String?
    var toolUseId: String?
    var isError: Bool?
    var time: String?
    var model: String?
    var sidechain: Bool?
}

/// agents.Agent (internal/agents/agents.go). Empty binary = not installed.
struct AgentInfo: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var tier: String?
    var binary: String?
    var canHooks: Bool?
    var custom: Bool?

    var installed: Bool { !(binary ?? "").isEmpty }
    var displayName: String { name ?? id }
}

struct AgentsResponse: Codable {
    var agents: [AgentInfo]?
}

/// sessions.MenuOption / sessions.Menu (internal/sessions/menu.go).
struct MenuOption: Codable, Identifiable, Equatable {
    var number: Int
    var label: String
    var id: Int { number }
}

struct ScreenMenu: Codable, Equatable {
    var title: String?
    var options: [MenuOption]?
    var selected: Int?
    /// One short sentence of guidance for dialogs Aigo knows (issue #6).
    var note: String?
    /// 0-based index into `options` of the option Aigo recommends (issue #6).
    var recommended: Int?

    /// `note`, trimmed, or nil.
    var guidance: String? {
        let n = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    func isRecommended(_ option: MenuOption) -> Bool {
        guard let r = recommended, let list = options, r >= 0, r < list.count else { return false }
        return list[r] == option
    }
}

/// GET /api/v1/sessions/{id}/screen
struct ScreenState: Codable, Equatable {
    var text: String?
    var menu: ScreenMenu?
    var preview: [String]?
    var working: String?
}

/// gitx.File (GET /api/v1/git/status).
struct GitFile: Codable, Identifiable, Equatable {
    var path: String
    var origPath: String?
    var index: String?
    var worktree: String?
    var added: Int?
    var deleted: Int?
    var binary: Bool?
    var id: String { path }

    /// One status letter: M, A, D, R, ? ...
    var letter: String {
        let w = (worktree ?? ".").trimmingCharacters(in: .whitespaces)
        let i = (index ?? ".").trimmingCharacters(in: .whitespaces)
        if !w.isEmpty && w != "." { return w }
        if !i.isEmpty && i != "." { return i }
        return "M"
    }
}

/// gitx.Status.
struct GitStatus: Codable, Equatable {
    var root: String?
    var branch: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var files: [GitFile]?
    var added: Int?
    var deleted: Int?
}

struct GitDiff: Codable {
    var diff: String?
}

/// GET /api/v1/recent-dirs
struct RecentDir: Codable, Identifiable, Equatable {
    var path: String
    var last: String?
    var id: String { path }
}

/// Subset of the host info map (server.info()).
struct HostInfo: Codable {
    var hostName: String?
    var hostId: String?
    var version: String?
    var fingerprint: String?
    var remote: RemoteInfo?
}

/// Host info `remote` (docs/API.md §7).
struct RemoteInfo: Codable {
    var enabled: Bool?
    var port: String?
    /// Every reachable host:port, best first (v0.4 hosts).
    var endpoints: [String]?
    var tailscale: TailscaleInfo?

    private enum CodingKeys: String, CodingKey { case enabled, port, endpoints, tailscale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        // Be lenient: port may be a number or a string.
        if let s = try? c.decodeIfPresent(String.self, forKey: .port) {
            port = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .port) {
            port = String(n)
        }
        endpoints = try? c.decodeIfPresent([String].self, forKey: .endpoints)
        tailscale = try? c.decodeIfPresent(TailscaleInfo.self, forKey: .tailscale)
    }
}

struct TailscaleInfo: Codable {
    var ip: String?
    var dnsName: String?
}

/// data of the first `snapshot` event on /api/v1/events.
struct Snapshot: Codable {
    var host: HostInfo?
    var sessions: [SessionInfo]?
    var inbox: [InboxItem]?
    var notifications: [HostNotice]?
    var external: [ExternalSession]?
    var board: BoardCounts?
}

/// notify.Notification (internal/notify/notify.go), data of `notify` events.
struct HostNotice: Codable {
    var id: String?
    var category: String?
    var title: String?
    var body: String?
    var sessionId: String?
    var agent: String?
    var actionId: String?
    var at: String?
}

struct EventEnvelope: Decodable {
    var type: String
}

struct DataEnvelope<T: Decodable>: Decodable {
    var data: T
}

struct IDOnly: Decodable {
    var id: String
}

/// Frames of WS /api/v1/sessions/{id}/transcript.
struct TranscriptFrame: Decodable {
    var type: String
    var messages: [TranscriptMessage]?
    var hasMore: Bool?
    var error: String?
}

/// JSON frames of WS /api/v1/sessions/{id}/attach (output itself is binary).
struct AttachFrame: Decodable {
    var type: String
    var session: SessionInfo?
    var code: Int?
    // `size` (docs/API.md §6, v0.4 hosts)
    var cols: Int?
    var rows: Int?
    var owner: Bool?
    var mode: String?
    var reason: String?
    var replay: Bool?
    // `hello.terminal` (issue #94, desktop v0.4.0): replays are raw VT, `report` is understood.
    var terminal: AttachTerminal?
}

struct AttachTerminal: Decodable {
    /// "raw": snapshots are replays of raw VT output.
    var replay: String?
    /// The host accepts `{"type":"report"}` for the emulator's own replies.
    var report: Bool?
}

/// POST /api/v1/pairing/complete response.
struct PairResponse: Decodable {
    var token: String
    var hostId: String?
    var hostName: String?
}

struct ErrorBody: Decodable {
    var error: String?
}

/// Go marshals time.Time as RFC 3339 with up to 9 fractional digits; the
/// zero time ("0001-01-01T00:00:00Z") means "not set".
enum AigoDate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard var s = raw, s.count >= 20 else { return nil }
        if s.hasPrefix("0001-") { return nil }
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber {
                end = s.index(after: end)
            }
            fraction = Double("0" + String(s[dot..<end])) ?? 0
            s.removeSubrange(dot..<end)
        }
        guard let d = plain.date(from: s) else { return nil }
        return d.addingTimeInterval(fraction)
    }
}
