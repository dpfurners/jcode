import Foundation

/// One entry in the rendered transcript.
public struct TranscriptEntry: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    public struct ToolCall: Equatable, Sendable, Identifiable {
        public enum Status: Equatable, Sendable {
            case streamingInput
            case running
            case succeeded
            case failed(String)
        }

        public var id: String
        public var name: String
        public var input: String
        public var output: String
        public var status: Status

        public init(
            id: String, name: String, input: String = "", output: String = "",
            status: Status = .streamingInput
        ) {
            self.id = id
            self.name = name
            self.input = input
            self.output = output
            self.status = status
        }
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var reasoning: String
    public var toolCalls: [ToolCall]
    /// True while this entry is still receiving streamed content.
    public var isStreaming: Bool
    /// True while this entry is a soft-interrupt waiting for the server to
    /// inject it at a safe point. Cleared by `soft_interrupt_injected`.
    public var isQueued: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        reasoning: String = "",
        toolCalls: [ToolCall] = [],
        isStreaming: Bool = false,
        isQueued: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
        self.isQueued = isQueued
    }
}

/// A transient, user-dismissible notice surfaced to the UI.
///
/// Covers out-of-band server signals that must never be silently dropped:
/// push notifications, interrupts, and context compaction events.
public struct Notice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case info
        case notification
        case compaction
    }

    public var id: UUID
    public var kind: Kind
    public var message: String

    public init(id: UUID = UUID(), kind: Kind = .info, message: String) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}

/// Full client-side session state derived from server events.
public struct SessionState: Equatable, Sendable {
    public var phase: ConnectionPhase
    public var transcript: [TranscriptEntry]
    public var sessionID: String?
    public var sessionTitle: String?
    public var allSessions: [String]
    /// Human titles for sessions in `allSessions`, keyed by session ID.
    /// Populated from `session_renamed` broadcasts and history payloads.
    public var sessionTitles: [String: String]
    public var isProcessing: Bool
    /// True while the live turn is one this client did not start: another
    /// client's message, or a turn already running when we attached. Such a
    /// turn only ever streams its tail to us (and never the other client's
    /// user message), so the app re-reads history when it ends.
    public var isAdoptedTurn: Bool
    public var isReasoning: Bool
    public var modelName: String?
    public var providerName: String?
    public var availableModels: [String]
    public var reasoningEffort: String?
    public var serverVersion: String?
    public var tokenInput: UInt64
    public var tokenOutput: UInt64
    public var statusDetail: String?
    /// Live turn-level provider phase (e.g. "authenticating", "waiting").
    public var serverPhase: String?
    public var errorBanner: String?
    public var notices: [Notice]
    /// Soft-interrupt messages queued mid-run, in send order, until the
    /// server confirms injection.
    public var pendingInterrupts: [String]
    /// A running tool is waiting on the user (`stdin_request`). Cleared when
    /// this or another client answers it, or when the turn ends.
    public var pendingPrompt: PendingPrompt?
    /// Installed skill names from the history payload, for `/` completion.
    public var skills: [String]

    public var hasPendingInterrupts: Bool { !pendingInterrupts.isEmpty }

    /// Human title for a session in the list, falling back to nil when unknown.
    public func title(forSession sessionID: String) -> String? {
        sessionTitles[sessionID]
    }

    public init() {
        phase = .disconnected
        transcript = []
        sessionID = nil
        sessionTitle = nil
        allSessions = []
        sessionTitles = [:]
        isProcessing = false
        isAdoptedTurn = false
        isReasoning = false
        modelName = nil
        providerName = nil
        availableModels = []
        reasoningEffort = nil
        serverVersion = nil
        tokenInput = 0
        tokenOutput = 0
        statusDetail = nil
        serverPhase = nil
        errorBanner = nil
        notices = []
        pendingInterrupts = []
        pendingPrompt = nil
        skills = []
    }
}

/// Local intents that mutate state without a server round-trip.
public enum LocalIntent: Equatable, Sendable {
    /// User submitted a message; append it optimistically.
    case userSentMessage(String)
    /// User queued a soft-interrupt message mid-run.
    case userQueuedInterrupt(String)
    /// User cancelled all queued soft-interrupts before they injected; the
    /// optimistic bubbles are removed because they will never reach the agent.
    case cancelledQueuedInterrupts
    /// User answered the pending prompt (`stdin_response` was sent).
    case answeredPrompt(requestID: String)
    /// Dismiss the current error banner.
    case dismissError
    /// Dismiss a transient notice by id.
    case dismissNotice(UUID)
    /// User cleared the conversation; wipe the transcript optimistically while
    /// keeping the connection and session metadata.
    case clearedConversation
    /// Reset everything (switching servers/sessions).
    case reset
}

/// Pure state machine turning connection output into session state.
///
/// All streaming, tool lifecycle, and history-sync behavior lives here so it
/// can be exhaustively unit tested on macOS without UI or network.
public enum SessionReducer {
    public static func reduce(_ state: SessionState, _ output: ConnectionOutput) -> SessionState {
        switch output {
        case .phase(let phase):
            return reducePhase(state, phase)
        case .event(let event):
            return reduceEvent(state, event)
        }
    }

    public static func reduce(_ state: SessionState, intent: LocalIntent) -> SessionState {
        var state = state
        switch intent {
        case .userSentMessage(let text):
            state.transcript.append(TranscriptEntry(role: .user, text: text))
            state.isProcessing = true
            state.isAdoptedTurn = false
            state.errorBanner = nil
        case .userQueuedInterrupt(let text):
            state.transcript.append(TranscriptEntry(role: .user, text: text, isQueued: true))
            state.pendingInterrupts.append(text)
        case .cancelledQueuedInterrupts:
            state.transcript.removeAll { $0.isQueued }
            state.pendingInterrupts = []
        case .answeredPrompt(let requestID):
            if state.pendingPrompt?.requestID == requestID {
                state.pendingPrompt = nil
            }
        case .dismissError:
            state.errorBanner = nil
        case .dismissNotice(let id):
            state.notices.removeAll { $0.id == id }
        case .clearedConversation:
            state.transcript = []
            state.isProcessing = false
            state.isReasoning = false
            state.errorBanner = nil
        case .reset:
            state = SessionState()
        }
        return state
    }

    // MARK: - Phase

    private static func reducePhase(_ state: SessionState, _ phase: ConnectionPhase)
        -> SessionState
    {
        var state = state
        state.phase = phase
        switch phase {
        case .connected:
            state.errorBanner = nil
        case .failed(let reason):
            state.errorBanner = reason
            state.isProcessing = false
            state.isReasoning = false
        case .disconnected, .reconnecting:
            state.isProcessing = false
            state.isReasoning = false
            state.serverPhase = nil
            // The server replays a still-pending prompt after resubscribe.
            state.pendingPrompt = nil
            finishStreaming(&state)
        case .connecting:
            break
        }
        return state
    }

    // MARK: - Events

    private static func reduceEvent(_ state: SessionState, _ event: ServerEvent) -> SessionState {
        var state = state
        switch event {
        case .textDelta(let text):
            adoptRunningTurn(&state)
            withStreamingAssistant(&state) { $0.text += text }

        case .reasoningDelta(let text):
            adoptRunningTurn(&state)
            state.isReasoning = true
            withStreamingAssistant(&state) { $0.reasoning += text }

        case .reasoningDone:
            state.isReasoning = false

        case .textReplace(let text):
            withStreamingAssistant(&state) { $0.text = text }

        case .toolStart(let id, let name):
            adoptRunningTurn(&state)
            withStreamingAssistant(&state) { entry in
                entry.toolCalls.append(.init(id: id, name: name))
            }

        // The daemon ends the assistant *message* (`message_end`) when the
        // model stops to call a tool, then runs the tool and reports
        // `tool_exec`/`tool_done` for a call that now lives in an entry that
        // is no longer streaming. Looking only at the trailing streaming
        // entry opened a second assistant row for the finished call, so the
        // phone showed two rows where the daemon's history has one. Calls
        // are therefore located by id across the whole transcript, the way
        // the macOS client does.
        case .toolInput(let delta):
            if let location = lastStreamingInputToolCall(in: state) {
                state.transcript[location.entry].toolCalls[location.call].input += delta
            }

        case .toolExec(let id, let name):
            adoptRunningTurn(&state)
            if let location = locateToolCall(id: id, in: state) {
                state.transcript[location.entry].toolCalls[location.call].status = .running
            } else {
                withStreamingAssistant(&state) { entry in
                    entry.toolCalls.append(.init(id: id, name: name, status: .running))
                }
            }

        case .toolDone(let id, let name, let output, let error):
            adoptRunningTurn(&state)
            if let location = locateToolCall(id: id, in: state) {
                state.transcript[location.entry].toolCalls[location.call].output = output
                state.transcript[location.entry].toolCalls[location.call].status =
                    error.map { .failed($0) } ?? .succeeded
            } else {
                withStreamingAssistant(&state) { entry in
                    entry.toolCalls.append(
                        .init(
                            id: id, name: name, output: output,
                            status: error.map { .failed($0) } ?? .succeeded
                        ))
                }
            }

        case .messageEnd:
            finishStreaming(&state)

        case .connectionPhase(let phase):
            state.serverPhase = phase.isEmpty ? nil : phase

        case .softInterruptInjected(let content, let displayRole, _, _):
            resolvePendingInterrupt(&state, content: content, displayRole: displayRole)

        case .retryRollback(let attempt, let max):
            // The provider is replaying the response from the top: discard all
            // partial output from the current attempt so it does not duplicate.
            if let last = state.transcript.indices.last, state.transcript[last].isStreaming {
                state.transcript.removeLast()
            }
            state.isReasoning = false
            state.statusDetail = "Retrying (\(attempt)/\(max))"

        case .done:
            state.isProcessing = false
            state.isAdoptedTurn = false
            state.isReasoning = false
            state.serverPhase = nil
            state.pendingPrompt = nil
            finishStreaming(&state)
            drainPendingInterrupts(&state)

        case .interrupted:
            state.isProcessing = false
            state.isReasoning = false
            state.serverPhase = nil
            state.pendingPrompt = nil
            finishStreaming(&state)
            drainPendingInterrupts(&state)
            state.notices.append(Notice(message: "Interrupted"))

        case .error(_, let message, let retryAfterSecs):
            state.isProcessing = false
            state.isReasoning = false
            state.serverPhase = nil
            state.pendingPrompt = nil
            finishStreaming(&state)
            if let retry = retryAfterSecs {
                state.errorBanner = "\(message) (retry in \(retry)s)"
            } else {
                state.errorBanner = message
            }

        case .tokenUsage(let input, let output):
            state.tokenInput = input
            state.tokenOutput = output

        case .statusDetail(let detail):
            state.statusDetail = detail

        case .state(_, let sessionID, _, let isProcessing):
            state.sessionID = sessionID
            state.isProcessing = isProcessing

        case .sessionID(let sessionID):
            state.sessionID = sessionID

        case .sessionRenamed(let sessionID, let displayTitle):
            state.sessionTitles[sessionID] = displayTitle
            if state.sessionID == nil || state.sessionID == sessionID {
                state.sessionTitle = displayTitle
            }

        case .history(let payload):
            state = applyHistory(state, payload)

        case .modelChanged(_, let model, let error):
            if let error {
                state.errorBanner = error
            } else {
                state.modelName = model
            }

        case .reasoningEffortChanged(_, let effort, let error):
            if let error {
                state.errorBanner = error
            } else {
                state.reasoningEffort = effort
            }

        case .compactResult(_, let message, let success):
            if success {
                state.notices.append(Notice(kind: .compaction, message: message))
            } else {
                state.errorBanner = message
            }

        case .availableModelsUpdated(let models, let providerModel):
            state.availableModels = models
            if let providerModel {
                state.modelName = providerModel
            }

        case .compaction(let trigger, let tokensSaved):
            if let saved = tokensSaved, trigger != "background" {
                state.notices.append(
                    Notice(kind: .compaction, message: "Context compacted (\(saved) tokens saved)"))
            }

        case .notification(let fromName, let message):
            let prefix = fromName.map { "\($0): " } ?? ""
            state.notices.append(Notice(kind: .notification, message: prefix + message))

        case .reloading:
            state.notices.append(Notice(message: "Server is updating, reconnecting shortly"))

        case .sessionCloseRequested(let reason):
            state.isProcessing = false
            state.isReasoning = false
            state.pendingPrompt = nil
            finishStreaming(&state)
            state.errorBanner = reason.isEmpty ? "Server closed this session" : reason

        case .stdinRequest(let prompt):
            // A tool blocked on input means the turn is live even if no
            // `state` event said so (replay after attach).
            state.pendingPrompt = prompt
            adoptRunningTurn(&state)

        case .stdinResolved(let requestID):
            if state.pendingPrompt?.requestID == requestID {
                state.pendingPrompt = nil
            }

        case .ack, .pong, .unknown, .sessions, .sessionClosed, .fileMatches:
            // Board/search replies are consumed by their requesters, not the
            // attached-session state.
            break
        }
        return state
    }

    private static func applyHistory(
        _ state: SessionState, _ payload: ServerEvent.HistoryPayload
    ) -> SessionState {
        var state = state
        state.sessionID = payload.sessionID
        state.providerName = payload.providerName ?? state.providerName
        state.modelName = payload.providerModel ?? state.modelName
        if !payload.availableModels.isEmpty {
            state.availableModels = payload.availableModels
        }
        if !payload.allSessions.isEmpty {
            state.allSessions = payload.allSessions
        }
        state.serverVersion = payload.serverVersion ?? state.serverVersion
        state.sessionTitle = payload.displayTitle ?? state.sessionTitle
        state.reasoningEffort = payload.reasoningEffort ?? state.reasoningEffort
        if !payload.skills.isEmpty {
            state.skills = payload.skills
        }
        if let title = payload.displayTitle {
            state.sessionTitles[payload.sessionID] = title
        }
        // History replaces the transcript wholesale, so optimistic queued
        // bubbles are rebuilt from the server's authoritative view.
        state.pendingInterrupts = []
        if let totals = payload.totalTokens {
            state.tokenInput = totals.input
            state.tokenOutput = totals.output
        }

        // History replaces the transcript wholesale: it is the server's
        // authoritative view, used on connect and reconnect.
        state.transcript = payload.messages.compactMap { message in
            let role: TranscriptEntry.Role
            switch message.role {
            case "user": role = .user
            case "assistant": role = .assistant
            case "system": role = .system
            default: return nil
            }
            var toolCalls: [TranscriptEntry.ToolCall] = []
            if let data = message.toolData {
                toolCalls.append(
                    .init(
                        id: data.id,
                        name: data.name,
                        input: data.input,
                        output: data.output ?? "",
                        status: data.error.map { .failed($0) }
                            ?? (data.output != nil ? .succeeded : .running)
                    ))
            } else {
                toolCalls = message.toolCalls.map { name in
                    .init(id: name, name: name, status: .succeeded)
                }
            }
            // History inlines persisted reasoning into the assistant text as
            // sentinel-marked emphasis lines; split it back out so a reopened
            // session shows thinking in the same disclosure as a live one
            // (and so the transcript matches what the macOS client shows).
            let (text, reasoning) = role == .assistant
                ? ReasoningMarkup.split(content: message.content)
                : (message.content, "")
            // Skip empty assistant placeholders.
            if text.isEmpty && reasoning.isEmpty && toolCalls.isEmpty {
                return nil
            }
            return TranscriptEntry(role: role, text: text, reasoning: reasoning, toolCalls: toolCalls)
        }
        return state
    }

    // MARK: - Helpers

    /// Marks the matching queued soft-interrupt as delivered. If the injection
    /// came from another client (no optimistic bubble), appends the content so
    /// the transcript still reflects what the agent saw.
    private static func resolvePendingInterrupt(
        _ state: inout SessionState, content: String, displayRole: String?
    ) {
        if let index = state.pendingInterrupts.firstIndex(of: content) {
            state.pendingInterrupts.remove(at: index)
        }
        if let index = state.transcript.firstIndex(where: { $0.isQueued && $0.text == content })
            ?? state.transcript.firstIndex(where: { $0.isQueued })
        {
            state.transcript[index].isQueued = false
        } else {
            let role: TranscriptEntry.Role = displayRole == "system" ? .system : .user
            state.transcript.append(TranscriptEntry(role: role, text: content))
        }
    }

    /// The turn is over: anything still marked queued has either been consumed
    /// server-side or is moot, so stop showing it as pending.
    private static func drainPendingInterrupts(_ state: inout SessionState) {
        state.pendingInterrupts = []
        for index in state.transcript.indices where state.transcript[index].isQueued {
            state.transcript[index].isQueued = false
        }
    }

    /// Mutates the trailing streaming assistant entry, creating it if needed.
    /// A streamed fragment for a turn we never marked as started means the
    /// turn belongs to someone else; note that so the app can catch up on
    /// the parts that were never streamed to us once it ends.
    private static func adoptRunningTurn(_ state: inout SessionState) {
        guard !state.isProcessing else { return }
        state.isProcessing = true
        state.isAdoptedTurn = true
    }

    private typealias ToolCallLocation = (entry: Int, call: Int)

    /// The newest call with this id anywhere in the transcript: a finished
    /// call is reported after its entry stopped streaming.
    private static func locateToolCall(id: String, in state: SessionState) -> ToolCallLocation? {
        for entryIndex in state.transcript.indices.reversed() {
            if let callIndex = state.transcript[entryIndex].toolCalls.lastIndex(where: {
                $0.id == id
            }) {
                return (entryIndex, callIndex)
            }
        }
        return nil
    }

    /// The most recent call still accumulating streamed input, which is the
    /// only sink `tool_input` deltas can refer to (they carry no id).
    private static func lastStreamingInputToolCall(in state: SessionState) -> ToolCallLocation? {
        for entryIndex in state.transcript.indices.reversed() {
            let calls = state.transcript[entryIndex].toolCalls
            guard let callIndex = calls.indices.last else { continue }
            guard calls[callIndex].status == .streamingInput else { return nil }
            return (entryIndex, callIndex)
        }
        return nil
    }

    private static func withStreamingAssistant(
        _ state: inout SessionState, _ mutate: (inout TranscriptEntry) -> Void
    ) {
        if let last = state.transcript.indices.last,
            state.transcript[last].role == .assistant,
            state.transcript[last].isStreaming
        {
            mutate(&state.transcript[last])
        } else {
            var entry = TranscriptEntry(role: .assistant, text: "", isStreaming: true)
            mutate(&entry)
            state.transcript.append(entry)
        }
    }

    private static func finishStreaming(_ state: inout SessionState) {
        if let last = state.transcript.indices.last, state.transcript[last].isStreaming {
            state.transcript[last].isStreaming = false
            // Drop fully-empty assistant stubs (e.g. tool-only turns that
            // were replaced or cancelled before any text arrived).
            if state.transcript[last].text.isEmpty
                && state.transcript[last].toolCalls.isEmpty
                && state.transcript[last].reasoning.isEmpty
            {
                state.transcript.removeLast()
            }
        }
    }
}
