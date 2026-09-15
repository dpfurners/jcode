import Foundation

/// One-shot, pre-subscribe requests against a server: open a socket, send a
/// single request, wait for its reply, close. This is the board tier: it
/// polls `list_sessions` on every saved server without creating a session
/// (`subscribe` is never sent), and it also carries `close_session` and the
/// new-session sheet's `search_files`.
///
/// Deliberately not an actor with state: every call is independent so a slow
/// server cannot wedge the poll of another.
public struct ServerProbe: Sendable {
    public enum ProbeError: Error, Equatable, Sendable {
        case timeout
        case closed
        case server(String)
    }

    public var gateway: Gateway
    public var authToken: String
    public var timeoutSeconds: Double
    private let makeTransport: @Sendable () -> any WebSocketTransport

    public init(
        gateway: Gateway,
        authToken: String,
        timeoutSeconds: Double = 4,
        makeTransport: @escaping @Sendable () -> any WebSocketTransport = {
            URLSessionWebSocketTransport()
        }
    ) {
        self.gateway = gateway
        self.authToken = authToken
        self.timeoutSeconds = timeoutSeconds
        self.makeTransport = makeTransport
    }

    public init(credential: ServerCredential, timeoutSeconds: Double = 4) {
        self.init(
            gateway: credential.gateway, authToken: credential.token,
            timeoutSeconds: timeoutSeconds)
    }

    public func listSessions(limit: Int = 100, includeWorkers: Bool = false) async throws
        -> SessionsPayload
    {
        try await roundTrip({ .listSessions(id: $0, limit: limit, includeWorkers: includeWorkers) }) {
            if case let .sessions(payload) = $0 { return payload }
            return nil
        }
    }

    /// Returns whether the server deleted the session file.
    @discardableResult
    public func closeSession(_ sessionID: String, delete: Bool) async throws -> Bool {
        try await roundTrip({ .closeSession(id: $0, sessionID: sessionID, delete: delete) }) {
            if case let .sessionClosed(_, _, deleted) = $0 { return deleted }
            return nil
        }
    }

    public func searchFiles(
        query: String, limit: Int = 30, dirsOnly: Bool = false, workingDir: String? = nil
    ) async throws -> [FileMatch] {
        try await roundTrip({
            .searchFiles(
                id: $0, query: query, limit: limit, dirsOnly: dirsOnly, workingDir: workingDir)
        }) {
            if case let .fileMatches(_, _, matches) = $0 { return matches }
            return nil
        }
    }

    /// Sends one request (id 1) and returns the first event `match` accepts.
    /// An `error` event with the same id fails the call; unrelated events
    /// (pong, keepalives) are skipped. The deadline closes the socket rather
    /// than cancelling the reader: a blocked receive is not cancellation-aware
    /// on every transport, but every transport unblocks on close.
    private func roundTrip<T: Sendable>(
        _ build: @escaping @Sendable (UInt64) -> Request,
        _ match: @escaping @Sendable (ServerEvent) -> T?
    ) async throws -> T {
        let transport = makeTransport()
        let timeout = timeoutSeconds
        let timedOut = TimeoutFlag()
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            timedOut.set()
            await transport.close()
        }
        defer { deadline.cancel() }
        do {
            try await transport.connect(url: gateway.webSocketURL, authToken: authToken)
            try await transport.send(text: build(1).encodedLine())
            while true {
                guard let text = try await transport.receiveText() else {
                    throw ProbeError.closed
                }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let event = try? ServerEvent.decode(line: String(line)) else {
                        continue
                    }
                    if let value = match(event) {
                        await transport.close()
                        return value
                    }
                    if case let .error(id, message, _) = event, id == 1 {
                        await transport.close()
                        throw ProbeError.server(message)
                    }
                }
            }
        } catch {
            await transport.close()
            if timedOut.isSet { throw ProbeError.timeout }
            throw error
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
