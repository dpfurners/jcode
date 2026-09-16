import Foundation

/// The phone-side half of `scripts/phone-sync-check.sh` (docs/PHONE.md M4):
/// a JSON snapshot of what the app currently shows, in the wire's own
/// vocabulary, so the check can diff it against Jed and the daemon.
///
/// Pure: the app feeds it the board, the reducer state the chat renders and
/// the completion rows the popup lists; it never re-derives any of them.
public enum SyncDump {
    /// One saved server as the board sees it.
    public struct Server: Equatable, Sendable {
        public var board: ServerBoard
        /// The credential's literal host (the board only keeps "host:port").
        public var host: String

        public init(board: ServerBoard, host: String) {
            self.board = board
            self.host = host
        }
    }

    /// What the composer popup lists. `kind` is "slash", "file" or "none".
    public struct Completion: Equatable, Sendable {
        public var kind: String
        public var rows: [String]

        public init(kind: String, rows: [String]) {
            self.kind = kind
            self.rows = rows
        }

        public static let none = Completion(kind: "none", rows: [])
    }

    /// Builds the dump document. `attached` is nil while on the board.
    public static func document(
        servers: [Server], attached: SessionState?, completion: Completion
    ) -> [String: Any] {
        var doc: [String: Any] = [:]
        doc["board"] = servers.map { server -> [String: Any] in
            [
                "server": server.board.name,
                "host": server.host,
                "reachable": server.board.reachable == true,
                "sessions": server.board.sessions.map(encode),
            ]
        }
        doc["attached"] = attached.map(encode) ?? NSNull()
        doc["completion"] = ["kind": completion.kind, "rows": completion.rows]
        return doc
    }

    /// Serialized document with sorted keys (stable diffs).
    public static func data(
        servers: [Server], attached: SessionState?, completion: Completion
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: document(servers: servers, attached: attached, completion: completion),
            options: [.sortedKeys, .prettyPrinted])
    }

    // MARK: - Encoders

    /// A `sessions` row re-encoded with the wire's snake_case keys. Absent
    /// optionals are omitted, as the server omits them.
    public static func encode(_ row: SessionSummary) -> [String: Any] {
        var out: [String: Any] = [
            "id": row.id,
            "short_name": row.shortName,
            "phase": row.phase.rawValue,
            "queued": row.queued,
            "client_count": row.clientCount,
            "is_live": row.isLive,
        ]
        out["title"] = row.title
        out["working_dir"] = row.workingDir
        out["created_at"] = row.createdAt
        out["updated_at"] = row.updatedAt
        out["last_active_at"] = row.lastActiveAt
        out["model"] = row.model
        out["provider"] = row.provider
        out["reason"] = row.reason
        out["current_tool"] = row.currentTool
        out["turn_started_at"] = row.turnStartedAt
        out["parent_id"] = row.parentID
        out["swarm_role"] = row.swarmRole
        out["pending_prompt"] = row.pendingPrompt.map(encode)
        out["preview"] = row.preview.map { ["kind": $0.kind, "text": $0.text] }
        return out
    }

    public static func encode(_ prompt: PendingPrompt) -> [String: Any] {
        var out: [String: Any] = [
            "request_id": prompt.requestID,
            "prompt": prompt.prompt,
            "is_password": prompt.isPassword,
        ]
        out["tool_call_id"] = prompt.toolCallID
        return out
    }

    /// The attached session as the chat renders it.
    public static func encode(_ state: SessionState) -> [String: Any] {
        [
            "session_id": state.sessionID ?? "",
            "title": state.sessionTitle ?? NSNull(),
            "model": state.modelName ?? NSNull(),
            "transcript": state.transcript.map(encode),
            "pending_prompt": state.pendingPrompt.map(encode) ?? NSNull(),
            "queued": state.pendingInterrupts,
        ]
    }

    public static func encode(_ entry: TranscriptEntry) -> [String: Any] {
        [
            "role": entry.role.rawValue,
            "text": entry.text,
            "reasoning": entry.reasoning,
            "streaming": entry.isStreaming,
            "tool_calls": entry.toolCalls.map { call -> [String: Any] in
                [
                    "name": call.name,
                    "status": status(call.status),
                    "has_input": !call.input.isEmpty,
                    "has_output": !call.output.isEmpty,
                ]
            },
        ]
    }

    public static func status(_ status: TranscriptEntry.ToolCall.Status) -> String {
        switch status {
        case .streamingInput: "streaming_input"
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed: "failed"
        }
    }
}
