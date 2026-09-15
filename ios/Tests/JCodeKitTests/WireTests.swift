import Foundation
import Testing

@testable import JCodeKit

// MARK: - Gateway / PairURI

@Test func gatewayBuildsEndpoints() {
    let gateway = Gateway(host: "devbox.tailnet.ts.net")
    #expect(gateway.healthURL.absoluteString == "http://devbox.tailnet.ts.net:7643/health")
    #expect(gateway.pairURL.absoluteString == "http://devbox.tailnet.ts.net:7643/pair")
    #expect(gateway.webSocketURL.absoluteString == "ws://devbox.tailnet.ts.net:7643/ws")
}

@Test func pairURIParsesQRPayload() {
    let payload = PairURI.parse("jcode://pair?host=mybox.ts.net&port=7643&code=123456")
    #expect(payload?.gateway.host == "mybox.ts.net")
    #expect(payload?.gateway.port == 7643)
    #expect(payload?.code == "123456")
}

@Test func pairURIDefaultsPort() {
    let payload = PairURI.parse("jcode://pair?host=mybox&code=987654")
    #expect(payload?.gateway.port == Gateway.defaultPort)
}

@Test func pairURIRejectsGarbage() {
    #expect(PairURI.parse("https://example.com/pair?host=x&code=1") == nil)
    #expect(PairURI.parse("jcode://pair?host=&code=1") == nil)
    #expect(PairURI.parse("jcode://pair?host=x") == nil)
    #expect(PairURI.parse("not a uri") == nil)
}

// MARK: - Request encoding (must match crates/jcode-protocol/src/wire.rs)

private func encodedObject(_ request: Request) throws -> [String: Any] {
    let line = try request.encodedLine()
    let data = line.data(using: .utf8)!
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Test func encodesMessageRequest() throws {
    let object = try encodedObject(.message(id: 7, content: "hello"))
    #expect(object["type"] as? String == "message")
    #expect(object["id"] as? UInt64 == 7)
    #expect(object["content"] as? String == "hello")
}

@Test func encodesSubscribeWithTargetSession() throws {
    let object = try encodedObject(.subscribe(id: 1, targetSessionID: "sess_abc"))
    #expect(object["type"] as? String == "subscribe")
    #expect(object["target_session_id"] as? String == "sess_abc")

    let bare = try encodedObject(.subscribe(id: 2, targetSessionID: nil))
    #expect(bare["target_session_id"] == nil)
}

@Test func encodesControlRequests() throws {
    #expect(try encodedObject(.cancel(id: 3))["type"] as? String == "cancel")
    #expect(try encodedObject(.ping(id: 4))["type"] as? String == "ping")
    #expect(try encodedObject(.getHistory(id: 5))["type"] as? String == "get_history")
    #expect(try encodedObject(.clear(id: 6))["type"] as? String == "clear")
    #expect(
        try encodedObject(.cancelSoftInterrupts(id: 8))["type"] as? String
            == "cancel_soft_interrupts")

    let soft = try encodedObject(.softInterrupt(id: 9, content: "also do x", urgent: true))
    #expect(soft["type"] as? String == "soft_interrupt")
    #expect(soft["content"] as? String == "also do x")
    #expect(soft["urgent"] as? Bool == true)

    let resume = try encodedObject(.resumeSession(id: 10, sessionID: "sess_x"))
    #expect(resume["type"] as? String == "resume_session")
    #expect(resume["session_id"] as? String == "sess_x")

    let model = try encodedObject(.setModel(id: 11, model: "claude-sonnet-4"))
    #expect(model["type"] as? String == "set_model")
    #expect(model["model"] as? String == "claude-sonnet-4")

    let rename = try encodedObject(.renameSession(id: 12, title: "My session"))
    #expect(rename["type"] as? String == "rename_session")
    #expect(rename["title"] as? String == "My session")
}

@Test func encodesReasoningEffortAndCompact() throws {
    let effort = try encodedObject(.setReasoningEffort(id: 13, effort: "high"))
    #expect(effort["type"] as? String == "set_reasoning_effort")
    #expect(effort["id"] as? UInt64 == 13)
    #expect(effort["effort"] as? String == "high")

    let compact = try encodedObject(.compact(id: 14))
    #expect(compact["type"] as? String == "compact")
    #expect(compact["id"] as? UInt64 == 14)
}

// MARK: - ServerEvent decoding (fixtures mirror real server output)

@Test func decodesStreamingEvents() throws {
    #expect(
        try ServerEvent.decode(line: #"{"type":"text_delta","text":"Hel"}"#)
            == .textDelta(text: "Hel"))
    #expect(
        try ServerEvent.decode(line: #"{"type":"reasoning_delta","text":"hmm"}"#)
            == .reasoningDelta(text: "hmm"))
    #expect(
        try ServerEvent.decode(line: #"{"type":"reasoning_done","duration_secs":1.5}"#)
            == .reasoningDone(durationSecs: 1.5))
    #expect(
        try ServerEvent.decode(line: #"{"type":"text_replace","text":"clean"}"#)
            == .textReplace(text: "clean"))
    #expect(try ServerEvent.decode(line: #"{"type":"message_end"}"#) == .messageEnd)
    #expect(try ServerEvent.decode(line: #"{"type":"done","id":3}"#) == .done(id: 3))
    #expect(try ServerEvent.decode(line: #"{"type":"interrupted"}"#) == .interrupted)
}

@Test func decodesToolLifecycle() throws {
    #expect(
        try ServerEvent.decode(line: #"{"type":"tool_start","id":"t1","name":"bash"}"#)
            == .toolStart(id: "t1", name: "bash"))
    #expect(
        try ServerEvent.decode(line: #"{"type":"tool_input","delta":"{\"cmd\""}"#)
            == .toolInput(delta: "{\"cmd\""))
    #expect(
        try ServerEvent.decode(line: #"{"type":"tool_exec","id":"t1","name":"bash"}"#)
            == .toolExec(id: "t1", name: "bash"))
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"tool_done","id":"t1","name":"bash","output":"ok"}"#)
            == .toolDone(id: "t1", name: "bash", output: "ok", error: nil))
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"tool_done","id":"t2","name":"bash","output":"","error":"boom"}"#)
            == .toolDone(id: "t2", name: "bash", output: "", error: "boom"))
}

@Test func decodesErrorAndStatus() throws {
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"error","id":1,"message":"rate limited","retry_after_secs":30}"#)
            == .error(id: 1, message: "rate limited", retryAfterSecs: 30))
    #expect(
        try ServerEvent.decode(line: #"{"type":"tokens","input":1200,"output":340}"#)
            == .tokenUsage(input: 1200, output: 340))
    #expect(
        try ServerEvent.decode(line: #"{"type":"status_detail","detail":"thinking"}"#)
            == .statusDetail(detail: "thinking"))
    #expect(
        try ServerEvent.decode(
            line:
                #"{"type":"state","id":2,"session_id":"s1","message_count":4,"is_processing":true}"#
        ) == .state(id: 2, sessionID: "s1", messageCount: 4, isProcessing: true))
}

@Test func decodesSessionEvents() throws {
    #expect(
        try ServerEvent.decode(line: #"{"type":"session","session_id":"sess_1"}"#)
            == .sessionID(sessionID: "sess_1"))
    #expect(
        try ServerEvent.decode(
            line:
                #"{"type":"session_renamed","session_id":"sess_1","display_title":"Fix bug"}"#)
            == .sessionRenamed(sessionID: "sess_1", displayTitle: "Fix bug"))
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"model_changed","id":5,"model":"gpt-5","provider_name":"openai"}"#)
            == .modelChanged(id: 5, model: "gpt-5", error: nil))
}

@Test func decodesHistoryPayload() throws {
    let line = """
        {"type":"history","id":2,"session_id":"sess_9","messages":[\
        {"role":"user","content":"hi"},\
        {"role":"assistant","content":"hello!","tool_calls":["bash"]},\
        {"role":"assistant","content":"","tool_data":{"id":"t1","name":"read","input":"{}","output":"data"}}\
        ],"provider_name":"anthropic","provider_model":"claude-sonnet-4",\
        "available_models":["claude-sonnet-4","claude-opus-4"],\
        "total_tokens":[1500,800],"all_sessions":["sess_9","sess_8"],\
        "server_version":"v0.26.11","display_title":"My chat"}
        """
    guard case let .history(payload) = try ServerEvent.decode(line: line) else {
        Issue.record("expected history event")
        return
    }
    #expect(payload.sessionID == "sess_9")
    #expect(payload.messages.count == 3)
    #expect(payload.messages[0].role == "user")
    #expect(payload.messages[1].toolCalls == ["bash"])
    #expect(payload.messages[2].toolData?.name == "read")
    #expect(payload.providerModel == "claude-sonnet-4")
    #expect(payload.availableModels.count == 2)
    #expect(payload.totalTokens == .init(input: 1500, output: 800))
    #expect(payload.allSessions == ["sess_9", "sess_8"])
    #expect(payload.serverVersion == "v0.26.11")
    #expect(payload.displayTitle == "My chat")
}

@Test func unknownEventTypesAreTolerated() throws {
    let event = try ServerEvent.decode(
        line: #"{"type":"some_future_event","payload":{"x":1}}"#)
    #expect(event == .unknown(type: "some_future_event"))
}

@Test func decodesTurnLifecycleSignals() throws {
    #expect(
        try ServerEvent.decode(line: #"{"type":"connection_phase","phase":"authenticating"}"#)
            == .connectionPhase(phase: "authenticating"))
    #expect(
        try ServerEvent.decode(line: #"{"type":"retry_rollback","attempt":2,"max":5}"#)
            == .retryRollback(attempt: 2, max: 5))
    #expect(
        try ServerEvent.decode(
            line:
                #"{"type":"soft_interrupt_injected","content":"also fix y","point":"C","tools_skipped":1}"#
        )
            == .softInterruptInjected(
                content: "also fix y", displayRole: nil, point: "C", toolsSkipped: 1))
    #expect(
        try ServerEvent.decode(
            line:
                #"{"type":"soft_interrupt_injected","content":"note","display_role":"system","point":"A"}"#
        )
            == .softInterruptInjected(
                content: "note", displayRole: "system", point: "A", toolsSkipped: nil))
}

@Test func decodesEffortAndCompactResponses() throws {
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"reasoning_effort_changed","id":3,"effort":"high"}"#)
            == .reasoningEffortChanged(id: 3, effort: "high", error: nil))
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"reasoning_effort_changed","id":4,"error":"unsupported"}"#)
            == .reasoningEffortChanged(id: 4, effort: nil, error: "unsupported"))
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"compact_result","id":5,"message":"Compaction started","success":true}"#
        )
            == .compactResult(id: 5, message: "Compaction started", success: true))
}

@Test func decodesServerLifecycleEvents() throws {
    #expect(
        try ServerEvent.decode(line: #"{"type":"reloading"}"#)
            == .reloading(newSocket: nil))
    #expect(
        try ServerEvent.decode(line: #"{"type":"reloading","new_socket":"/tmp/jcode.sock"}"#)
            == .reloading(newSocket: "/tmp/jcode.sock"))
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"session_close_requested","reason":"taken over"}"#)
            == .sessionCloseRequested(reason: "taken over"))
}

@Test func historyCarriesReasoningEffort() throws {
    let line =
        #"{"type":"history","id":1,"session_id":"s","messages":[],"reasoning_effort":"medium"}"#
    guard case let .history(payload) = try ServerEvent.decode(line: line) else {
        Issue.record("expected history event")
        return
    }
    #expect(payload.reasoningEffort == "medium")
}

@Test func malformedLinesThrow() {
    #expect(throws: WireError.self) {
        try ServerEvent.decode(line: "not json")
    }
    #expect(throws: WireError.self) {
        try ServerEvent.decode(line: #"{"no_type":true}"#)
    }
}

// MARK: - Phone wire additions (docs/PHONE-WIRE.md)

@Test func encodesSubscribeWithWorkingDirAndTakeover() throws {
    let object = try encodedObject(
        .subscribe(id: 1, targetSessionID: nil, workingDir: "/Users/me/dev/jed"))
    #expect(object["working_dir"] as? String == "/Users/me/dev/jed")
    #expect(object["target_session_id"] == nil)
    // False is omitted, exactly like serde's skip_serializing_if.
    #expect(object["allow_session_takeover"] == nil)

    let attach = try encodedObject(
        .subscribe(id: 2, targetSessionID: "s1", allowSessionTakeover: true))
    #expect(attach["allow_session_takeover"] as? Bool == true)
}

@Test func encodesImagesAsMimeBase64Pairs() throws {
    let image = ImageAttachment(mimeType: "image/jpeg", base64: "AAAA")
    let message = try encodedObject(.message(id: 1, content: "look", images: [image]))
    #expect(message["images"] as? [[String]] == [["image/jpeg", "AAAA"]])
    #expect(message["active_skill"] == nil)

    let bare = try encodedObject(.message(id: 2, content: "no images"))
    #expect(bare["images"] == nil)

    let soft = try encodedObject(
        .softInterrupt(id: 3, content: "also this", urgent: false, images: [image]))
    #expect(soft["images"] as? [[String]] == [["image/jpeg", "AAAA"]])
}

@Test func encodesActiveSkill() throws {
    let object = try encodedObject(
        .message(id: 1, content: "/grill-me my plan", activeSkill: "grill-me"))
    #expect(object["active_skill"] as? String == "grill-me")
}

@Test func encodesBoardRequests() throws {
    let list = try encodedObject(.listSessions(id: 7))
    #expect(list["type"] as? String == "list_sessions")
    #expect(list["limit"] as? Int == 100)
    #expect(list["include_workers"] as? Bool == false)

    let close = try encodedObject(.closeSession(id: 8, sessionID: "session_fox", delete: true))
    #expect(close["type"] as? String == "close_session")
    #expect(close["session_id"] as? String == "session_fox")
    #expect(close["delete"] as? Bool == true)

    let search = try encodedObject(
        .searchFiles(id: 9, query: "/Users/me/de", limit: 30, dirsOnly: true, workingDir: nil))
    #expect(search["type"] as? String == "search_files")
    #expect(search["query"] as? String == "/Users/me/de")
    #expect(search["dirs_only"] as? Bool == true)
    #expect(search["limit"] as? Int == 30)
    #expect(search["working_dir"] is NSNull)

    let scoped = try encodedObject(
        .searchFiles(id: 10, query: "compos", workingDir: "/Users/me/dev/jed"))
    #expect(scoped["working_dir"] as? String == "/Users/me/dev/jed")

    let stdin = try encodedObject(.stdinResponse(id: 11, requestID: "req-1", input: "yes"))
    #expect(stdin["type"] as? String == "stdin_response")
    #expect(stdin["request_id"] as? String == "req-1")
    #expect(stdin["input"] as? String == "yes")
}

@Test func decodesStdinRequestAndResolved() throws {
    #expect(
        try ServerEvent.decode(
            line:
                #"{"type":"stdin_request","request_id":"r1","prompt":"Password: ","is_password":true,"tool_call_id":"t9"}"#
        )
            == .stdinRequest(
                PendingPrompt(requestID: "r1", prompt: "Password: ", isPassword: true, toolCallID: "t9")))
    #expect(
        try ServerEvent.decode(line: #"{"type":"stdin_request","request_id":"r2","prompt":"Continue? "}"#)
            == .stdinRequest(
                PendingPrompt(requestID: "r2", prompt: "Continue? ", isPassword: false, toolCallID: nil)))
    #expect(
        try ServerEvent.decode(line: #"{"type":"stdin_resolved","request_id":"r1"}"#)
            == .stdinResolved(requestID: "r1"))
}

@Test func decodesSessionsPayload() throws {
    let line = """
        {"type":"sessions","id":7,"server_name":"work-mini","server_icon":"🔥",\
        "server_version":"v0.85.0 (abc1234)","sessions":[\
        {"id":"session_fox_1","short_name":"fox","title":"Fix the queue bar",\
        "working_dir":"/Users/dpfurner/dev/jed","created_at":"2026-09-15T18:45:33Z",\
        "updated_at":"2026-09-15T18:51:41Z","last_active_at":"2026-09-15T18:51:41Z",\
        "model":"claude-opus-4","provider":"claude","phase":"needs_you",\
        "reason":"waiting for input","current_tool":"ask_user",\
        "turn_started_at":"2026-09-15T18:50:02Z","queued":1,\
        "pending_prompt":{"request_id":"r1","prompt":"Which DB?","is_password":false,"tool_call_id":"t1"},\
        "preview":{"kind":"prompt","text":"Which DB?"},"client_count":1,"is_live":true,\
        "parent_id":null,"swarm_role":null},\
        {"id":"session_owl_2","short_name":"owl","title":null,"phase":"idle","queued":0,\
        "pending_prompt":null,"preview":null,"client_count":0,"is_live":false}\
        ],"recent_projects":[\
        {"path":"/Users/dpfurner/dev/jed","last_used_at":"2026-09-15T18:51:41Z","session_count":41}]}
        """
    guard case let .sessions(payload) = try ServerEvent.decode(line: line) else {
        Issue.record("expected sessions event")
        return
    }
    #expect(payload.id == 7)
    #expect(payload.serverName == "work-mini")
    #expect(payload.serverIcon == "🔥")
    #expect(payload.sessions.count == 2)
    let fox = payload.sessions[0]
    #expect(fox.id == "session_fox_1")
    #expect(fox.shortName == "fox")
    #expect(fox.displayTitle == "Fix the queue bar")
    #expect(fox.phase == .needsYou)
    #expect(fox.reason == "waiting for input")
    #expect(fox.currentTool == "ask_user")
    #expect(fox.queued == 1)
    #expect(fox.pendingPrompt?.prompt == "Which DB?")
    #expect(fox.preview == .init(kind: "prompt", text: "Which DB?"))
    #expect(fox.isLive)
    #expect(fox.parentID == nil)
    #expect(fox.turnStartedAtDate != nil)
    #expect(fox.updatedAtDate.map { $0.timeIntervalSince1970 } == 1789498301)
    let owl = payload.sessions[1]
    #expect(owl.phase == .idle)
    #expect(owl.title == nil)
    #expect(owl.displayTitle == "owl")
    #expect(owl.pendingPrompt == nil)
    #expect(payload.recentProjects == [
        RecentProject(path: "/Users/dpfurner/dev/jed", lastUsedAt: "2026-09-15T18:51:41Z", sessionCount: 41)
    ])
}

@Test func sessionPhaseRanksNeedsYouFirst() throws {
    #expect(SessionSummary.Phase.needsYou > .failed)
    #expect(SessionSummary.Phase.failed > .running)
    #expect(SessionSummary.Phase.running > .idle)
    #expect(SessionSummary.Phase(rawValue: "needs_you") == .needsYou)
    #expect(SessionSummary.date("2026-09-15T18:51:41.123Z") != nil)
}

@Test func decodesSessionClosedAndFileMatches() throws {
    #expect(
        try ServerEvent.decode(
            line: #"{"type":"session_closed","id":8,"session_id":"session_fox","deleted":false}"#)
            == .sessionClosed(id: 8, sessionID: "session_fox", deleted: false))
    #expect(
        try ServerEvent.decode(
            line:
                #"{"type":"file_matches","id":9,"query":"compos","matches":[{"path":"Sources/Jed/Views/Chat/ComposerView.swift","is_dir":false},{"path":"/Users/me/dev","is_dir":true}]}"#
        )
            == .fileMatches(
                id: 9, query: "compos",
                matches: [
                    FileMatch(path: "Sources/Jed/Views/Chat/ComposerView.swift", isDir: false),
                    FileMatch(path: "/Users/me/dev", isDir: true),
                ]))
}

@Test func historyCarriesSkills() throws {
    let line =
        #"{"type":"history","id":1,"session_id":"s","messages":[],"skills":["grill-me","caveman"]}"#
    guard case let .history(payload) = try ServerEvent.decode(line: line) else {
        Issue.record("expected history event")
        return
    }
    #expect(payload.skills == ["grill-me", "caveman"])
}
