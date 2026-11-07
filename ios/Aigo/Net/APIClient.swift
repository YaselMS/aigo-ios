import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    /// The pairing is no longer valid (device removed, certificate changed).
    var needsRepair: Bool = false

    var errorDescription: String? { message }

    static func from(status: Int, data: Data) -> APIError {
        if status == 401 {
            return APIError(status: status, message: ConnectionProblem.removed.message, needsRepair: true)
        }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data), let e = body.error, !e.isEmpty {
            return APIError(status: status, message: e)
        }
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return APIError(status: status, message: text.isEmpty ? "The PC answered with HTTP \(status)." : text)
    }

    /// Plain-language description of any error (without host context).
    static func describe(_ error: Error) -> String {
        if let e = error as? APIError {
            return e.message
        }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled:
                return "The connection was cancelled."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "Secure connection failed. Check the address and fingerprint."
            case .timedOut:
                return "Timed out reaching the PC."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Can't reach the PC at this address. Same Wi-Fi or Tailscale? Is remote access on?"
            case .notConnectedToInternet, .networkConnectionLost:
                return "No network connection."
            default:
                return u.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Why the phone can't talk to its PC, in plain words.
struct ConnectionProblem: Equatable {
    var message: String
    /// Retrying will not help: the user has to pair again.
    var needsRepair: Bool = false

    static let removed = ConnectionProblem(
        message: "This iPhone was removed from the PC — pair again.", needsRepair: true)
    static let certificateChanged = ConnectionProblem(
        message: "This PC's certificate changed — pair again.", needsRepair: true)
}

enum HostAddress {
    /// Host part of "host:port" / "[v6]:port".
    static func host(_ addr: String) -> String {
        if addr.hasPrefix("["), let close = addr.firstIndex(of: "]") {
            return String(addr[addr.index(after: addr.startIndex)..<close])
        }
        if addr.filter({ $0 == ":" }).count == 1, let colon = addr.lastIndex(of: ":") {
            return String(addr[..<colon])
        }
        return addr
    }

    /// Private (RFC 1918), link-local or mDNS address: reached over Wi-Fi,
    /// which needs the Local Network permission on iOS.
    static func isLAN(_ addr: String) -> Bool {
        let h = host(addr).lowercased()
        if h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        if h.hasPrefix("fe80:") || h.hasPrefix("fd") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch parts[0] {
        case 10: return true
        case 192: return parts[1] == 168
        case 172: return (16...31).contains(parts[1])
        case 169: return parts[1] == 254
        default: return false
        }
    }
}

/// REST + WebSocket access to one paired host over pinned TLS.
/// All stored properties are immutable, so it is safe to share.
final class APIClient: @unchecked Sendable {
    let addr: String
    let fingerprint: String
    let token: String
    let hostName: String
    let session: URLSession
    private let delegate: PinnedSessionDelegate

    init(addr: String, fingerprint: String, token: String, hostName: String = "") {
        self.addr = addr
        self.hostName = hostName
        self.fingerprint = CertificatePin.normalize(fingerprint)
        self.token = token
        let delegate = PinnedSessionDelegate(fingerprint: fingerprint)
        self.delegate = delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    convenience init(credentials: HostCredentials) {
        self.init(addr: credentials.addr, fingerprint: credentials.fingerprint, token: credentials.token,
                  hostName: credentials.hostName)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func url(_ path: String, websocket: Bool = false) throws -> URL {
        let scheme = websocket ? "wss" : "https"
        guard let u = URL(string: "\(scheme)://\(addr)\(path)") else {
            throw APIError(status: 0, message: "Invalid PC address: \(addr)")
        }
        return u
    }

    // MARK: - Core

    func data(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        let target = try url(path)
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.timeoutInterval = 45
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw wrap(error)
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status >= 300 {
            throw APIError.from(status: status, data: result.0)
        }
        return result.0
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let d = try await data("GET", path)
        return try decode(type, from: d)
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]?, as type: T.Type) async throws -> T {
        let d = try await data(method, path, body: body)
        return try decode(type, from: d)
    }

    /// For endpoints answering {"ok":true}.
    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        _ = try await data(method, path, body: body)
    }

    private func decode<T: Decodable>(_ type: T.Type, from d: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: d)
        } catch {
            throw APIError(status: 0, message: "Unexpected answer from the PC (\(error.localizedDescription)).")
        }
    }

    private func wrap(_ error: Error) -> Error {
        let p = problem(for: error)
        return APIError(status: 0, message: p.message, needsRepair: p.needsRepair)
    }

    var hostLabel: String {
        let n = hostName.trimmingCharacters(in: .whitespaces)
        return (n.isEmpty || n == "PC") ? addr : n
    }

    /// Maps a networking failure to a plain cause the user can act on.
    func problem(for error: Error, response: URLResponse? = nil) -> ConnectionProblem {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            return .removed
        }
        if let e = error as? APIError {
            return ConnectionProblem(message: e.message, needsRepair: e.needsRepair)
        }
        guard let u = error as? URLError else {
            return ConnectionProblem(message: error.localizedDescription)
        }
        if delegate.lastMismatch != nil {
            switch u.code {
            case .cancelled, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
                return .certificateChanged
            default:
                break
            }
        }
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut,
             .cannotFindHost, .dnsLookupFailed:
            if HostAddress.isLAN(addr) {
                return ConnectionProblem(message: "Can't reach \(hostLabel). Check: same Wi-Fi as the PC; iPhone Settings → Aigo → Local Network is on; Windows firewall allows Aigo on this network (Private).")
            }
            return ConnectionProblem(message: "Can't reach \(hostLabel) at \(addr). Check: the PC is on and Aigo is running; Tailscale (or your VPN) is connected on both devices; Windows firewall allows Aigo.")
        case .cancelled:
            return ConnectionProblem(message: "The connection to \(hostLabel) was cancelled.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return ConnectionProblem(message: "Secure connection to \(hostLabel) failed. Check the address, or pair again.")
        default:
            return ConnectionProblem(message: APIError.describe(error))
        }
    }

    // MARK: - WebSocket

    func webSocketTask(_ path: String) throws -> URLSessionWebSocketTask {
        let target = try url(path, websocket: true)
        var req = URLRequest(url: target)
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("aigo.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 64 << 20
        return task
    }

    // MARK: - Pairing

    static func pair(addr: String, fingerprint: String, code: String, deviceName: String) async throws -> HostCredentials {
        let client = APIClient(addr: addr, fingerprint: fingerprint, token: "")
        defer { client.invalidate() }
        let body: [String: Any] = ["code": code, "name": deviceName, "platform": "ios"]
        let res = try await client.send("POST", "/api/v1/pairing/complete", body: body, as: PairResponse.self)
        return HostCredentials(addr: addr,
                               fingerprint: CertificatePin.normalize(fingerprint),
                               token: res.token,
                               hostId: res.hostId ?? "",
                               hostName: res.hostName ?? "PC")
    }

    // MARK: - Endpoints

    func sessions() async throws -> [SessionInfo] {
        try await get("/api/v1/sessions", as: [SessionInfo].self)
    }

    /// Search (v0.3 host): titles, prompts and older or outside-Aigo chats.
    /// Older hosts ignore `q` and return every session.
    func searchSessions(_ query: String) async throws -> [SessionInfo] {
        try await get("/api/v1/sessions?q=\(APIClient.queryValue(query))", as: [SessionInfo].self)
    }

    /// "Looks good": moves a session from Review to Done (v0.3 host).
    func seen(_ id: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/seen")
    }

    /// Older hosts: marks the session viewed (done -> idle).
    func viewed(_ id: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/viewed")
    }

    func gitStatus(cwd: String) async throws -> GitStatus {
        try await get("/api/v1/git/status?cwd=\(APIClient.queryValue(cwd))", as: GitStatus.self)
    }

    func gitDiff(cwd: String, path: String) async throws -> String {
        let p = "/api/v1/git/diff?cwd=\(APIClient.queryValue(cwd))&path=\(APIClient.queryValue(path))"
        return try await get(p, as: GitDiff.self).diff ?? ""
    }

    static func queryValue(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func inbox() async throws -> [InboxItem] {
        try await get("/api/v1/inbox", as: [InboxItem].self)
    }

    func agents() async throws -> [AgentInfo] {
        try await get("/api/v1/agents", as: AgentsResponse.self).agents ?? []
    }

    func recentDirs() async throws -> [RecentDir] {
        try await get("/api/v1/recent-dirs", as: [RecentDir].self)
    }

    func createSession(_ body: [String: Any]) async throws -> SessionInfo {
        try await send("POST", "/api/v1/sessions", body: body, as: SessionInfo.self)
    }

    func screen(_ id: String) async throws -> ScreenState {
        try await get("/api/v1/sessions/\(id)/screen", as: ScreenState.self)
    }

    func prompt(_ id: String, text: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/prompt", body: ["text": text])
    }

    func keys(_ id: String, keys: [String]) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/keys", body: ["keys": keys])
    }

    func input(_ id: String, data: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/input", body: ["data": data])
    }

    func interrupt(_ id: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/interrupt")
    }

    func kill(_ id: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/kill")
    }

    func restart(_ id: String) async throws -> SessionInfo {
        try await send("POST", "/api/v1/sessions/\(id)/restart", body: nil, as: SessionInfo.self)
    }

    func remove(_ id: String) async throws {
        try await call("DELETE", "/api/v1/sessions/\(id)")
    }

    func chooseMenu(_ id: String, number: Int, label: String) async throws {
        try await call("POST", "/api/v1/sessions/\(id)/menu", body: ["number": number, "label": label])
    }

    func decide(actionId: String, approve: Bool, choice: String?) async throws {
        var body: [String: Any] = ["decision": approve ? "approve" : "deny"]
        if let choice = choice {
            body["choice"] = choice
        }
        try await call("POST", "/api/v1/approvals/\(actionId)", body: body)
    }
}
