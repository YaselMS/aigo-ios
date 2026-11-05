import Foundation

/// Live chat transcript of one session (WS /api/v1/sessions/{id}/transcript).
@MainActor
final class TranscriptModel: ObservableObject {
    @Published private(set) var messages: [TranscriptMessage] = []
    @Published private(set) var hasMore = false
    @Published private(set) var waiting = true
    @Published private(set) var error: String?
    /// Increments when new messages arrive at the bottom (drives auto-scroll).
    @Published private(set) var bottomTick = 0

    private var socket: LiveSocket?
    private var sessionID: String?

    func start(client: APIClient, sessionID: String) {
        if self.sessionID == sessionID && socket != nil { return }
        stop()
        self.sessionID = sessionID
        let s = LiveSocket(client: client, path: "/api/v1/sessions/\(sessionID)/transcript")
        s.onMessage = { [weak self] data in
            self?.handle(data)
        }
        s.onState = { [weak self] state in
            if case .closed(let problem) = state {
                self?.error = problem.message
            } else if state == .open {
                self?.error = nil
            }
        }
        socket = s
        s.start()
    }

    func stop() {
        socket?.stop()
        socket = nil
        sessionID = nil
    }

    func loadOlder() {
        socket?.send(["type": "older", "count": 200])
    }

    /// What Chat shows: conversation text, tool calls and results.
    var visible: [TranscriptMessage] {
        messages.filter { m in
            if m.sidechain == true { return false }
            switch m.kind ?? "text" {
            case "thinking", "title":
                return false
            case "text":
                return !(m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(TranscriptFrame.self, from: data) else { return }
        switch frame.type {
        case "waiting":
            waiting = true
        case "backlog":
            waiting = false
            messages = frame.messages ?? []
            hasMore = frame.hasMore ?? false
            bottomTick += 1
        case "append":
            waiting = false
            messages.append(contentsOf: frame.messages ?? [])
            bottomTick += 1
        case "older":
            messages.insert(contentsOf: frame.messages ?? [], at: 0)
            hasMore = frame.hasMore ?? false
        case "error":
            error = frame.error
        default:
            break
        }
    }
}
