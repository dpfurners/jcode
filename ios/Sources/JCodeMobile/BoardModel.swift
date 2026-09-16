import Foundation
import JCodeKit
import Observation

/// The board tier: every saved server polled for its sessions.
///
/// One short-lived connection per server per poll, `list_sessions` only
/// (never `subscribe`, so polling creates no sessions). Polls every 5 s while
/// the board is on screen and the scene is active; `stop()` in the
/// background. Servers are polled in parallel so one dead host does not
/// delay the others. All ranking lives in `JCodeKit.Board`.
@MainActor
@Observable
final class BoardModel {
    static let pollInterval: Duration = .seconds(5)

    private(set) var boards: [ServerBoard] = []
    /// Set when a stop/delete or new-session step fails; dismissable.
    var actionError: String?
    /// Deep-link banner for an unknown server (shown on the board).
    var banner: String?

    private var pollTask: Task<Void, Never>?
    private var servers: [ServerCredential] = []
    private let makeProbe: @Sendable (ServerCredential) -> ServerProbe

    init(makeProbe: @escaping @Sendable (ServerCredential) -> ServerProbe = { ServerProbe(credential: $0) }) {
        self.makeProbe = makeProbe
    }

    var rows: [BoardRow] { Board.rows(boards) }
    var unreachable: [ServerBoard] { Board.unreachable(boards) }
    var isPolling: Bool { pollTask != nil }

    func board(for serverID: String) -> ServerBoard? {
        boards.first { $0.serverID == serverID }
    }

    /// Reconciles the saved server list: keeps polled state for servers that
    /// remain, adds placeholders for new ones, drops removed ones.
    func setServers(_ servers: [ServerCredential]) {
        self.servers = servers
        boards = servers.map { server in
            if var existing = boards.first(where: { $0.serverID == server.id }) {
                // A rename must show at once, not on the next poll.
                existing.pinnedName = server.customName
                existing.name = server.displayName
                return existing
            }
            return ServerBoard(serverID: server.id, name: server.serverName,
                               pinnedName: server.customName)
        }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One immediate poll of every server (pull-to-refresh, after an action).
    func pollAll() async {
        let servers = self.servers
        let makeProbe = self.makeProbe
        await withTaskGroup(of: (String, Result<SessionsPayload, Error>).self) { group in
            for server in servers {
                group.addTask {
                    do {
                        return (server.id, .success(try await makeProbe(server).listSessions()))
                    } catch {
                        return (server.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                apply(id, result)
            }
        }
    }

    private func apply(_ serverID: String, _ result: Result<SessionsPayload, Error>) {
        guard let index = boards.firstIndex(where: { $0.serverID == serverID }) else { return }
        switch result {
        case .success(let payload):
            boards[index] = boards[index].applying(payload, at: Date())
        case .failure(let error):
            boards[index] = boards[index].failing(Self.describe(error))
        }
    }

    // MARK: - Actions

    /// Stops (or deletes) a session on its server, then re-polls that server
    /// so the row updates without waiting for the next tick.
    func closeSession(_ row: BoardRow, delete: Bool) async {
        guard let server = servers.first(where: { $0.id == row.serverID }) else { return }
        do {
            try await makeProbe(server).closeSession(row.session.id, delete: delete)
        } catch {
            actionError = "\(delete ? "Delete" : "Stop") failed: \(Self.describe(error))"
        }
        await pollOne(server)
    }

    func pollOne(_ server: ServerCredential) async {
        do {
            apply(server.id, .success(try await makeProbe(server).listSessions()))
        } catch {
            apply(server.id, .failure(error))
        }
    }

    /// Absolute-path completion for the new-session sheet.
    func searchDirectories(on server: ServerCredential, prefix: String) async -> [FileMatch] {
        (try? await makeProbe(server).searchFiles(query: prefix, limit: 30, dirsOnly: true)) ?? []
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ServerProbe.ProbeError.timeout: "timed out"
        case ServerProbe.ProbeError.closed: "connection closed"
        case ServerProbe.ProbeError.server(let message): message
        case TransportError.unauthorized: "not paired (re-pair)"
        default: "unreachable"
        }
    }
}
