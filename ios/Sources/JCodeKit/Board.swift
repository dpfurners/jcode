import Foundation

/// What the board knows about one saved server: the latest `sessions`
/// reply, or why it could not get one.
public struct ServerBoard: Equatable, Sendable, Identifiable {
    public var id: String { serverID }
    /// `ServerCredential.id` ("host:port").
    public var serverID: String
    /// Display name: the server's own `server_name` once heard, else the
    /// name recorded at pairing.
    public var name: String
    public var icon: String?
    public var version: String?
    public var sessions: [SessionSummary]
    public var recentProjects: [RecentProject]
    /// Nil until the first poll completes.
    public var reachable: Bool?
    /// Last successful poll.
    public var lastSeen: Date?
    public var lastError: String?

    public init(
        serverID: String, name: String, icon: String? = nil, version: String? = nil,
        sessions: [SessionSummary] = [], recentProjects: [RecentProject] = [],
        reachable: Bool? = nil, lastSeen: Date? = nil, lastError: String? = nil
    ) {
        self.serverID = serverID
        self.name = name
        self.icon = icon
        self.version = version
        self.sessions = sessions
        self.recentProjects = recentProjects
        self.reachable = reachable
        self.lastSeen = lastSeen
        self.lastError = lastError
    }

    /// Folds a successful poll in. Sessions and projects are replaced, the
    /// server's self-reported name wins over the pairing-time name.
    public func applying(_ payload: SessionsPayload, at now: Date) -> ServerBoard {
        var next = self
        next.name = payload.serverName ?? name
        next.icon = payload.serverIcon ?? icon
        next.version = payload.serverVersion ?? version
        next.sessions = payload.sessions
        next.recentProjects = payload.recentProjects
        next.reachable = true
        next.lastSeen = now
        next.lastError = nil
        return next
    }

    /// Folds a failed poll in. The previous sessions stay so the rows do not
    /// vanish on a blip; the UI greys the group instead.
    public func failing(_ reason: String) -> ServerBoard {
        var next = self
        next.reachable = false
        next.lastError = reason
        return next
    }
}

/// One board row: a session plus the server it lives on.
public struct BoardRow: Equatable, Sendable, Identifiable {
    public var id: String { "\(serverID)/\(session.id)" }
    public var serverID: String
    public var serverName: String
    public var serverIcon: String?
    public var session: SessionSummary

    public init(serverID: String, serverName: String, serverIcon: String? = nil, session: SessionSummary) {
        self.serverID = serverID
        self.serverName = serverName
        self.serverIcon = serverIcon
        self.session = session
    }
}

public enum Board {
    /// Flattens reachable servers into one list ranked needs_you > failed >
    /// running > idle, then newest `updated_at` first (Jed's
    /// `SessionActivity` order). Unreachable servers are excluded; the UI
    /// shows them as grey group headers instead.
    public static func rows(_ boards: [ServerBoard]) -> [BoardRow] {
        boards
            .filter { $0.reachable == true }
            .flatMap { board in
                board.sessions.map {
                    BoardRow(
                        serverID: board.serverID, serverName: board.name,
                        serverIcon: board.icon, session: $0)
                }
            }
            .sorted { lhs, rhs in
                if lhs.session.phase != rhs.session.phase {
                    return lhs.session.phase > rhs.session.phase
                }
                let l = lhs.session.updatedAtDate ?? .distantPast
                let r = rhs.session.updatedAtDate ?? .distantPast
                if l != r { return l > r }
                return lhs.id < rhs.id
            }
    }

    /// Servers whose last poll failed (or never completed), for the grey
    /// "unreachable" group headers.
    public static func unreachable(_ boards: [ServerBoard]) -> [ServerBoard] {
        boards.filter { $0.reachable != true }
    }
}

/// `jcode://` links the app handles beyond pairing (docs/PHONE-WIRE.md).
public enum DeepLink: Equatable, Sendable {
    case board
    case session(host: String, id: String)

    public static func parse(_ string: String) -> DeepLink? {
        guard let components = URLComponents(string: string),
            components.scheme?.lowercased() == "jcode"
        else { return nil }
        // `jcode://board` parses with host "board"; `jcode://session?...` with
        // host "session".
        switch components.host?.lowercased() {
        case "board":
            return .board
        case "session":
            let items = components.queryItems ?? []
            guard let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
                let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty
            else { return nil }
            return .session(host: host, id: id)
        default:
            return nil
        }
    }

    /// Matches a link `host` to a saved server: the server's literal host,
    /// its host's first DNS label, or its pairing-time server name, all
    /// case-insensitively. `hostname -s` on the Mac is what the push hook
    /// puts in the link, so the first label is the common case.
    public static func matchServer(host: String, in servers: [ServerCredential]) -> ServerCredential? {
        let wanted = host.lowercased()
        return servers.first { server in
            let full = server.host.lowercased()
            let label = full.split(separator: ".").first.map(String.init) ?? full
            return full == wanted || label == wanted || server.serverName.lowercased() == wanted
        }
    }
}
