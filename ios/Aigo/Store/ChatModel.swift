import Foundation
import Network

/// Structured chat of one chat-mode session (host API §7k):
/// WS /sessions/{id}/chat?since=<seq> plus the POST commands.
/// Keeps the highest `seq`, so every reconnect (backoff, return from the
/// background, network change, close 1013) resumes with the missed events
/// instead of a full snapshot.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var thread: ChatThread?
    @Published private(set) var hasMore = false
    /// The first snapshot (or replay) arrived.
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// Increments when an item is added at the bottom.
    @Published private(set) var bottomTick = 0
    /// Increments when streamed text grows (follow the bottom without animation).
    @Published private(set) var streamTick = 0

    private(set) var seq = 0
    private var index: [String: Int] = [:]
    private var socket: LiveSocket?
    private var client: APIClient?
    private var sessionID: String?
    private var loadingOlder = false
    private var monitor: NWPathMonitor?
    private var networkWasDown = false

    var isRunning: Bool { thread?.isRunning ?? false }

    func start(client: APIClient, sessionID: String) {
        if self.sessionID == sessionID && socket != nil && self.client === client { return }
        if self.sessionID != sessionID {
            reset()
        }
        stopSocket()
        self.client = client
        self.sessionID = sessionID
        let s = LiveSocket(client: client, path: "/api/v1/sessions/\(sessionID)/chat")
        s.pathProvider = { [weak self] in
            let since = self?.seq ?? 0
            return "/api/v1/sessions/\(sessionID)/chat?since=\(since)"
        }
        s.onMessage = { [weak self] data in
            self?.handle(data)
        }
        s.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .open:
                self.error = nil
            case .closed(let problem):
                self.error = problem.message
                self.loadingOlder = false
            case .connecting:
                break
            }
        }
        socket = s
        s.start()
        startMonitor()
    }

    func stop() {
        stopSocket()
        monitor?.cancel()
        monitor = nil
    }

    private func stopSocket() {
        socket?.stop()
        socket = nil
    }

    private func reset() {
        items = []
        index = [:]
        thread = nil
        hasMore = false
        loaded = false
        seq = 0
        error = nil
    }

    /// Reconnect now with the replay cursor (foreground, network back).
    func resync() {
        guard socket != nil else { return }
        socket?.restart()
    }

    /// Network came back: resync at once instead of waiting for the backoff.
    private func startMonitor() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if !up {
                    self.networkWasDown = true
                } else if self.networkWasDown {
                    self.networkWasDown = false
                    self.resync()
                }
            }
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        monitor = m
    }

    func loadOlder() {
        guard let first = items.first, !loadingOlder else { return }
        loadingOlder = true
        socket?.send(["type": "older", "before": first.id, "count": 200])
    }

    // MARK: - Stream

    private func handle(_ data: Data) {
        guard let ev = try? JSONDecoder().decode(ChatEvent.self, from: data) else { return }
        if ev.type == "older" {
            let older = (ev.items ?? []).filter { index[$0.id] == nil }
            items.insert(contentsOf: older, at: 0)
            rebuildIndex()
            hasMore = ev.hasMore ?? false
            loadingOlder = false
            return
        }
        if ev.type == "snapshot" {
            seq = ev.seq ?? seq
            items = ev.items ?? []
            rebuildIndex()
            if let t = ev.thread { thread = t }
            hasMore = ev.hasMore ?? false
            loaded = true
            bottomTick += 1
            return
        }
        if let s = ev.seq {
            // Already applied (an overlapping replay).
            if s <= seq { return }
            seq = s
        }
        loaded = true
        switch ev.type {
        case "item.add", "item.update":
            guard let item = ev.item else { return }
            if let i = index[item.id] {
                items[i] = item
                streamTick += 1
            } else {
                items.append(item)
                index[item.id] = items.count - 1
                bottomTick += 1
            }
        case "item.delta":
            guard let id = ev.id, let i = index[id], let text = ev.text else { return }
            if ev.field == "output" {
                var tool = items[i].tool ?? ChatTool()
                tool.output = (tool.output ?? "") + text
                items[i].tool = tool
            } else {
                items[i].text = (items[i].text ?? "") + text
            }
            streamTick += 1
        case "thread.update":
            if let t = ev.thread { thread = t }
        default:
            break
        }
    }

    private func rebuildIndex() {
        index = [:]
        for (i, it) in items.enumerated() {
            index[it.id] = i
        }
    }

    // MARK: - Commands

    /// Sends a message (a new turn, or input to the running one). The user
    /// item appears at once with the client id as its id; the host's
    /// item.add with the same id replaces it.
    func send(_ text: String, by device: String) async -> String? {
        let clientId = ChatModel.newClientId()
        let local = ChatItem(id: clientId, type: "user", status: "done", text: text, by: device)
        if index[clientId] == nil {
            items.append(local)
            index[clientId] = items.count - 1
            bottomTick += 1
        }
        let err = await command("send", ["text": text, "clientId": clientId])
        if err != nil, let i = index[clientId], items[i].at == nil {
            // Never reached the host: take the bubble back.
            items.remove(at: i)
            rebuildIndex()
        }
        return err
    }

    func respond(requestId: String, option: String) async -> String? {
        await command("respond", ["requestId": requestId, "option": option, "clientId": ChatModel.newClientId()])
    }

    func respond(requestId: String, answers: [String: String]) async -> String? {
        await command("respond", ["requestId": requestId, "answers": answers, "clientId": ChatModel.newClientId()])
    }

    func interrupt() async -> String? {
        await command("interrupt", ["clientId": ChatModel.newClientId()])
    }

    func settings(model: String? = nil, effort: String? = nil, access: String? = nil) async -> String? {
        var body: [String: Any] = ["clientId": ChatModel.newClientId()]
        if let model { body["model"] = model }
        if let effort { body["effort"] = effort }
        if let access { body["access"] = access }
        return await command("settings", body)
    }

    /// POSTs a command; a transport failure is retried once with the same
    /// client id (the host runs it once).
    private func command(_ name: String, _ body: [String: Any]) async -> String? {
        guard let c = client, let sid = sessionID else { return "Not connected to your PC." }
        var attempt = 0
        while true {
            do {
                try await c.chatCommand(sid, name, body: body)
                return nil
            } catch let e as APIError where e.status >= 400 {
                return ChatModel.describe(e)
            } catch {
                attempt += 1
                if attempt >= 2 { return c.problem(for: error).message }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    static func describe(_ e: APIError) -> String {
        switch e.code ?? "" {
        case "trust": return "Answer the folder trust card in the chat first."
        case "not_open": return "That request was already answered or is no longer open."
        case "not_running": return "Nothing is running right now."
        case "terminal_mode": return "This session now runs in a terminal."
        default: return e.message
        }
    }

    static func newClientId() -> String {
        "ios-" + UUID().uuidString.lowercased()
    }
}
