import JCodeKit
import SwiftUI

/// The board: every session across every paired server, ranked by how
/// urgently it needs the operator. Tap = attach. Polls while visible.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compactEdgePads) private var edgePads
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairing = false
    @State private var showNewSession = false
    @State private var showSettings = false
    @State private var pendingDelete: BoardRow?
    /// Ticks once a second so elapsed timers on running rows advance.
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.board.banner {
                ErrorBanner(message: banner) { model.board.banner = nil }
                    .padding(.bottom, 8)
            }
            if let error = model.board.actionError {
                ErrorBanner(message: error) { model.board.actionError = nil }
                    .padding(.bottom, 8)
            }
            list
        }
        .onReceive(clock) { now = $0 }
        .onAppear { model.board.start() }
        .onDisappear { model.board.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.board.start() } else { model.board.stop() }
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                PairingView()
                    .background(Theme.background)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showPairing = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: model.servers.count) { _, _ in showPairing = false }
        .alert(
            "Delete session?", isPresented: .init(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    Task { await model.board.closeSession(row, delete: true) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("\(pendingDelete?.session.displayTitle ?? "") on \(pendingDelete?.serverName ?? "") is removed from disk. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Board")
                    .font(Theme.mono(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(summary)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            headerButton("plus", label: "Pair server", hint: "Pair a new server") {
                showPairing = true
            }
            headerButton("square.and.pencil", label: "New session", hint: "Start a session in a project") {
                showNewSession = true
            }
            .disabled(!model.hasServers)
            headerButton("ellipsis", label: "Settings", hint: "Servers and info") {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.top, edgePads.top)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Theme.background
                Theme.chrome
                Hairline()
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var summary: String {
        let rows = model.board.rows
        let needs = rows.filter { $0.session.phase == .needsYou }.count
        let running = rows.filter { $0.session.phase == .running }.count
        let reachable = model.board.boards.filter { $0.reachable == true }.count
        var parts = ["\(reachable)/\(model.board.boards.count) up"]
        if needs > 0 { parts.append("\(needs) need you") }
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ")
    }

    private func headerButton(
        _ symbol: String, label: String, hint: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(Theme.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    // MARK: - List

    private var list: some View {
        List {
            if model.board.rows.isEmpty && model.board.unreachable.isEmpty {
                emptyState
            }
            ForEach(model.board.rows) { row in
                Button {
                    if let server = model.servers.first(where: { $0.id == row.serverID }) {
                        model.attach(to: server, sessionID: row.session.id)
                    }
                } label: {
                    BoardRowView(row: row, now: now)
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.border)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = row
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await model.board.closeSession(row, delete: false) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .tint(Theme.warning)
                }
                .accessibilityHint("Attaches to this session")
            }
            ForEach(model.board.unreachable) { board in
                Section {
                    UnreachableHeader(board: board, now: now)
                        .listRowBackground(Theme.background)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .refreshable { await model.board.pollAll() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.hasServers ? "tray" : "link")
                .font(Theme.icon(28))
                .foregroundStyle(Theme.mint)
            Text(model.hasServers ? "No sessions yet" : "No servers paired")
                .font(Theme.mono(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(model.hasServers
                ? "Start one with the compose button."
                : "Tap + and scan the QR from `jcode pair`.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }
}

/// One session row: phase dot, title, server chip, elapsed/queued, preview.
struct BoardRowView: View {
    let row: BoardRow
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PhaseDot(phase: row.session.phase)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.session.displayTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ServerChip(name: row.serverName, icon: row.serverIcon)
                }
                HStack(spacing: 8) {
                    Text(statusLine)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    if row.session.queued > 0 {
                        Label("\(row.session.queued)", systemImage: "clock")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel("\(row.session.queued) queued")
                    }
                }
                if let preview = row.session.preview, !preview.text.isEmpty {
                    Text(preview.text)
                        .font(.footnote)
                        .foregroundStyle(preview.kind == "prompt" ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.session.displayTitle) on \(row.serverName), \(statusLine)")
    }

    private var statusLine: String {
        var parts: [String] = []
        switch row.session.phase {
        case .needsYou: parts.append(row.session.reason ?? "needs you")
        case .failed: parts.append(row.session.reason.map { "failed: \($0)" } ?? "failed")
        case .running: parts.append(row.session.currentTool ?? "running")
        case .idle: parts.append("idle")
        }
        if row.session.phase == .running || row.session.phase == .needsYou,
            let start = row.session.turnStartedAtDate
        {
            parts.append(Self.elapsed(since: start, now: now))
        }
        if let model = row.session.model {
            parts.append(shortModelName(model))
        }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch row.session.phase {
        case .needsYou: Theme.warning
        case .failed: Theme.error
        case .running: Theme.mint
        case .idle: Theme.textTertiary
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    private func shortModelName(_ name: String) -> String {
        if let idx = name.firstIndex(of: ":"), idx != name.startIndex {
            return String(name[name.index(after: idx)...])
        }
        return name
    }
}

struct PhaseDot: View {
    let phase: SessionSummary.Phase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3).padding(-3))
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch phase {
        case .needsYou: Theme.warning
        case .failed: Theme.error
        case .running: Theme.mint
        case .idle: Theme.textTertiary
        }
    }
}

struct ServerChip: View {
    let name: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon, !icon.isEmpty {
                Text(icon).font(.caption2)
            }
            Text(name)
                .font(Theme.mono(10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.surfaceElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .accessibilityLabel("Server \(name)")
    }
}

/// Grey group header for a server the last poll could not reach.
struct UnreachableHeader: View {
    let board: ServerBoard
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(board.name)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(detail)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if board.reachable == nil { return "checking…" }
        if let seen = board.lastSeen {
            return "last seen \(BoardRowView.elapsed(since: seen, now: now)) ago"
        }
        return board.lastError ?? "unreachable"
    }
}
