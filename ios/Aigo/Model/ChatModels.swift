import Foundation

// Structured chat (host API §7k) and workspace (§7l) JSON. Like the rest of
// Models.swift: Go omits empty fields, so nearly everything is optional.

/// One entry of a chat thread's timeline (chat.Item).
struct ChatItem: Codable, Identifiable, Equatable {
    var id: String
    var turn: String?
    /// user | assistant | reasoning | tool | plan | request | notice | turn
    var type: String
    /// running | done | error | declined | interrupted; request: open | answered | expired
    var status: String?
    var text: String?
    var tool: ChatTool?
    var steps: [ChatStep]?
    var request: ChatRequest?
    var usage: ChatUsage?
    var parent: String?
    var ms: Int?
    var at: String?
    var by: String?

    var isRunning: Bool { status == "running" }
}

struct ChatTool: Codable, Equatable {
    /// command | edit | read | search | mcp | web | agent | other
    var kind: String?
    var title: String?
    var detail: String?
    var output: String?
    var diff: String?
    var exit: Int?
}

struct ChatStep: Codable, Equatable {
    var text: String?
    /// pending | running | done
    var status: String?
}

struct ChatRequest: Codable, Equatable {
    /// approval | question
    var kind: String?
    var title: String?
    var body: String?
    var options: [ChatOption]?
    var questions: [ChatQuestion]?
    var `for`: String?
    var answer: String?
    var tool: String?
}

/// A request option: `id` is the harness's native id, sent back as is.
struct ChatOption: Codable, Equatable, Identifiable {
    var id: String
    var label: String?
    /// primary | danger | ""
    var style: String?

    var title: String { (label ?? "").isEmpty ? id : label! }
}

struct ChatQuestion: Codable, Equatable, Identifiable {
    var id: String
    var header: String?
    var text: String?
    var options: [ChatOption]?
    var freeText: Bool?
    var secret: Bool?
}

struct ChatUsage: Codable, Equatable {
    var input: Int?
    var cached: Int?
    var output: Int?
    var total: Int?
    var context: Int?
    var last: Int?
}

struct ChatModelInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    var efforts: [String]?
    var defaultEffort: String?
    var isDefault: Bool?
    var description: String?

    var title: String { (name ?? "").isEmpty ? id : name! }
}

/// The thread header: harness, controls and turn state.
struct ChatThread: Codable, Equatable {
    var harness: String?
    var version: String?
    var threadId: String?
    var model: String?
    var effort: String?
    var access: String?
    var accessModes: [String]?
    var models: [ChatModelInfo]?
    var running: Bool?
    var turnId: String?
    var usage: ChatUsage?
    var ctxPct: Int?
    var account: String?
    var cwd: String?
    var error: String?
    /// A harness process is attached. False: the timeline is a replay and the
    /// next message resumes it.
    var live: Bool?

    var isRunning: Bool { running == true }
}

/// One frame of WS /sessions/{id}/chat (chat.Event).
struct ChatEvent: Decodable {
    var type: String
    var seq: Int?
    var item: ChatItem?
    var id: String?
    var field: String?
    var text: String?
    var thread: ChatThread?
    var items: [ChatItem]?
    var hasMore: Bool?
}

/// Aigo's access-mode words (host API §7k).
enum ChatAccess {
    static func label(_ mode: String) -> String {
        switch mode {
        case "default": return "Config default"
        case "ask": return "Ask first"
        case "auto": return "Auto"
        case "read-only": return "Read-only"
        case "full": return "Full access"
        case "edits": return "Accept edits"
        case "plan": return "Plan"
        default: return mode
        }
    }
}

// MARK: - Workspace (host API §7l)

struct WorkspaceSection: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    var items: [String]?

    var title: String { (name ?? "").isEmpty ? id : name! }
}

/// GET /api/v1/workspace (`items` only with `resolve=1`).
struct WorkspaceDoc: Codable, Equatable {
    var version: Int?
    var updatedAt: String?
    var updatedBy: String?
    var pinned: [String]?
    var sections: [WorkspaceSection]?
    var names: [String: String]?
    var hidden: [String: String]?
    var items: [String: SearchItem]?

    /// Every id the document names (pinned, sections, names).
    var ids: Set<String> {
        var out = Set(pinned ?? [])
        for s in sections ?? [] { out.formUnion(s.items ?? []) }
        out.formUnion((names ?? [:]).keys)
        return out
    }
}

extension SearchItem {
    /// Workspace key: "<agent>:<agentSessionId>" when known, else the id.
    var workspaceKey: String {
        if let a = agent, !a.isEmpty, let s = agentSessionId, !s.isEmpty { return "\(a):\(s)" }
        return id
    }
}
