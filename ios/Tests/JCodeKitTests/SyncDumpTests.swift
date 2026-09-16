import Foundation
import Testing

@testable import JCodeKit

private let sessionsLine = """
    {"type":"sessions","id":1,"server_name":"home-mini","sessions":[{"id":"s-1","short_name":"fox",\
    "title":"Fix the queue bar","working_dir":"/tmp/w","created_at":"2026-09-15T01:00:00Z",\
    "updated_at":"2026-09-15T02:00:00.5Z","last_active_at":"2026-09-15T02:00:00.5Z","model":"m1",\
    "provider":"anthropic","phase":"needs_you","reason":"prompt","current_tool":"bash",\
    "turn_started_at":"2026-09-15T01:59:00Z","queued":2,"pending_prompt":{"request_id":"r1",\
    "prompt":"Which DB?","is_password":false,"tool_call_id":"t1"},"preview":{"kind":"prompt",\
    "text":"Which DB?"},"client_count":1,"is_live":true,"parent_id":"root","swarm_role":"worker"},\
    {"id":"s-2","short_name":"owl","phase":"idle","queued":0,"client_count":0,"is_live":false}]}
    """

private func rows(_ line: String) throws -> [[String: Any]] {
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    return try #require(object["sessions"] as? [[String: Any]])
}

@Test func syncDumpRoundTripsSessionRowsWithWireKeys() throws {
    guard case .sessions(let payload) = try ServerEvent.decode(line: sessionsLine) else {
        Issue.record("not a sessions event")
        return
    }
    let original = try rows(sessionsLine)
    let encoded = payload.sessions.map(SyncDump.encode)
    #expect(encoded.count == original.count)
    for (lhs, rhs) in zip(encoded, original) {
        #expect(NSDictionary(dictionary: lhs) == NSDictionary(dictionary: rhs))
    }
}

@Test func syncDumpDocumentHasTheCheckedPaths() throws {
    guard case .sessions(let payload) = try ServerEvent.decode(line: sessionsLine) else {
        Issue.record("not a sessions event")
        return
    }
    let board = ServerBoard(serverID: "127.0.0.1:7643", name: "paired")
        .applying(payload, at: Date())
    var state = SessionState()
    state.sessionID = "s-1"
    state.sessionTitle = "Fix the queue bar"
    state.modelName = "m1"
    state.pendingInterrupts = ["later"]
    state.pendingPrompt = PendingPrompt(requestID: "r1", prompt: "Which DB?", isPassword: true, toolCallID: nil)
    state.transcript = [
        TranscriptEntry(role: .user, text: "hi"),
        TranscriptEntry(
            role: .assistant, text: "ok", reasoning: "think",
            toolCalls: [
                TranscriptEntry.ToolCall(id: "t1", name: "bash", input: "ls", output: "a", status: .succeeded),
                TranscriptEntry.ToolCall(id: "t2", name: "bash", status: .failed("boom")),
            ], isStreaming: true),
    ]
    let data = try SyncDump.data(
        servers: [SyncDump.Server(board: board, host: "127.0.0.1")],
        attached: state,
        completion: SyncDump.Completion(kind: "slash", rows: ["compact", "clear"]))
    let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    let servers = try #require(doc["board"] as? [[String: Any]])
    #expect(servers[0]["server"] as? String == "home-mini")
    #expect(servers[0]["host"] as? String == "127.0.0.1")
    #expect(servers[0]["reachable"] as? Bool == true)
    let sessions = try #require(servers[0]["sessions"] as? [[String: Any]])
    #expect(sessions.map { $0["id"] as? String } == ["s-1", "s-2"])
    #expect((sessions[0]["preview"] as? [String: Any])?["text"] as? String == "Which DB?")

    let attached = try #require(doc["attached"] as? [String: Any])
    #expect(attached["session_id"] as? String == "s-1")
    #expect(attached["title"] as? String == "Fix the queue bar")
    #expect(attached["model"] as? String == "m1")
    #expect(attached["queued"] as? [String] == ["later"])
    let prompt = try #require(attached["pending_prompt"] as? [String: Any])
    #expect(prompt["request_id"] as? String == "r1")
    #expect(prompt["is_password"] as? Bool == true)
    let transcript = try #require(attached["transcript"] as? [[String: Any]])
    #expect(transcript.map { $0["role"] as? String } == ["user", "assistant"])
    #expect(transcript[1]["reasoning"] as? String == "think")
    #expect(transcript[1]["streaming"] as? Bool == true)
    let tools = try #require(transcript[1]["tool_calls"] as? [[String: Any]])
    #expect(tools.map { $0["status"] as? String } == ["succeeded", "failed"])
    #expect(tools[0]["has_input"] as? Bool == true)
    #expect(tools[0]["has_output"] as? Bool == true)
    #expect(tools[1]["has_input"] as? Bool == false)

    let completion = try #require(doc["completion"] as? [String: Any])
    #expect(completion["kind"] as? String == "slash")
    #expect(completion["rows"] as? [String] == ["compact", "clear"])
}

@Test func syncDumpOnTheBoardHasNullAttachedAndNoCompletion() throws {
    let data = try SyncDump.data(servers: [], attached: nil, completion: .none)
    let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(doc["attached"] is NSNull)
    #expect((doc["board"] as? [Any])?.isEmpty == true)
    #expect((doc["completion"] as? [String: Any])?["kind"] as? String == "none")
}
