import SwiftUI
import UIKit

enum AppRoute: Hashable {
    case session(String)
    case settings
}

enum ConnectionState: Equatable {
    case unpaired      // no paired host
    case connecting
    case online
    case offline(String)
}

/// Single source of truth for the UI: the active host, its sessions and
/// inbox, kept live by the /events WebSocket.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var hosts: [HostCredentials] = []
    @Published private(set) var activeHostID: String?
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var inbox: [InboxItem] = []
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var connection: ConnectionState = .unpaired
    @Published private(set) var hostDisplayName: String = ""
    @Published var path: [AppRoute] = []
    @Published var pairDraft: PairDraft?
    @Published var showPairSheet = false

    private(set) var client: APIClient?
    private var events: LiveSocket?
    private let live: LiveActivityController
    private var started = false
    private var wentToBackground = false
    /// Questions answered through the on-screen menu: hidden until the host
    /// resolves the inbox row (it does so when the agent continues).
    private var locallyAnswered: Set<String> = []

    init() {
        live = LiveActivityController()
        hosts = HostVault.load()
        let saved = UserDefaults.standard.string(forKey: "activeHostID")
        if let saved = saved, hosts.contains(where: { $0.id == saved }) {
            activeHostID = saved
        } else {
            activeHostID = hosts.first?.id
        }
    }

    var activeHost: HostCredentials? {
        hosts.first { $0.id == activeHostID }
    }

    // MARK: - Derived state

    var pendingItems: [InboxItem] {
        inbox
            .filter { $0.isPendingApproval && !locallyAnswered.contains($0.id) }
            .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    }

    var sortedSessions: [SessionInfo] {
        sessions.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            return (a.createdAt ?? "") > (b.createdAt ?? "")
        }
    }

    var workingCount: Int {
        sessions.filter { $0.status == .working || $0.status == .stalled }.count
    }

    var needsYouCount: Int {
        max(pendingItems.count, sessions.filter { $0.status == .needsYou }.count)
    }

    var statusSentence: String {
        if activeHost == nil {
            return "Pair your PC to get started."
        }
        if case .offline = connection, sessions.isEmpty {
            return "Can't reach \(hostLabel) right now."
        }
        let needs = needsYouCount
        let working = workingCount
        var parts: [String] = []
        if needs > 0 {
            parts.append(needs == 1 ? "1 agent needs you." : "\(needs) agents need you.")
        }
        if working > 0 {
            if needs > 0 {
                parts.append(working == 1 ? "1 is working." : "\(working) are working.")
            } else {
                parts.append(working == 1 ? "1 agent is working." : "\(working) agents are working.")
            }
        }
        if parts.isEmpty {
            return sessions.isEmpty ? "Nothing is running. Tap + to start." : "All quiet. Nothing needs you."
        }
        return parts.joined(separator: " ")
    }

    var hostLabel: String {
        if !hostDisplayName.isEmpty { return hostDisplayName }
        return activeHost?.hostName ?? "your PC"
    }

    func session(id: String) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    func agentName(_ id: String?) -> String {
        if let id = id, let a = agents.first(where: { $0.id == id }), let n = a.name, !n.isEmpty {
            return n
        }
        return AgentNames.display(id)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        NotificationManager.shared.onOpenSession = { [weak self] id in
            self?.openSession(id)
        }
        NotificationManager.shared.requestAuthorization()
        connect()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wentToBackground = true
        case .active:
            // iOS suspends sockets in the background: reconnect for a fresh snapshot.
            if started && wentToBackground {
                wentToBackground = false
                if activeHost != nil {
                    events?.restart()
                }
            }
        default:
            break
        }
    }

    func connect() {
        disconnect()
        guard let host = activeHost else {
            connection = .unpaired
            sessions = []
            inbox = []
            live.end()
            return
        }
        let c = APIClient(credentials: host)
        client = c
        hostDisplayName = host.hostName
        let socket = LiveSocket(client: c, path: "/api/v1/events")
        socket.onState = { [weak self] state in
            self?.socketStateChanged(state)
        }
        socket.onMessage = { [weak self] data in
            self?.handleEvent(data)
        }
        events = socket
        socket.start()
        Task { await self.loadAgents() }
    }

    private func disconnect() {
        events?.stop()
        events = nil
        client?.invalidate()
        client = nil
    }

    private func socketStateChanged(_ state: LiveSocket.State) {
        switch state {
        case .connecting:
            if connection != .online {
                connection = .connecting
            }
        case .open:
            connection = .online
        case .closed(let reason):
            connection = .offline(reason)
        }
    }

    // MARK: - Events

    private func handleEvent(_ data: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(EventEnvelope.self, from: data) else { return }
        switch envelope.type {
        case "snapshot":
            guard let snap = try? decoder.decode(DataEnvelope<Snapshot>.self, from: data).data else { return }
            sessions = snap.sessions ?? []
            withAnimation(.easeInOut(duration: 0.25)) {
                inbox = snap.inbox ?? []
                pruneLocallyAnswered()
            }
            if let name = snap.host?.hostName, !name.isEmpty {
                hostDisplayName = name
                rememberHostName(name)
            }
        case "session.updated":
            guard let info = try? decoder.decode(DataEnvelope<SessionInfo>.self, from: data).data else { return }
            upsertSession(info)
        case "session.removed":
            guard let gone = try? decoder.decode(DataEnvelope<IDOnly>.self, from: data).data else { return }
            sessions.removeAll { $0.id == gone.id }
        case "inbox.updated":
            guard let item = try? decoder.decode(DataEnvelope<InboxItem>.self, from: data).data else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                upsertInbox(item)
            }
        case "inbox.reset":
            Task { await self.reloadInbox() }
        case "notify":
            guard let notice = try? decoder.decode(DataEnvelope<HostNotice>.self, from: data).data else { return }
            NotificationManager.shared.post(notice, hostName: hostLabel)
        default:
            return
        }
        refreshLiveActivity()
    }

    private func upsertSession(_ info: SessionInfo) {
        if let i = sessions.firstIndex(where: { $0.id == info.id }) {
            sessions[i] = info
        } else {
            sessions.append(info)
        }
    }

    private func upsertInbox(_ item: InboxItem) {
        if let i = inbox.firstIndex(where: { $0.id == item.id }) {
            inbox[i] = item
        } else {
            inbox.insert(item, at: 0)
        }
        pruneLocallyAnswered()
    }

    private func pruneLocallyAnswered() {
        locallyAnswered = locallyAnswered.filter { id in
            inbox.contains { $0.id == id && $0.isPendingApproval }
        }
    }

    private func rememberHostName(_ name: String) {
        guard let i = hosts.firstIndex(where: { $0.id == activeHostID }), hosts[i].hostName != name else { return }
        hosts[i].hostName = name
        HostVault.save(hosts)
    }

    private func refreshLiveActivity() {
        guard activeHost != nil else {
            live.end()
            return
        }
        let pending = pendingItems
        let working = sortedSessions.filter { $0.status == .working || $0.status == .stalled }
        var headline = ""
        var detail = ""
        if let top = pending.first {
            headline = top.title ?? "An agent needs you"
            detail = top.message ?? top.contextLine
        } else if let blocked = sessions.first(where: { $0.status == .needsYou }) {
            headline = blocked.displayTitle
            detail = "Waiting for your answer"
        } else if let w = working.first {
            headline = w.displayTitle
            detail = w.nowLine
        }
        live.update(hostName: hostLabel, working: working.count, needsYou: needsYouCount,
                    headline: headline, detail: detail)
    }

    // MARK: - Loading

    func refresh() async {
        guard let c = client else { return }
        do {
            let s = try await c.sessions()
            let i = try await c.inbox()
            sessions = s
            withAnimation(.easeInOut(duration: 0.25)) {
                inbox = i
                pruneLocallyAnswered()
            }
            refreshLiveActivity()
        } catch {
            connection = .offline(APIError.describe(error))
        }
        if connection != .online {
            events?.restart()
        }
    }

    func reloadInbox() async {
        guard let c = client, let items = try? await c.inbox() else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            inbox = items
            pruneLocallyAnswered()
        }
        refreshLiveActivity()
    }

    func loadAgents() async {
        guard let c = client, let list = try? await c.agents() else { return }
        agents = list
    }

    func recentDirs() async -> [RecentDir] {
        guard let c = client else { return [] }
        return (try? await c.recentDirs()) ?? []
    }

    // MARK: - Navigation

    func openSession(_ id: String) {
        path = [.session(id)]
    }

    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "aigo" else { return }
        let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() ?? ""
        switch host {
        case "pair":
            if let draft = PairDraft(url: url) {
                pairDraft = draft
                showPairSheet = true
            }
        case "session":
            let parts = url.pathComponents.filter { $0 != "/" }
            if let id = parts.first {
                openSession(id)
            }
        default:
            path = []
        }
    }

    func sendViewing(_ sessionID: String) {
        events?.send(["type": "viewing", "sessionId": sessionID])
    }

    // MARK: - Hosts

    func pair(_ draft: PairDraft) async throws {
        let addr = PairDraft.normalizeAddress(draft.addr)
        let fp = CertificatePin.normalize(draft.fingerprint)
        let code = draft.code.filter { $0.isNumber }
        guard !addr.isEmpty else {
            throw APIError(status: 0, message: "Enter the PC's address, like 10.0.0.10:47211.")
        }
        guard fp.count == 64 else {
            throw APIError(status: 0, message: "The fingerprint should be 64 hex characters.")
        }
        guard code.count == 6 else {
            throw APIError(status: 0, message: "The pairing code has 6 digits.")
        }
        var creds = try await APIClient.pair(addr: addr, fingerprint: fp, code: code,
                                             deviceName: UIDevice.current.name)
        if creds.hostName.isEmpty || creds.hostName == "PC", !draft.hostName.isEmpty {
            creds.hostName = draft.hostName
        }
        hosts.removeAll { $0.id == creds.id || $0.addr == creds.addr }
        hosts.append(creds)
        HostVault.save(hosts)
        pairDraft = nil
        activate(creds.id)
    }

    func activate(_ id: String) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        activeHostID = id
        UserDefaults.standard.set(id, forKey: "activeHostID")
        sessions = []
        inbox = []
        locallyAnswered = []
        path = []
        live.end()
        connect()
    }

    func forget(_ id: String) {
        hosts.removeAll { $0.id == id }
        HostVault.save(hosts)
        if activeHostID == id {
            activeHostID = hosts.first?.id
            UserDefaults.standard.set(activeHostID, forKey: "activeHostID")
            sessions = []
            inbox = []
            path = []
            live.end()
            connect()
        }
    }

    // MARK: - Actions (each returns an error message, or nil on success)

    func decide(_ item: InboxItem, approve: Bool, choice: String? = nil) async -> String? {
        guard let c = client else { return "Not connected to your PC." }
        guard let action = item.actionId, !action.isEmpty else { return "This item can't be answered from here." }
        do {
            try await c.decide(actionId: action, approve: approve, choice: choice)
            withAnimation(.easeInOut(duration: 0.3)) {
                if let i = inbox.firstIndex(where: { $0.id == item.id }) {
                    inbox[i].pending = false
                    inbox[i].decision = approve ? "approve" : "deny"
                }
            }
            refreshLiveActivity()
            return nil
        } catch {
            return APIError.describe(error)
        }
    }

    /// Answers an agent's question by picking the matching option of the
    /// menu shown in its terminal (AskUserQuestion has no hook-side answer).
    func answerQuestion(_ item: InboxItem, number: Int, label: String) async -> String? {
        guard let sid = item.sessionId, !sid.isEmpty else {
            return "This agent runs outside Aigo. Answer it in its own terminal."
        }
        if let err = await chooseMenu(sid, number: number, label: label) {
            return err
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            _ = locallyAnswered.insert(item.id)
        }
        refreshLiveActivity()
        return nil
    }

    func sendPrompt(_ sessionID: String, _ text: String) async -> String? {
        await perform { try await $0.prompt(sessionID, text: text) }
    }

    func sendKeys(_ sessionID: String, _ keys: [String]) async -> String? {
        await perform { try await $0.keys(sessionID, keys: keys) }
    }

    func chooseMenu(_ sessionID: String, number: Int, label: String) async -> String? {
        await perform { try await $0.chooseMenu(sessionID, number: number, label: label) }
    }

    func interrupt(_ sessionID: String) async -> String? {
        await perform { try await $0.interrupt(sessionID) }
    }

    func kill(_ sessionID: String) async -> String? {
        await perform { try await $0.kill(sessionID) }
    }

    func restart(_ sessionID: String) async -> String? {
        guard let c = client else { return "Not connected to your PC." }
        do {
            let info = try await c.restart(sessionID)
            upsertSession(info)
            return nil
        } catch {
            return APIError.describe(error)
        }
    }

    func remove(_ sessionID: String) async -> String? {
        let err = await perform { try await $0.remove(sessionID) }
        if err == nil {
            sessions.removeAll { $0.id == sessionID }
            refreshLiveActivity()
        }
        return err
    }

    func createSession(_ body: [String: Any]) async throws -> SessionInfo {
        guard let c = client else {
            throw APIError(status: 0, message: "Not connected to your PC.")
        }
        let info = try await c.createSession(body)
        upsertSession(info)
        refreshLiveActivity()
        return info
    }

    private func perform(_ op: (APIClient) async throws -> Void) async -> String? {
        guard let c = client else { return "Not connected to your PC." }
        do {
            try await op(c)
            return nil
        } catch {
            return APIError.describe(error)
        }
    }
}
