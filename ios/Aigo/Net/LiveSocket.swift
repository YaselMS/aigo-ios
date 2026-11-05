import Foundation

/// One authenticated WebSocket with automatic reconnect (exponential backoff).
/// Used for /api/v1/events and /api/v1/sessions/{id}/transcript. The server
/// re-sends its full state (snapshot / backlog) on every new connection.
@MainActor
final class LiveSocket {
    enum State: Equatable {
        case connecting
        case open
        case closed(String)
    }

    var onMessage: ((Data) -> Void)?
    var onState: ((State) -> Void)?

    private let client: APIClient
    private let path: String
    private var task: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var generation = 0

    init(client: APIClient, path: String) {
        self.client = client
        self.path = path
    }

    func start() {
        guard runner == nil else { return }
        generation += 1
        let gen = generation
        runner = Task { [weak self] in
            await self?.run(gen)
        }
    }

    func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        pinger?.cancel()
        pinger = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Drops the current connection and connects again right away.
    func restart() {
        stop()
        start()
    }

    func send(_ object: [String: Any]) {
        guard let task = task,
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(text)) { _ in }
    }

    private func run(_ gen: Int) async {
        var attempt = 0
        while !Task.isCancelled && gen == generation {
            onState?(.connecting)
            let ws: URLSessionWebSocketTask
            do {
                ws = try client.webSocketTask(path)
            } catch {
                onState?(.closed(APIError.describe(error)))
                return
            }
            task = ws
            ws.resume()
            var reason = "Disconnected"
            var opened = false
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard gen == generation else { break }
                    if !opened {
                        opened = true
                        attempt = 0
                        onState?(.open)
                        startPinger(ws)
                    }
                    switch message {
                    case .string(let text):
                        onMessage?(Data(text.utf8))
                    case .data(let data):
                        onMessage?(data)
                    @unknown default:
                        break
                    }
                }
            } catch {
                reason = APIError.describe(error)
            }
            ws.cancel(with: .goingAway, reason: nil)
            guard gen == generation, !Task.isCancelled else { return }
            pinger?.cancel()
            pinger = nil
            task = nil
            onState?(.closed(reason))
            attempt += 1
            let delay = min(20.0, 0.75 * pow(2.0, Double(min(attempt, 5))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Client-side ping so a dead link is noticed even if the server's
    /// keepalive never arrives (e.g. after the phone changed networks).
    private func startPinger(_ ws: URLSessionWebSocketTask) {
        pinger?.cancel()
        pinger = Task { [weak ws] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                guard let socket = ws else { return }
                socket.sendPing { error in
                    if error != nil {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                }
            }
        }
    }
}
