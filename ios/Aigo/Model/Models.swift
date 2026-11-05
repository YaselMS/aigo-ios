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
}

/// GET /api/v1/sessions/{id}/screen
struct ScreenState: Codable, Equatable {
    var text: String?
    var menu: ScreenMenu?
    var preview: [String]?
    var working: String?
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
}

/// data of the first `snapshot` event on /api/v1/events.
struct Snapshot: Codable {
    var host: HostInfo?
    var sessions: [SessionInfo]?
    var inbox: [InboxItem]?
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

/// POST /api/v1/pairing/complete response.
struct PairResponse: Decodable {
    var token: String
    var hostId: String?
    var hostName: String?
}

struct ErrorBody: Decodable {
    var error: String?
}
