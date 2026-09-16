import Foundation

/// Abstraction over a WebSocket so `Connection` is testable with a fake.
public protocol WebSocketTransport: Sendable {
    /// Opens the socket. Throws if the connection or auth fails.
    func connect(url: URL, authToken: String) async throws
    /// Sends one text frame.
    func send(text: String) async throws
    /// Receives the next text frame. Returns nil when the socket closes.
    func receiveText() async throws -> String?
    /// Closes the socket.
    func close() async
}

/// URLSession-backed transport used in production.
///
/// Auth is sent via `Authorization: Bearer <token>` on the upgrade request,
/// matching the gateway's preferred auth source.
public actor URLSessionWebSocketTransport: WebSocketTransport {
    private var task: URLSessionWebSocketTask?

    public init() {}

    public func connect(url: URL, authToken: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        self.task = task
        // Nothing is sent here on purpose, and the handshake is not probed.
        //
        // Two behaviours of the real gateway rule out the obvious probes,
        // both verified at frame level against a live server:
        //  - `sendPing` never completes. The gateway sends its own WebSocket
        //    pings but answers a client ping with opcode 0x9 (another ping)
        //    rather than 0xA (pong), so the callback never fires. With the
        //    probe here, every board poll timed out against a real daemon
        //    while the mock gateway (which pongs) passed.
        //  - A protocol-level `ping` *request* sent before `subscribe` makes
        //    the daemon close the connection immediately.
        //
        // The first real send/receive is therefore the first thing on the
        // wire, and a rejected upgrade (401) surfaces from that instead.
    }

    public func send(text: String) async throws {
        guard let task else { throw TransportError.notConnected }
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.mapping(error, on: task)
        }
    }

    public func receiveText() async throws -> String? {
        guard let task else { throw TransportError.notConnected }
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // Treat close as end-of-stream rather than error when the
                // task reports a normal closure.
                if task.closeCode != .invalid {
                    return nil
                }
                throw Self.mapping(error, on: task)
            }
            switch message {
            case .string(let text):
                return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    return text
                }
            @unknown default:
                continue
            }
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// Classifies a transport error, keeping the "no longer paired" signal.
    ///
    /// The upgrade's 401 used to surface from a handshake probe; that probe
    /// had to go (see `connect`), so the status is read here instead: it is
    /// still on the task's response, and a rejected upgrade fails the first
    /// send or receive rather than silently retrying forever.
    private static func mapping(
        _ error: Error, on task: URLSessionWebSocketTask
    ) -> Error {
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            return TransportError.unauthorized
        }
        return error
    }
}

public enum TransportError: Error, Equatable {
    case notConnected
    /// The server rejected the WebSocket upgrade as unauthorized (401):
    /// the pairing token is unknown or was revoked. Reconnecting with the
    /// same token cannot succeed; the device must re-pair.
    case unauthorized
}
