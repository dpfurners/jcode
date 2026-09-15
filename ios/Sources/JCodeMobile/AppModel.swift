import Foundation
import JCodeKit
import Observation

/// Observable glue between JCodeKit and the SwiftUI views.
///
/// Owns the credential store, the active `Connection`, and the derived
/// `SessionState`. Contains no protocol or state-transition logic itself;
/// everything flows through `SessionReducer`.
@MainActor
@Observable
final class AppModel {
    // MARK: - Published state

    private(set) var session = SessionState()
    private(set) var servers: [ServerCredential] = []
    /// Server of the attached session. Nil while on the board.
    var activeServer: ServerCredential?
    /// True while a session is attached (chat on screen). Back = detach.
    private(set) var isAttached = false
    let board = BoardModel()

    /// Composer draft. Setting it recomputes the completion popup.
    var draft = "" {
        didSet { if draft != oldValue { updateCompletion() } }
    }
    /// What the completion popup shows for the current draft.
    private(set) var completion = CompletionState()
    /// Images attached to the draft, already downscaled and encoded.
    var attachments: [PendingImage] = []

    // MARK: - Internals

    private let store: any CredentialStore
    private var connection: Connection?
    private var pumpTask: Task<Void, Never>?
    private var fileSearchTask: Task<Void, Never>?

    init(store: any CredentialStore = KeychainCredentialStore()) {
        self.store = store
        servers = store.loadAll()
        board.setServers(servers)
    }

    var hasServers: Bool { !servers.isEmpty }

    var isConnected: Bool {
        session.phase == .connected
    }

    // MARK: - Pairing

    func pair(gateway: Gateway, code: String, deviceName: String) async throws {
        let client = PairingClient()
        let response = try await client.pair(
            gateway: gateway,
            code: code,
            deviceID: deviceID(),
            deviceName: deviceName
        )
        let credential = ServerCredential(
            host: gateway.host,
            port: gateway.port,
            token: response.token,
            serverName: response.serverName,
            serverVersion: response.serverVersion
        )
        store.save(credential)
        servers = store.loadAll()
        board.setServers(servers)
        Task { await board.pollOne(credential) }
    }

    func removeServer(_ credential: ServerCredential) {
        store.remove(id: credential.id)
        servers = store.loadAll()
        board.setServers(servers)
        if activeServer?.id == credential.id {
            detach()
        }
    }

    // MARK: - Attach / detach (board <-> chat)

    /// Attaches to an existing session: full live sync alongside any other
    /// client (no takeover).
    func attach(to server: ServerCredential, sessionID: String) {
        isAttached = true
        connect(to: server, sessionID: sessionID)
    }

    /// Opens a new session in `workingDir` on `server`.
    func startSession(on server: ServerCredential, workingDir: String) {
        isAttached = true
        session = SessionState()
        open(server, sessionID: nil, workingDir: workingDir)
    }

    /// Back to the board: drops the session connection.
    func detach() {
        disconnect()
        isAttached = false
        activeServer = nil
        session = SessionState()
        draft = ""
        attachments = []
        fileSearchTask?.cancel()
        completion = CompletionState()
    }

    /// Resolves a `jcode://` link. Returns false (and posts a board banner)
    /// when the server is not paired.
    @discardableResult
    func open(deepLink: DeepLink) -> Bool {
        switch deepLink {
        case .board:
            detach()
            return true
        case .session(let host, let id):
            guard let server = DeepLink.matchServer(host: host, in: servers) else {
                detach()
                board.banner = "No paired server matches \"\(host)\""
                return false
            }
            attach(to: server, sessionID: id)
            return true
        }
    }

    // MARK: - Connection lifecycle

    func connect(to credential: ServerCredential, sessionID: String? = nil) {
        session = SessionState()
        open(credential, sessionID: sessionID)
    }

    /// Reconnects to the active server without discarding the rendered
    /// transcript; the history resync replaces it once the socket is back.
    func retryConnection() {
        guard let activeServer else { return }
        open(activeServer, sessionID: session.sessionID)
    }

    private func open(_ credential: ServerCredential, sessionID: String?, workingDir: String? = nil) {
        disconnect()
        activeServer = credential
        let connection = Connection(
            configuration: .init(
                gateway: credential.gateway,
                authToken: credential.token
            )
        )
        self.connection = connection
        pumpTask = Task { [weak self] in
            let stream = await connection.start(resumeSessionID: sessionID, workingDir: workingDir)
            for await output in stream {
                guard let self else { return }
                self.session = SessionReducer.reduce(self.session, output)
                if case .event(let event) = output {
                    self.consumeFileMatches(event)
                }
            }
        }
    }

    func disconnect() {
        pumpTask?.cancel()
        pumpTask = nil
        let connection = connection
        self.connection = nil
        Task { await connection?.stop() }
        session = SessionReducer.reduce(session, .phase(.disconnected))
    }

    // MARK: - Actions

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments.map(\.attachment)
        guard !text.isEmpty || !images.isEmpty else { return }
        draft = ""
        attachments = []
        let shown = images.isEmpty ? text : text + " [\(images.count) image\(images.count == 1 ? "" : "s")]"
        if session.isProcessing {
            session = SessionReducer.reduce(session, intent: .userQueuedInterrupt(shown))
            send { .softInterrupt(id: $0, content: text, urgent: false, images: images) }
        } else {
            let skill = Completion.activeSkill(in: text, skills: session.skills)
            session = SessionReducer.reduce(session, intent: .userSentMessage(shown))
            send { .message(id: $0, content: text, images: images, activeSkill: skill) }
        }
    }

    // MARK: - Composer completion

    /// Inserts the tapped row into the draft in place of the token.
    func acceptCompletion(_ row: String) {
        guard let token = Completion.token(in: draft) else { return }
        draft = Completion.apply(token, replacement: row, to: draft)
    }

    private func updateCompletion() {
        fileSearchTask?.cancel()
        guard let token = Completion.token(in: draft) else {
            completion = CompletionState()
            return
        }
        switch token.kind {
        case .slash:
            completion = CompletionState(
                kind: .slash, query: token.query,
                rows: Completion.slashRows(skills: session.skills, query: token.query))
        case .file:
            // Keep stale rows while the next search is in flight so the popup
            // does not flicker; one request per token change after 300 ms.
            completion = CompletionState(
                kind: .file, query: token.query,
                rows: completion.kind == .file ? completion.rows : [])
            let query = token.query
            fileSearchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let connection = self.connection else { return }
                let requestID = try? await connection.send {
                    .searchFiles(id: $0, query: query, limit: 30, dirsOnly: false, workingDir: nil)
                }
                self.pendingFileSearch = (requestID, query)
            }
        }
    }

    /// The in-flight `search_files` request whose `file_matches` reply
    /// feeds the popup. Older replies are ignored.
    private var pendingFileSearch: (id: UInt64?, query: String)?

    private func consumeFileMatches(_ event: ServerEvent) {
        guard case let .fileMatches(id, query, matches) = event,
            let pending = pendingFileSearch, pending.id == id,
            completion.kind == .file, completion.query == query
        else { return }
        completion.rows = matches.map(\.path)
    }

    /// Answers the pending `stdin_request` from the inline prompt card.
    func answerPrompt(_ input: String) {
        guard let prompt = session.pendingPrompt else { return }
        session = SessionReducer.reduce(session, intent: .answeredPrompt(requestID: prompt.requestID))
        send { .stdinResponse(id: $0, requestID: prompt.requestID, input: input) }
    }

    func addAttachment(_ image: PendingImage) {
        attachments.append(image)
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func interrupt() {
        send { .cancel(id: $0) }
    }

    func switchSession(_ sessionID: String) {
        guard let activeServer else { return }
        connect(to: activeServer, sessionID: sessionID)
    }

    func setModel(_ model: String) {
        send { .setModel(id: $0, model: model) }
    }

    func setReasoningEffort(_ effort: String) {
        send { .setReasoningEffort(id: $0, effort: effort) }
    }

    /// Asks the server to compact the conversation context.
    func compactConversation() {
        send { .compact(id: $0) }
    }

    func renameSession(_ title: String) {
        send { .renameSession(id: $0, title: title.isEmpty ? nil : title) }
    }

    func dismissError() {
        session = SessionReducer.reduce(session, intent: .dismissError)
    }

    func dismissNotice(_ id: UUID) {
        session = SessionReducer.reduce(session, intent: .dismissNotice(id))
    }

    /// Clears the current conversation on the server and optimistically locally.
    func clearConversation() {
        session = SessionReducer.reduce(session, intent: .clearedConversation)
        send { .clear(id: $0) }
    }

    /// Drops any soft-interrupt messages queued mid-run before they inject.
    func cancelQueuedInterrupts() {
        session = SessionReducer.reduce(session, intent: .cancelledQueuedInterrupts)
        send { .cancelSoftInterrupts(id: $0) }
    }

    // MARK: - Helpers

    private func send(_ build: @escaping @Sendable (UInt64) -> Request) {
        guard let connection else { return }
        Task {
            do {
                try await connection.send(build)
            } catch {
                // Connection drops surface via phase changes; nothing to do here.
            }
        }
    }

    private func deviceID() -> String {
        let key = "jcode.device.id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

/// Rows for the composer completion popup.
struct CompletionState: Equatable {
    enum Kind: String { case none, slash, file }
    var kind: Kind = .none
    var query = ""
    /// Slash: command/skill names without the sigil. File: relative paths
    /// exactly as they will be inserted.
    var rows: [String] = []
}
