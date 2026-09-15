import JCodeKit
import SwiftUI

/// New session: pick a server, then a project from its recent working
/// directories (pins first, as the server orders them), or type an absolute
/// path with server-side completion (`search_files` with `dirs_only`).
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var serverID: String?
    @State private var path = ""
    @State private var completions: [FileMatch] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                serverSection
                if let server {
                    projectsSection(server)
                    pathSection(server)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listStyle(.insetGrouped)
            .listRowSeparatorTint(Theme.border)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start(path) }
                        .disabled(server == nil || !path.hasPrefix("/"))
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if serverID == nil {
                serverID = model.servers.first { model.board.board(for: $0.id)?.reachable == true }?.id
                    ?? model.servers.first?.id
            }
        }
        .onChange(of: path) { _, value in schedulePathSearch(value) }
    }

    private var server: ServerCredential? {
        model.servers.first { $0.id == serverID }
    }

    private var serverSection: some View {
        Section("Server") {
            ForEach(model.servers) { candidate in
                let board = model.board.board(for: candidate.id)
                let isActive = candidate.id == serverID
                Button {
                    serverID = candidate.id
                    completions = []
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(board?.name ?? candidate.serverName)
                                .font(.body)
                                .foregroundStyle(Theme.textPrimary)
                            Text(board?.reachable == false ? "unreachable" : candidate.host)
                                .font(Theme.mono(11))
                                .foregroundStyle(board?.reachable == false ? Theme.error : Theme.textTertiary)
                        }
                        Spacer()
                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Theme.mint)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
    }

    private func projectsSection(_ server: ServerCredential) -> some View {
        let projects = model.board.board(for: server.id)?.recentProjects ?? []
        return Section("Recent projects") {
            if projects.isEmpty {
                Text("None reported yet")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .listRowBackground(Theme.surface)
            }
            ForEach(projects) { project in
                Button {
                    start(project.path)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.path.split(separator: "/").last.map(String.init) ?? project.path)
                                .font(.body)
                                .foregroundStyle(Theme.textPrimary)
                            Text(project.path)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        if project.sessionCount > 0 {
                            Text("\(project.sessionCount)")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityLabel("\(project.sessionCount) sessions")
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityHint("Starts a session in this project")
            }
        }
    }

    private func pathSection(_ server: ServerCredential) -> some View {
        Section("Or a path") {
            TextField("/absolute/path", text: $path)
                .font(Theme.mono(14))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.mint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { if path.hasPrefix("/") { start(path) } }
                .listRowBackground(Theme.surface)
                .accessibilityLabel("Project path")
            ForEach(completions) { match in
                Button {
                    path = match.path.hasSuffix("/") ? match.path : match.path + "/"
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                        Text(match.path)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityHint("Fills the path field")
            }
        }
    }

    /// One `search_files` per keystroke pause (300 ms), absolute mode.
    private func schedulePathSearch(_ value: String) {
        searchTask?.cancel()
        guard let server, value.hasPrefix("/") else {
            completions = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let matches = await model.board.searchDirectories(on: server, prefix: value)
            guard !Task.isCancelled else { return }
            completions = matches.filter { $0.path != value.trimmingCharacters(in: ["/"]) && $0.path != value }
        }
    }

    private func start(_ dir: String) {
        guard let server else { return }
        let trimmed = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        model.startSession(on: server, workingDir: trimmed)
        dismiss()
    }
}
