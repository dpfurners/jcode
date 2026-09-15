import Foundation

/// Client request to a jcode server.
///
/// Wire format mirrors `crates/jcode-protocol/src/wire.rs` (`#[serde(tag = "type")]`,
/// snake_case tags). Only the requests the iOS app uses are modeled; the server
/// ignores fields it does not expect.
public enum Request: Equatable, Sendable {
    /// `working_dir` opens a fresh session in that directory when no target is
    /// given. `allow_session_takeover` stays false for the phone: it attaches
    /// alongside other clients instead of evicting them.
    case subscribe(
        id: UInt64, targetSessionID: String?, workingDir: String? = nil,
        allowSessionTakeover: Bool = false)
    case message(
        id: UInt64, content: String, images: [ImageAttachment] = [], activeSkill: String? = nil)
    case cancel(id: UInt64)
    case softInterrupt(id: UInt64, content: String, urgent: Bool, images: [ImageAttachment] = [])
    case cancelSoftInterrupts(id: UInt64)
    case ping(id: UInt64)
    case getHistory(id: UInt64)
    case resumeSession(id: UInt64, sessionID: String)
    case setModel(id: UInt64, model: String)
    case setReasoningEffort(id: UInt64, effort: String)
    case compact(id: UInt64)
    case renameSession(id: UInt64, title: String?)
    case clear(id: UInt64)
    /// Board poll; allowed before `subscribe` (see docs/PHONE-WIRE.md).
    case listSessions(id: UInt64, limit: Int = 100, includeWorkers: Bool = false)
    /// Stop (and optionally delete) any session on the server.
    case closeSession(id: UInt64, sessionID: String, delete: Bool)
    /// Server-side path search: fuzzy relative to `workingDir`, or absolute
    /// prefix completion when `query` starts with "/".
    case searchFiles(
        id: UInt64, query: String, limit: Int = 30, dirsOnly: Bool = false,
        workingDir: String? = nil)
    /// Answers a `stdin_request` from a running tool.
    case stdinResponse(id: UInt64, requestID: String, input: String)

    public var id: UInt64 {
        switch self {
        case let .subscribe(id, _, _, _), let .message(id, _, _, _), let .cancel(id),
            let .softInterrupt(id, _, _, _), let .cancelSoftInterrupts(id),
            let .ping(id), let .getHistory(id), let .resumeSession(id, _),
            let .setModel(id, _), let .setReasoningEffort(id, _), let .compact(id),
            let .renameSession(id, _), let .clear(id), let .listSessions(id, _, _),
            let .closeSession(id, _, _), let .searchFiles(id, _, _, _, _),
            let .stdinResponse(id, _, _):
            return id
        }
    }

    /// Encodes the request as a single JSON line (no trailing newline).
    public func encodedLine() throws -> String {
        var object: [String: Any] = ["id": id]
        switch self {
        case let .subscribe(_, targetSessionID, workingDir, allowTakeover):
            object["type"] = "subscribe"
            if let targetSessionID {
                object["target_session_id"] = targetSessionID
            }
            if let workingDir {
                object["working_dir"] = workingDir
            }
            if allowTakeover {
                object["allow_session_takeover"] = true
            }
        case let .message(_, content, images, activeSkill):
            object["type"] = "message"
            object["content"] = content
            if !images.isEmpty {
                object["images"] = images.map(\.wireValue)
            }
            if let activeSkill {
                object["active_skill"] = activeSkill
            }
        case .cancel:
            object["type"] = "cancel"
        case let .softInterrupt(_, content, urgent, images):
            object["type"] = "soft_interrupt"
            object["content"] = content
            object["urgent"] = urgent
            if !images.isEmpty {
                object["images"] = images.map(\.wireValue)
            }
        case .cancelSoftInterrupts:
            object["type"] = "cancel_soft_interrupts"
        case .ping:
            object["type"] = "ping"
        case .getHistory:
            object["type"] = "get_history"
        case let .resumeSession(_, sessionID):
            object["type"] = "resume_session"
            object["session_id"] = sessionID
        case let .setModel(_, model):
            object["type"] = "set_model"
            object["model"] = model
        case let .setReasoningEffort(_, effort):
            object["type"] = "set_reasoning_effort"
            object["effort"] = effort
        case .compact:
            object["type"] = "compact"
        case let .renameSession(_, title):
            object["type"] = "rename_session"
            if let title {
                object["title"] = title
            }
        case .clear:
            object["type"] = "clear"
        case let .listSessions(_, limit, includeWorkers):
            object["type"] = "list_sessions"
            object["limit"] = limit
            object["include_workers"] = includeWorkers
        case let .closeSession(_, sessionID, delete):
            object["type"] = "close_session"
            object["session_id"] = sessionID
            object["delete"] = delete
        case let .searchFiles(_, query, limit, dirsOnly, workingDir):
            object["type"] = "search_files"
            object["query"] = query
            object["limit"] = limit
            object["dirs_only"] = dirsOnly
            object["working_dir"] = workingDir ?? NSNull()
        case let .stdinResponse(_, requestID, input):
            object["type"] = "stdin_response"
            object["request_id"] = requestID
            object["input"] = input
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw WireError.encodingFailed
        }
        return line
    }
}

/// An inline image on `message` / `soft_interrupt`. The Rust wire encodes
/// `images: Vec<(String, String)>` as `[[mime, base64], ...]`.
public struct ImageAttachment: Equatable, Sendable, Hashable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }

    var wireValue: [String] { [mimeType, base64] }
}

/// A running tool is blocked on interactive input (`stdin_request`).
public struct PendingPrompt: Equatable, Sendable {
    public var requestID: String
    public var prompt: String
    public var isPassword: Bool
    public var toolCallID: String?

    public init(requestID: String, prompt: String, isPassword: Bool, toolCallID: String?) {
        self.requestID = requestID
        self.prompt = prompt
        self.isPassword = isPassword
        self.toolCallID = toolCallID
    }
}

/// One row of a `sessions` reply (the board tier). Timestamps stay as the
/// server's RFC 3339 strings so they round-trip byte-for-byte into the sync
/// dump; use `date(_:)` to compare them.
public struct SessionSummary: Equatable, Sendable, Identifiable {
    public enum Phase: String, Sendable, Comparable {
        case idle
        case running
        case failed
        case needsYou = "needs_you"

        /// Board ranking: needs_you > failed > running > idle.
        public var rank: Int {
            switch self {
            case .needsYou: 3
            case .failed: 2
            case .running: 1
            case .idle: 0
            }
        }

        public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Preview: Equatable, Sendable {
        public var kind: String
        public var text: String

        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public var id: String
    public var shortName: String
    public var title: String?
    public var workingDir: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var lastActiveAt: String?
    public var model: String?
    public var provider: String?
    public var phase: Phase
    public var reason: String?
    public var currentTool: String?
    public var turnStartedAt: String?
    public var queued: Int
    public var pendingPrompt: PendingPrompt?
    public var preview: Preview?
    public var clientCount: Int
    public var isLive: Bool
    public var parentID: String?
    public var swarmRole: String?

    public init(
        id: String, shortName: String = "", title: String? = nil, workingDir: String? = nil,
        createdAt: String? = nil, updatedAt: String? = nil, lastActiveAt: String? = nil,
        model: String? = nil, provider: String? = nil, phase: Phase = .idle,
        reason: String? = nil, currentTool: String? = nil, turnStartedAt: String? = nil,
        queued: Int = 0, pendingPrompt: PendingPrompt? = nil, preview: Preview? = nil,
        clientCount: Int = 0, isLive: Bool = false, parentID: String? = nil,
        swarmRole: String? = nil
    ) {
        self.id = id
        self.shortName = shortName
        self.title = title
        self.workingDir = workingDir
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActiveAt = lastActiveAt
        self.model = model
        self.provider = provider
        self.phase = phase
        self.reason = reason
        self.currentTool = currentTool
        self.turnStartedAt = turnStartedAt
        self.queued = queued
        self.pendingPrompt = pendingPrompt
        self.preview = preview
        self.clientCount = clientCount
        self.isLive = isLive
        self.parentID = parentID
        self.swarmRole = swarmRole
    }

    /// Row label: custom/auto title, else the short name, else the id.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if !shortName.isEmpty { return shortName }
        return id
    }

    public var updatedAtDate: Date? { Self.date(updatedAt) }
    public var turnStartedAtDate: Date? { Self.date(turnStartedAt) }

    /// Parses RFC 3339 with or without fractional seconds.
    public static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date(string, strategy: .iso8601.year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: true))
        {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }
}

/// A project directory the server has seen recently (`sessions.recent_projects`).
/// The server lists `[phone] pinned_projects` first, so order is meaningful.
public struct RecentProject: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var lastUsedAt: String?
    public var sessionCount: Int

    public init(path: String, lastUsedAt: String? = nil, sessionCount: Int = 0) {
        self.path = path
        self.lastUsedAt = lastUsedAt
        self.sessionCount = sessionCount
    }
}

/// Reply to `list_sessions`.
public struct SessionsPayload: Equatable, Sendable {
    public var id: UInt64
    public var serverName: String?
    public var serverIcon: String?
    public var serverVersion: String?
    public var sessions: [SessionSummary]
    public var recentProjects: [RecentProject]

    public init(
        id: UInt64, serverName: String? = nil, serverIcon: String? = nil,
        serverVersion: String? = nil, sessions: [SessionSummary] = [],
        recentProjects: [RecentProject] = []
    ) {
        self.id = id
        self.serverName = serverName
        self.serverIcon = serverIcon
        self.serverVersion = serverVersion
        self.sessions = sessions
        self.recentProjects = recentProjects
    }
}

/// One hit of `search_files` (`file_matches`).
public struct FileMatch: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var isDir: Bool

    public init(path: String, isDir: Bool) {
        self.path = path
        self.isDir = isDir
    }
}

/// A tool call as represented in history payloads.
public struct ToolCallRecord: Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: String
    public var output: String?
    public var error: String?

    public init(id: String, name: String, input: String, output: String?, error: String?) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.error = error
    }
}

/// A message in conversation history (response to `get_history`).
public struct HistoryMessage: Equatable, Sendable {
    public var role: String
    public var content: String
    public var toolCalls: [String]
    public var toolData: ToolCallRecord?

    public init(
        role: String, content: String, toolCalls: [String] = [], toolData: ToolCallRecord? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolData = toolData
    }
}

/// Server event from a jcode server. Unknown event types decode as `.unknown`
/// so newer servers never break older apps.
public enum ServerEvent: Equatable, Sendable {
    case ack(id: UInt64)
    case textDelta(text: String)
    case reasoningDelta(text: String)
    case reasoningDone(durationSecs: Double?)
    case textReplace(text: String)
    case toolStart(id: String, name: String)
    case toolInput(delta: String)
    case toolExec(id: String, name: String)
    case toolDone(id: String, name: String, output: String, error: String?)
    case tokenUsage(input: UInt64, output: UInt64)
    case statusDetail(detail: String)
    case connectionPhase(phase: String)
    case softInterruptInjected(content: String, displayRole: String?, point: String, toolsSkipped: Int?)
    case retryRollback(attempt: Int, max: Int)
    case messageEnd
    case interrupted
    case done(id: UInt64)
    case error(id: UInt64, message: String, retryAfterSecs: UInt64?)
    case pong(id: UInt64)
    case state(id: UInt64, sessionID: String, messageCount: Int, isProcessing: Bool)
    case sessionID(sessionID: String)
    case sessionRenamed(sessionID: String, displayTitle: String)
    case history(HistoryPayload)
    case modelChanged(id: UInt64, model: String, error: String?)
    case reasoningEffortChanged(id: UInt64, effort: String?, error: String?)
    case compactResult(id: UInt64, message: String, success: Bool)
    case availableModelsUpdated(models: [String], providerModel: String?)
    case compaction(trigger: String, tokensSaved: UInt64?)
    case notification(fromName: String?, message: String)
    case reloading(newSocket: String?)
    case sessionCloseRequested(reason: String)
    case stdinRequest(PendingPrompt)
    /// Another client answered the prompt; close the local prompt UI.
    case stdinResolved(requestID: String)
    case sessions(SessionsPayload)
    case sessionClosed(id: UInt64, sessionID: String, deleted: Bool)
    case fileMatches(id: UInt64, query: String, matches: [FileMatch])
    case unknown(type: String)

    public struct HistoryPayload: Equatable, Sendable {
        public var id: UInt64
        public var sessionID: String
        public var messages: [HistoryMessage]
        public var providerName: String?
        public var providerModel: String?
        public var availableModels: [String]
        public var totalTokens: TokenTotals?
        public var allSessions: [String]
        public var serverVersion: String?
        public var displayTitle: String?
        public var reasoningEffort: String?
        /// Installed skill names, for `/` completion.
        public var skills: [String]

        public struct TokenTotals: Equatable, Sendable {
            public var input: UInt64
            public var output: UInt64

            public init(input: UInt64, output: UInt64) {
                self.input = input
                self.output = output
            }
        }

        public init(
            id: UInt64,
            sessionID: String,
            messages: [HistoryMessage],
            providerName: String? = nil,
            providerModel: String? = nil,
            availableModels: [String] = [],
            totalTokens: TokenTotals? = nil,
            allSessions: [String] = [],
            serverVersion: String? = nil,
            displayTitle: String? = nil,
            reasoningEffort: String? = nil,
            skills: [String] = []
        ) {
            self.id = id
            self.sessionID = sessionID
            self.messages = messages
            self.providerName = providerName
            self.providerModel = providerModel
            self.availableModels = availableModels
            self.totalTokens = totalTokens
            self.allSessions = allSessions
            self.serverVersion = serverVersion
            self.displayTitle = displayTitle
            self.reasoningEffort = reasoningEffort
            self.skills = skills
        }
    }

    /// Decodes one newline-delimited JSON event line.
    public static func decode(line: String) throws -> ServerEvent {
        guard let data = line.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let object = parsed as? [String: Any]
        else {
            throw WireError.invalidJSON(line: line)
        }
        guard let type = object["type"] as? String else {
            throw WireError.missingType(line: line)
        }
        let json = JSONObject(object)
        switch type {
        case "ack":
            return .ack(id: json.uint64("id"))
        case "text_delta":
            return .textDelta(text: json.string("text"))
        case "reasoning_delta":
            return .reasoningDelta(text: json.string("text"))
        case "reasoning_done":
            return .reasoningDone(durationSecs: json.optionalDouble("duration_secs"))
        case "text_replace":
            return .textReplace(text: json.string("text"))
        case "tool_start":
            return .toolStart(id: json.string("id"), name: json.string("name"))
        case "tool_input":
            return .toolInput(delta: json.string("delta"))
        case "tool_exec":
            return .toolExec(id: json.string("id"), name: json.string("name"))
        case "tool_done":
            return .toolDone(
                id: json.string("id"),
                name: json.string("name"),
                output: json.string("output"),
                error: json.optionalString("error")
            )
        case "tokens":
            return .tokenUsage(input: json.uint64("input"), output: json.uint64("output"))
        case "status_detail":
            return .statusDetail(detail: json.string("detail"))
        case "connection_phase":
            return .connectionPhase(phase: json.string("phase"))
        case "soft_interrupt_injected":
            return .softInterruptInjected(
                content: json.string("content"),
                displayRole: json.optionalString("display_role"),
                point: json.string("point"),
                toolsSkipped: json.optionalInt("tools_skipped")
            )
        case "retry_rollback":
            return .retryRollback(attempt: json.int("attempt"), max: json.int("max"))
        case "message_end":
            return .messageEnd
        case "interrupted":
            return .interrupted
        case "done":
            return .done(id: json.uint64("id"))
        case "error":
            return .error(
                id: json.uint64("id"),
                message: json.string("message"),
                retryAfterSecs: json.optionalUInt64("retry_after_secs")
            )
        case "pong":
            return .pong(id: json.uint64("id"))
        case "state":
            return .state(
                id: json.uint64("id"),
                sessionID: json.string("session_id"),
                messageCount: json.int("message_count"),
                isProcessing: json.bool("is_processing")
            )
        case "session":
            return .sessionID(sessionID: json.string("session_id"))
        case "session_renamed":
            return .sessionRenamed(
                sessionID: json.string("session_id"),
                displayTitle: json.string("display_title")
            )
        case "history":
            return .history(decodeHistory(json))
        case "model_changed":
            return .modelChanged(
                id: json.uint64("id"),
                model: json.string("model"),
                error: json.optionalString("error")
            )
        case "reasoning_effort_changed":
            return .reasoningEffortChanged(
                id: json.uint64("id"),
                effort: json.optionalString("effort"),
                error: json.optionalString("error")
            )
        case "compact_result":
            return .compactResult(
                id: json.uint64("id"),
                message: json.string("message"),
                success: json.bool("success")
            )
        case "available_models_updated":
            return .availableModelsUpdated(
                models: json.stringArray("available_models"),
                providerModel: json.optionalString("provider_model")
            )
        case "compaction":
            return .compaction(
                trigger: json.string("trigger"),
                tokensSaved: json.optionalUInt64("tokens_saved")
            )
        case "notification":
            return .notification(
                fromName: json.optionalString("from_name"),
                message: json.string("message")
            )
        case "reloading":
            return .reloading(newSocket: json.optionalString("new_socket"))
        case "session_close_requested":
            return .sessionCloseRequested(reason: json.string("reason"))
        case "stdin_request":
            return .stdinRequest(decodePrompt(json))
        case "stdin_resolved":
            return .stdinResolved(requestID: json.string("request_id"))
        case "sessions":
            return .sessions(decodeSessions(json))
        case "session_closed":
            return .sessionClosed(
                id: json.uint64("id"),
                sessionID: json.string("session_id"),
                deleted: json.bool("deleted")
            )
        case "file_matches":
            return .fileMatches(
                id: json.uint64("id"),
                query: json.string("query"),
                matches: json.objectArray("matches").map {
                    FileMatch(path: $0.string("path"), isDir: $0.bool("is_dir"))
                }
            )
        default:
            return .unknown(type: type)
        }
    }

    private static func decodeHistory(_ json: JSONObject) -> HistoryPayload {
        let messages = json.objectArray("messages").map { msg -> HistoryMessage in
            var toolData: ToolCallRecord?
            if let td = msg.optionalObject("tool_data") {
                toolData = ToolCallRecord(
                    id: td.string("id"),
                    name: td.string("name"),
                    input: td.string("input"),
                    output: td.optionalString("output"),
                    error: td.optionalString("error")
                )
            }
            return HistoryMessage(
                role: msg.string("role"),
                content: msg.string("content"),
                toolCalls: msg.stringArray("tool_calls"),
                toolData: toolData
            )
        }
        var totals: HistoryPayload.TokenTotals?
        if let pair = json.raw["total_tokens"] as? [Any], pair.count == 2,
            let input = JSONObject.coerceUInt64(pair[0]),
            let output = JSONObject.coerceUInt64(pair[1])
        {
            totals = HistoryPayload.TokenTotals(input: input, output: output)
        }
        return HistoryPayload(
            id: json.uint64("id"),
            sessionID: json.string("session_id"),
            messages: messages,
            providerName: json.optionalString("provider_name"),
            providerModel: json.optionalString("provider_model"),
            availableModels: json.stringArray("available_models"),
            totalTokens: totals,
            allSessions: json.stringArray("all_sessions"),
            serverVersion: json.optionalString("server_version"),
            displayTitle: json.optionalString("display_title"),
            reasoningEffort: json.optionalString("reasoning_effort"),
            skills: json.stringArray("skills")
        )
    }

    private static func decodePrompt(_ json: JSONObject) -> PendingPrompt {
        PendingPrompt(
            requestID: json.string("request_id"),
            prompt: json.string("prompt"),
            isPassword: json.bool("is_password"),
            toolCallID: json.optionalString("tool_call_id")
        )
    }

    private static func decodeSessions(_ json: JSONObject) -> SessionsPayload {
        let sessions = json.objectArray("sessions").map { row -> SessionSummary in
            SessionSummary(
                id: row.string("id"),
                shortName: row.string("short_name"),
                title: row.optionalString("title"),
                workingDir: row.optionalString("working_dir"),
                createdAt: row.optionalString("created_at"),
                updatedAt: row.optionalString("updated_at"),
                lastActiveAt: row.optionalString("last_active_at"),
                model: row.optionalString("model"),
                provider: row.optionalString("provider"),
                phase: SessionSummary.Phase(rawValue: row.string("phase")) ?? .idle,
                reason: row.optionalString("reason"),
                currentTool: row.optionalString("current_tool"),
                turnStartedAt: row.optionalString("turn_started_at"),
                queued: row.int("queued"),
                pendingPrompt: row.optionalObject("pending_prompt").map(decodePrompt),
                preview: row.optionalObject("preview").map {
                    SessionSummary.Preview(kind: $0.string("kind"), text: $0.string("text"))
                },
                clientCount: row.int("client_count"),
                isLive: row.bool("is_live"),
                parentID: row.optionalString("parent_id"),
                swarmRole: row.optionalString("swarm_role")
            )
        }
        let projects = json.objectArray("recent_projects").map { row in
            RecentProject(
                path: row.string("path"),
                lastUsedAt: row.optionalString("last_used_at"),
                sessionCount: row.int("session_count")
            )
        }
        return SessionsPayload(
            id: json.uint64("id"),
            serverName: json.optionalString("server_name"),
            serverIcon: json.optionalString("server_icon"),
            serverVersion: json.optionalString("server_version"),
            sessions: sessions,
            recentProjects: projects
        )
    }
}

public enum WireError: Error, Equatable {
    case encodingFailed
    case invalidJSON(line: String)
    case missingType(line: String)
}

/// Lenient JSON accessor. The wire protocol omits absent optionals and the
/// app must never crash on a server that is newer or older than itself.
struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    func string(_ key: String) -> String {
        raw[key] as? String ?? ""
    }

    func optionalString(_ key: String) -> String? {
        raw[key] as? String
    }

    func bool(_ key: String) -> Bool {
        raw[key] as? Bool ?? false
    }

    func int(_ key: String) -> Int {
        (raw[key] as? NSNumber)?.intValue ?? 0
    }

    func optionalInt(_ key: String) -> Int? {
        (raw[key] as? NSNumber)?.intValue
    }

    func uint64(_ key: String) -> UInt64 {
        Self.coerceUInt64(raw[key] ?? 0) ?? 0
    }

    func optionalUInt64(_ key: String) -> UInt64? {
        raw[key].flatMap(Self.coerceUInt64)
    }

    func optionalDouble(_ key: String) -> Double? {
        (raw[key] as? NSNumber)?.doubleValue
    }

    func stringArray(_ key: String) -> [String] {
        raw[key] as? [String] ?? []
    }

    func objectArray(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
    }

    func optionalObject(_ key: String) -> JSONObject? {
        (raw[key] as? [String: Any]).map(JSONObject.init)
    }

    static func coerceUInt64(_ value: Any) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return nil
    }
}
