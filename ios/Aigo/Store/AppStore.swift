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
    case offline(ConnectionProblem)
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
    /// True once the first snapshot of the active host arrived.
    @Published private(set) var hasSnapshot = false
    /// "Since you left" digest, newest first, capped at `timelineCap`.
    @Published private(set) var timeline: [TimelineEvent] = []
    /// Recent session.updated arrival times per session (activity pulse).
    @Published private(set) var activity: [String: [Date]] = [:]
    /// When the app last went to the background (for "Since you left").
    @Published private(set) var lastLeftAt: Date?
    @Published var path: [AppRoute] = []
    @Published var pairDraft: PairDraft?
    @Published var showPairSheet = false
    @Published var showNewWork = false
    /// Agent New work should preselect (e.g. "codex" from the empty state).
    @Published var newWorkAgent: String?
    @Published var showSearch = false
    /// Sessions marked "Looks good" here; shown as Done until the host agrees.
    @Published private(set) var locallySeen: Set<String> = []
    /// Sessions found by search that are not in the live list (older chats,
    /// chats started outside Aigo), so they can be opened.
    @Published private(set) var searchCache: [String: SessionInfo] = [:]

    private(set) var client: APIClient?
    private var events: LiveSocket?
    private let live: LiveActivityController
    private var started = false
    private var wentToBackground = false
    /// Questions answered through the on-screen menu: hidden until the host
    /// resolves the inbox row (it does so when the agent continues).
    private var locallyAnswered: Set<String> = []
    /// Inbox items answered from this phone (so the digest does not repeat them).
    private var answeredHere: Set<String> = []
    private var intentObserver: NSObjectProtocol?

    private static let timelineCap = 100

    init() {
        live = LiveActivityController()
        hosts = HostVault.load()
        let saved = UserDefaults.standard.string(forKey: "activeHostID")
        if let saved = saved, hosts.contains(where: { $0.id == saved }) {
            activeHostID = saved
        } else {
            activeHostID = hosts.first?.id
        }
        let left = UserDefaults.standard.double(forKey: "lastLeftAt")
        if left > 0 {
            lastLeftAt = Date(timeIntervalSince1970: left)
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

    func pendingItems(for sessionID: String) -> [InboxItem] {
        pendingItems.filter { $0.sessionId == sessionID }
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

    var connectionProblem: ConnectionProblem? {
        if case .offline(let p) = connection { return p }
        return nil
    }

    var statusSentence: String {
        if activeHost == nil {
            return "Pair your PC to get started."
        }
        if connectionProblem != nil, sessions.isEmpty {
            return "Can't reach \(hostLabel) right now."
        }
        if !hasSnapshot {
            return "Connecting to \(hostLabel)…"
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
            return sessions.isEmpty ? "Nothing is running yet." : "All quiet. Nothing needs you."
        }
        return parts.joined(separator: " ")
    }

    var hostLabel: String {
        if !hostDisplayName.isEmpty { return hostDisplayName }
        let n = activeHost?.hostName ?? ""
        return n.isEmpty ? "your PC" : n
    }

    func session(id: String) -> SessionInfo? {
        sessions.first { $0.id == id } ?? searchCache[id]
    }

    // MARK: - Board

    /// True when the host sends the v0.3 `board` field.
    var hostHasBoard: Bool {
        sessions.contains { $0.board != nil }
    }

    func column(of s: SessionInfo, now: Date = Date()) -> BoardColumn? {
        var col = s.boardColumn(hostHasBoard: hostHasBoard, now: now)
        if col == .review && locallySeen.contains(s.id) { col = .done }
        return col
    }

    /// Cards of every column. Pending approvals and questions are their own
    /// cards in Needs you (even for agents outside Aigo); a session with a
    /// pending item is shown only through that item.
    var board: [BoardColumn: [BoardCard]] {
        let now = Date()
        var out: [BoardColumn: [BoardCard]] = [.ask: [], .work: [], .review: [], .done: []]
        let pending = pendingItems
        let withItems = Set(pending.compactMap { $0.sessionId })
        for item in pending {
            let s = item.sessionId.flatMap { session(id: $0) }
            out[.ask]?.append(BoardCard(id: "i:" + item.id, column: .ask, item: item, session: s,
                                        date: AigoDate.parse(item.createdAt)))
        }
        for s in sessions where !withItems.contains(s.id) {
            guard let col = column(of: s, now: now) else { continue }
            out[col]?.append(BoardCard(id: "s:" + s.id, column: col, item: nil, session: s, date: s.activityDate))
        }
        for col in BoardColumn.allCases {
            if col == .ask {
                out[col]?.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            } else {
                out[col]?.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            }
        }
        return out
    }

    /// "Looks good": Review -> Done.
    func markSeen(_ id: String) async -> String? {
        guard let c = client else { return "Not connected to your PC." }
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = locallySeen.insert(id)
        }
        do {
            try await c.seen(id)
        } catch let e as APIError where e.status == 404 || e.status == 405 {
            // Host without /seen: mark it viewed instead.
            try? await c.viewed(id)
        } catch {
            withAnimation { _ = locallySeen.remove(id) }
            return c.problem(for: error).message
        }
        return nil
    }

    /// Search: live sessions filtered here, merged with the host's results
    /// (which also cover older and outside-Aigo chats on v0.3 hosts).
    func search(_ query: String) async -> [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = q.isEmpty ? sortedByActivity(sessions) : sortedByActivity(sessions.filter { $0.matches(q) })
        guard !q.isEmpty, let c = client, let remote = try? await c.searchSessions(q) else { return local }
        let liveIDs = Set(sessions.map { $0.id })
        let remoteIDs = Set(remote.map { $0.id })
        if remoteIDs == liveIDs && remote.contains(where: { !$0.matches(q) }) {
            // The host ignored `q` (pre-v0.3): keep the local filter.
            return local
        }
        for s in remote where !liveIDs.contains(s.id) {
            searchCache[s.id] = s
        }
        var seen = Set<String>()
        var merged: [SessionInfo] = []
        for s in local + remote.map({ session(id: $0.id) ?? $0 }) where !seen.contains(s.id) {
            seen.insert(s.id)
            merged.append(s)
        }
        return merged
    }

    private func sortedByActivity(_ list: [SessionInfo]) -> [SessionInfo] {
        list.sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
    }

    func agentName(_ id: String?) -> String {
        if let id = id, let a = agents.first(where: { $0.id == id }), let n = a.name, !n.isEmpty {
            return n
        }
        return AgentNames.display(id)
    }

    /// Short lane name for the digest: the session's title or its folder.
    func laneName(sessionID: String?, fallback: String) -> String {
        if let sid = sessionID, let s = session(id: sid) {
            return s.displayTitle
        }
        return fallback
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        NotificationManager.shared.onOpenSession = { [weak self] id in
            self?.openSession(id)
        }
        NotificationManager.shared.requestAuthorization()
        intentObserver = NotificationCenter.default.addObserver(
            forName: IntentActions.decidedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadInbox()
            }
        }
        connect()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wentToBackground = true
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "lastLeftAt")
        case .active:
            // iOS suspends sockets in the background: reconnect for a fresh snapshot.
            if started && wentToBackground {
                wentToBackground = false
                let left = UserDefaults.standard.double(forKey: "lastLeftAt")
                if left > 0 {
                    lastLeftAt = Date(timeIntervalSince1970: left)
                }
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
        connection = .connecting
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

    /// Retry button: reconnect right away.
    func retry() {
        guard activeHost != nil else { return }
        if events == nil {
            connect()
        } else {
            connection = .connecting
            events?.restart()
        }
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
            withAnimation(.easeInOut(duration: 0.2)) {
                connection = .online
            }
        case .closed(let problem):
            withAnimation(.easeInOut(duration: 0.2)) {
                connection = .offline(problem)
            }
        }
    }

    // MARK: - Events

    private func handleEvent(_ data: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(EventEnvelope.self, from: data) else { return }
        switch envelope.type {
        case "snapshot":
            guard let snap = try? decoder.decode(DataEnvelope<Snapshot>.self, from: data).data else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                sessions = snap.sessions ?? []
                inbox = snap.inbox ?? []
                pruneLocallyAnswered()
                hasSnapshot = true
                seedTimeline(snap)
            }
            if let name = snap.host?.hostName, !name.isEmpty {
                hostDisplayName = name
                rememberHostName(name)
            }
        case "session.updated":
            guard let info = try? decoder.decode(DataEnvelope<SessionInfo>.self, from: data).data else { return }
            let previous = session(id: info.id)
            noteActivity(info.id)
            withAnimation(.easeInOut(duration: 0.25)) {
                upsertSession(info)
                sessionChanged(from: previous, to: info)
            }
        case "session.removed":
            guard let gone = try? decoder.decode(DataEnvelope<IDOnly>.self, from: data).data else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                sessions.removeAll { $0.id == gone.id }
            }
            activity[gone.id] = nil
        case "inbox.updated":
            guard let item = try? decoder.decode(DataEnvelope<InboxItem>.self, from: data).data else { return }
            let previous = inbox.first { $0.id == item.id }
            withAnimation(.easeInOut(duration: 0.3)) {
                upsertInbox(item)
                inboxChanged(from: previous, to: item)
            }
        case "inbox.reset":
            Task { await self.reloadInbox() }
        case "notify":
            guard let notice = try? decoder.decode(DataEnvelope<HostNotice>.self, from: data).data else { return }
            NotificationManager.shared.post(notice, hostName: hostLabel)
            withAnimation(.easeInOut(duration: 0.25)) {
                addNotice(notice)
            }
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

    // MARK: - Activity pulse

    private func noteActivity(_ id: String) {
        let now = Date()
        var list = activity[id] ?? []
        list.append(now)
        list = list.filter { now.timeIntervalSince($0) < 120 }
        if list.count > 40 {
            list.removeFirst(list.count - 40)
        }
        activity[id] = list
    }

    // MARK: - Timeline ("Since you left")

    private func insertEvent(_ event: TimelineEvent) {
        guard !timeline.contains(where: { $0.id == event.id }) else { return }
        let index = timeline.firstIndex { $0.date < event.date } ?? timeline.count
        timeline.insert(event, at: index)
        if timeline.count > AppStore.timelineCap {
            timeline.removeLast(timeline.count - AppStore.timelineCap)
        }
    }

    private func recentEvent(session: String?, kinds: [TimelineEvent.Kind], within seconds: TimeInterval,
                             of date: Date, prefix: String) -> Int? {
        guard let session = session, !session.isEmpty else { return nil }
        return timeline.firstIndex { e in
            e.sessionId == session && kinds.contains(e.kind) && e.id.hasPrefix(prefix) &&
                abs(e.date.timeIntervalSince(date)) < seconds
        }
    }

    private func statusEvent(for s: SessionInfo, date: Date) -> TimelineEvent? {
        let prompt = (s.lastPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let who = s.isAgent ? agentName(s.agent) : "Terminal"
        let kind: TimelineEvent.Kind
        let text: String
        switch s.status {
        case .working:
            kind = .working
            text = prompt.isEmpty ? "\(who) started working" : "\(who) is working on: \(prompt)"
        case .needsYou:
            kind = .needsYou
            text = "\(who) is waiting on you"
        case .done:
            kind = .done
            text = prompt.isEmpty ? "\(who) finished a turn" : "Finished: \(prompt)"
        case .exited:
            kind = .exited
            text = s.nowLine
        case .stalled:
            kind = .notice
            text = "\(who) has been quiet for a while"
        case .idle:
            return nil
        }
        let stamp = s.statusChangedAt ?? String(Int(date.timeIntervalSince1970))
        return TimelineEvent(id: "s:\(s.id):\(stamp):\(kind)", date: date, kind: kind, sessionId: s.id,
                             lane: s.displayTitle, text: text, detail: nil)
    }

    private func seedTimeline(_ snap: Snapshot) {
        let pendingSessions = Set((snap.inbox ?? []).filter { $0.isPendingApproval }.compactMap { $0.sessionId })
        for s in snap.sessions ?? [] {
            guard let date = AigoDate.parse(s.statusChangedAt) ?? AigoDate.parse(s.lastActivityAt) else { continue }
            if s.status == .needsYou && pendingSessions.contains(s.id) { continue }
            if let e = statusEvent(for: s, date: date) {
                insertEvent(e)
            }
        }
        for item in snap.inbox ?? [] {
            if let e = inboxEvent(item) {
                insertEvent(e)
            }
        }
        for n in snap.notifications ?? [] {
            addNotice(n, seeding: true)
        }
    }

    private func sessionChanged(from old: SessionInfo?, to new: SessionInfo) {
        let oldStatus = old?.status
        let newStatus = new.status
        guard oldStatus != newStatus else { return }
        let date = Date()
        if newStatus == .needsYou && !pendingItems(for: new.id).isEmpty { return }
        if newStatus == .done,
           recentEvent(session: new.id, kinds: [.done], within: 30, of: date, prefix: "n:") != nil {
            return
        }
        if let e = statusEvent(for: new, date: date) {
            insertEvent(e)
        }
        if newStatus == .done && UIApplication.shared.applicationState == .active {
            Haptics.success()
        }
    }

    private func inboxEvent(_ item: InboxItem) -> TimelineEvent? {
        let lane = laneName(sessionID: item.sessionId, fallback: item.contextLine)
        let title = (item.title ?? "").isEmpty ? "An agent asked for approval" : item.title!
        if item.isPendingApproval {
            let date = AigoDate.parse(item.createdAt) ?? Date()
            return TimelineEvent(id: "i:\(item.id):pending", date: date, kind: .needsYou, sessionId: item.sessionId,
                                 lane: lane, text: title, detail: item.message)
        }
        guard let decision = item.decision, !decision.isEmpty, !(item.actionId ?? "").isEmpty else { return nil }
        let date = AigoDate.parse(item.updatedAt) ?? AigoDate.parse(item.createdAt) ?? Date()
        let approved = decision == "approve" || decision == "allow"
        let by = (item.decidedBy ?? "").isEmpty ? "" : " (\(item.decidedBy!))"
        return TimelineEvent(id: "i:\(item.id):\(decision)", date: date, kind: approved ? .approved : .denied,
                             sessionId: item.sessionId, lane: lane,
                             text: (approved ? "Approved: " : "Denied: ") + title + by, detail: nil)
    }

    private func inboxChanged(from old: InboxItem?, to new: InboxItem) {
        if new.isPendingApproval {
            if let e = inboxEvent(new) {
                // The specific request replaces a generic "waiting on you".
                if let i = recentEvent(session: new.sessionId, kinds: [.needsYou], within: 60, of: e.date, prefix: "s:") {
                    timeline.remove(at: i)
                }
                insertEvent(e)
            }
            return
        }
        guard old?.isPendingApproval == true, !answeredHere.contains(new.id) else { return }
        if var e = inboxEvent(new) {
            e.date = Date()
            insertEvent(e)
        }
    }

    private func addNotice(_ n: HostNotice, seeding: Bool = false) {
        let category = n.category ?? ""
        // Approvals are covered by inbox events.
        if category == "approval_required" { return }
        let date = AigoDate.parse(n.at) ?? Date()
        let id = "n:" + ((n.id ?? "").isEmpty ? "\(category):\(date.timeIntervalSince1970)" : n.id!)
        let body = (n.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if category == "task_complete",
           let i = recentEvent(session: n.sessionId, kinds: [.done], within: 30, of: date, prefix: "s:") {
            // Attach the agent's last message to the status change.
            if !body.isEmpty {
                timeline[i].detail = body
            }
            return
        }
        let kind: TimelineEvent.Kind
        switch category {
        case "task_complete": kind = .done
        case "error": kind = .problem
        default: kind = .notice
        }
        let lane = laneName(sessionID: n.sessionId, fallback: AgentNames.display(n.agent))
        var text = (n.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = kind == .done ? "Finished a turn" : "Update from \(lane)"
        }
        insertEvent(TimelineEvent(id: id, date: date, kind: kind, sessionId: n.sessionId, lane: lane,
                                  text: text, detail: body.isEmpty ? nil : body))
    }

    // MARK: - Live Activity

    func refreshLiveActivity() {
        guard activeHost != nil else {
            live.end()
            return
        }
        let pending = pendingItems
        let working = sortedSessions.filter { $0.status == .working || $0.status == .stalled }
        var headline = ""
        var detail = ""
        var actionId = ""
        var context = ""
        if let top = pending.first {
            let s = top.sessionId.flatMap { session(id: $0) }
            headline = s?.displayTitle ?? top.title ?? "An agent needs you"
            context = top.contextLine
            if let message = top.message, !message.isEmpty {
                detail = message
            } else {
                detail = s != nil ? (top.title ?? "") : ""
            }
            let kind = top.kind ?? ""
            if (kind.isEmpty || kind == "permission" || kind == "plan") && (top.options ?? []).isEmpty &&
                !top.looksDestructive {
                actionId = top.actionId ?? ""
            }
        } else if let blocked = sessions.first(where: { $0.status == .needsYou }) {
            headline = blocked.displayTitle
            context = blocked.subtitle
            detail = "Waiting for your answer"
        } else if let w = working.first {
            headline = w.displayTitle
            context = w.subtitle
            detail = w.nowLine
        }
        live.update(hostName: hostLabel, working: working.count, needsYou: needsYouCount,
                    headline: headline, detail: detail, actionId: actionId, context: context)
    }

    // MARK: - Loading

    func refresh() async {
        guard let c = client else {
            retry()
            return
        }
        do {
            let s = try await c.sessions()
            let i = try await c.inbox()
            withAnimation(.easeInOut(duration: 0.25)) {
                sessions = s
                inbox = i
                pruneLocallyAnswered()
                hasSnapshot = true
            }
            refreshLiveActivity()
        } catch {
            connection = .offline(c.problem(for: error))
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

    func openNewWork(agent: String? = nil) {
        newWorkAgent = agent
        showNewWork = true
    }

    func openPairSheet() {
        pairDraft = nil
        showPairSheet = true
    }

    /// Pair again with the active PC (prefills its address and name).
    func repairActiveHost() {
        if let host = activeHost {
            pairDraft = PairDraft(addr: host.addr, fingerprint: "", code: "", hostName: host.hostName)
        } else {
            pairDraft = nil
        }
        showPairSheet = true
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
        showPairSheet = false
        Haptics.success()
        activate(creds.id)
    }

    func activate(_ id: String) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        if id == activeHostID && client != nil {
            if connectionProblem != nil { retry() }
            return
        }
        activeHostID = id
        UserDefaults.standard.set(id, forKey: "activeHostID")
        resetHostState()
        connect()
    }

    func forget(_ id: String) {
        hosts.removeAll { $0.id == id }
        HostVault.save(hosts)
        if activeHostID == id {
            activeHostID = hosts.first?.id
            UserDefaults.standard.set(activeHostID, forKey: "activeHostID")
            resetHostState()
            connect()
        }
    }

    private func resetHostState() {
        sessions = []
        inbox = []
        timeline = []
        activity = [:]
        locallyAnswered = []
        answeredHere = []
        locallySeen = []
        searchCache = [:]
        hasSnapshot = false
        hostDisplayName = ""
        path = []
        live.end()
    }

    // MARK: - Actions (each returns an error message, or nil on success)

    func decide(_ item: InboxItem, approve: Bool, choice: String? = nil) async -> String? {
        guard let c = client else { return "Not connected to your PC." }
        guard let action = item.actionId, !action.isEmpty else { return "This item can't be answered from here." }
        do {
            try await c.decide(actionId: action, approve: approve, choice: choice)
            answeredHere.insert(item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                if let i = inbox.firstIndex(where: { $0.id == item.id }) {
                    inbox[i].pending = false
                    inbox[i].decision = approve ? "approve" : "deny"
                }
                let title = (item.title ?? "").isEmpty ? "the request" : item.title!
                let text: String
                if let choice = choice, approve {
                    text = "You answered \"\(choice)\": \(title)"
                } else {
                    text = (approve ? "You approved: " : "You denied: ") + title
                }
                insertEvent(TimelineEvent(id: "a:\(item.id)", date: Date(), kind: approve ? .approved : .denied,
                                          sessionId: item.sessionId,
                                          lane: laneName(sessionID: item.sessionId, fallback: item.contextLine),
                                          text: text, detail: nil))
            }
            refreshLiveActivity()
            return nil
        } catch {
            return c.problem(for: error).message
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
        answeredHere.insert(item.id)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            _ = locallyAnswered.insert(item.id)
            insertEvent(TimelineEvent(id: "a:\(item.id)", date: Date(), kind: .answered, sessionId: sid,
                                      lane: laneName(sessionID: sid, fallback: item.contextLine),
                                      text: "You answered \"\(label)\"", detail: item.title))
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

    func sendInput(_ sessionID: String, _ data: String) async -> String? {
        await perform { try await $0.input(sessionID, data: data) }
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
            withAnimation(.easeInOut(duration: 0.25)) {
                upsertSession(info)
            }
            return nil
        } catch {
            return c.problem(for: error).message
        }
    }

    func remove(_ sessionID: String) async -> String? {
        let err = await perform { try await $0.remove(sessionID) }
        if err == nil {
            withAnimation(.easeInOut(duration: 0.25)) {
                sessions.removeAll { $0.id == sessionID }
            }
            refreshLiveActivity()
        }
        return err
    }

    func createSession(_ body: [String: Any]) async throws -> SessionInfo {
        guard let c = client else {
            throw APIError(status: 0, message: "Not connected to your PC.")
        }
        let info = try await c.createSession(body)
        withAnimation(.easeInOut(duration: 0.25)) {
            upsertSession(info)
        }
        refreshLiveActivity()
        return info
    }

    private func perform(_ op: (APIClient) async throws -> Void) async -> String? {
        guard let c = client else { return "Not connected to your PC." }
        do {
            try await op(c)
            return nil
        } catch {
            return c.problem(for: error).message
        }
    }
}
