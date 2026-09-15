import Foundation
import Testing

@testable import JCodeKit

private func session(
    _ id: String, phase: SessionSummary.Phase, updated: String
) -> SessionSummary {
    SessionSummary(id: id, shortName: id, updatedAt: updated, phase: phase)
}

@Test func boardRanksNeedsYouThenFailedThenRunningThenIdleThenNewest() {
    let a = ServerBoard(
        serverID: "a:7643", name: "home",
        sessions: [
            session("idle-old", phase: .idle, updated: "2026-09-15T10:00:00Z"),
            session("running", phase: .running, updated: "2026-09-15T09:00:00Z"),
            session("needs", phase: .needsYou, updated: "2026-09-15T01:00:00Z"),
        ], reachable: true)
    let b = ServerBoard(
        serverID: "b:7643", name: "work",
        sessions: [
            session("idle-new", phase: .idle, updated: "2026-09-15T11:00:00Z"),
            session("failed", phase: .failed, updated: "2026-09-15T02:00:00Z"),
        ], reachable: true)
    let rows = Board.rows([a, b])
    #expect(rows.map(\.session.id) == ["needs", "failed", "running", "idle-new", "idle-old"])
    #expect(rows[0].serverName == "home")
    #expect(rows[1].serverName == "work")
}

@Test func boardExcludesUnreachableServersFromRowsButListsThem() {
    let dead = ServerBoard(
        serverID: "dead:7643", name: "laptop",
        sessions: [session("s", phase: .running, updated: "2026-09-15T11:00:00Z")],
        reachable: false, lastSeen: Date(timeIntervalSince1970: 100), lastError: "timeout")
    let unknown = ServerBoard(serverID: "new:7643", name: "fresh")
    let live = ServerBoard(serverID: "live:7643", name: "live", reachable: true)
    #expect(Board.rows([dead, unknown, live]).isEmpty)
    #expect(Board.unreachable([dead, unknown, live]).map(\.name) == ["laptop", "fresh"])
}

@Test func serverBoardFoldsPollResults() {
    let board = ServerBoard(serverID: "x:7643", name: "paired-name")
    let now = Date(timeIntervalSince1970: 1000)
    let ok = board.applying(
        SessionsPayload(
            id: 1, serverName: "work-mini", serverIcon: "🔥", serverVersion: "v1",
            sessions: [session("s", phase: .idle, updated: "2026-09-15T11:00:00Z")],
            recentProjects: [RecentProject(path: "/p")]),
        at: now)
    #expect(ok.name == "work-mini")
    #expect(ok.icon == "🔥")
    #expect(ok.reachable == true)
    #expect(ok.lastSeen == now)
    #expect(ok.sessions.count == 1)
    #expect(ok.recentProjects.map(\.path) == ["/p"])

    let failed = ok.failing("timeout")
    #expect(failed.reachable == false)
    #expect(failed.lastError == "timeout")
    // Rows and last-seen survive a blip so the UI can grey them out.
    #expect(failed.sessions == ok.sessions)
    #expect(failed.lastSeen == now)
}

@Test func deepLinkParsesBoardAndSession() {
    #expect(DeepLink.parse("jcode://board") == .board)
    #expect(DeepLink.parse("JCODE://Board") == .board)
    #expect(
        DeepLink.parse("jcode://session?host=work-mini&id=session_fox_1")
            == .session(host: "work-mini", id: "session_fox_1"))
    #expect(DeepLink.parse("jcode://session?host=work-mini") == nil)
    #expect(DeepLink.parse("jcode://session?id=x") == nil)
    #expect(DeepLink.parse("jcode://pair?host=h&code=1") == nil)
    #expect(DeepLink.parse("https://example.com/board") == nil)
}

@Test func deepLinkMatchesServerByLabelNameOrLiteralHost() {
    let servers = [
        ServerCredential(
            host: "work-mini.tail1234.ts.net", port: 7643, token: "t", serverName: "Work Mini",
            serverVersion: "v"),
        ServerCredential(
            host: "127.0.0.1", port: 7643, token: "t", serverName: "mock-jcode", serverVersion: "v"),
        ServerCredential(
            host: "100.64.0.9", port: 7643, token: "t", serverName: "home-mini", serverVersion: "v"),
    ]
    #expect(DeepLink.matchServer(host: "work-mini", in: servers)?.host == "work-mini.tail1234.ts.net")
    #expect(DeepLink.matchServer(host: "WORK-MINI", in: servers)?.host == "work-mini.tail1234.ts.net")
    #expect(DeepLink.matchServer(host: "Work Mini", in: servers)?.host == "work-mini.tail1234.ts.net")
    #expect(DeepLink.matchServer(host: "127.0.0.1", in: servers)?.serverName == "mock-jcode")
    #expect(DeepLink.matchServer(host: "home-mini", in: servers)?.host == "100.64.0.9")
    #expect(DeepLink.matchServer(host: "nope", in: servers) == nil)
}

// MARK: - ServerProbe (one-shot pre-subscribe requests)

private func probe(_ transport: FakeTransport, timeout: Double = 2) -> ServerProbe {
    ServerProbe(
        gateway: Gateway(host: "test.local"), authToken: "tok", timeoutSeconds: timeout,
        makeTransport: { transport })
}

@Test func probeListsSessionsWithoutSubscribing() async throws {
    let transport = FakeTransport()
    await transport.push(#"{"type":"pong","id":99}"#)
    await transport.push(
        #"{"type":"sessions","id":1,"server_name":"work-mini","sessions":[{"id":"s1","short_name":"fox","phase":"running"}],"recent_projects":[]}"#
    )
    let payload = try await probe(transport).listSessions()
    #expect(payload.serverName == "work-mini")
    #expect(payload.sessions.map(\.id) == ["s1"])
    let sent = await transport.sentLines
    #expect(sent.count == 1)
    #expect(sent[0].contains("\"type\":\"list_sessions\""))
    #expect(!sent.joined().contains("subscribe"))
}

@Test func probeSurfacesServerErrorsAndTimeouts() async throws {
    let erroring = FakeTransport()
    await erroring.push(#"{"type":"error","id":1,"message":"unknown session"}"#)
    await #expect(throws: ServerProbe.ProbeError.server("unknown session")) {
        try await probe(erroring).closeSession("nope", delete: false)
    }

    let silent = FakeTransport()
    await #expect(throws: ServerProbe.ProbeError.timeout) {
        try await probe(silent, timeout: 0.05).listSessions()
    }

    let down = FakeTransport(behavior: .failConnect)
    await #expect(throws: TransportError.self) {
        try await probe(down).listSessions()
    }
}

@Test func probeCloseAndSearchDecodeReplies() async throws {
    let closing = FakeTransport()
    await closing.push(#"{"type":"session_closed","id":1,"session_id":"s1","deleted":true}"#)
    #expect(try await probe(closing).closeSession("s1", delete: true) == true)
    let sent = await closing.sentLines
    #expect(sent[0].contains("\"delete\":true"))

    let searching = FakeTransport()
    await searching.push(
        #"{"type":"file_matches","id":1,"query":"/Users/me","matches":[{"path":"/Users/me/dev","is_dir":true}]}"#
    )
    let matches = try await probe(searching).searchFiles(query: "/Users/me", dirsOnly: true)
    #expect(matches == [FileMatch(path: "/Users/me/dev", isDir: true)])
}
