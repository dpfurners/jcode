import Foundation
import JCodeKit

#if DEBUG
/// Harness-only mirror of what the app shows, for `phone-sync-check.sh`.
///
/// Enabled when the process environment has `JCODE_SYNC_DUMP=1`
/// (`SIMCTL_CHILD_JCODE_SYNC_DUMP=1 xcrun simctl launch …`). Writes
/// `Documents/sync-dump.json` once on launch and then after every board,
/// reducer or composer change, coalesced to at most 4 writes per second and
/// written atomically (temp file + rename). Compiled out of release builds.
@MainActor
enum SyncDumpWriter {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["JCODE_SYNC_DUMP"] == "1"
    }

    static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sync-dump.json")

    /// Observes `model` until the task is cancelled. Each change schedules
    /// one write 250 ms later; further changes in that window fold into it.
    static func start(model: AppModel) -> Task<Void, Never> {
        Task {
            write(model)
            while !Task.isCancelled {
                await changed(model)
                try? await Task.sleep(for: .milliseconds(250))
                write(model)
            }
        }
    }

    /// Resumes after the next mutation of anything the dump reads.
    private static func changed(_ model: AppModel) async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = snapshot(model)
            } onChange: {
                continuation.resume()
            }
        }
    }

    private static func snapshot(_ model: AppModel) -> (
        [SyncDump.Server], SessionState?, SyncDump.Completion
    ) {
        let servers = model.servers.map { credential in
            SyncDump.Server(
                board: model.board.board(for: credential.id)
                    ?? ServerBoard(serverID: credential.id, name: credential.serverName),
                host: credential.host)
        }
        let completion = SyncDump.Completion(
            kind: model.completion.kind.rawValue, rows: model.completion.rows)
        return (servers, model.isAttached ? model.session : nil, completion)
    }

    private static func write(_ model: AppModel) {
        let (servers, attached, completion) = snapshot(model)
        guard let data = try? SyncDump.data(servers: servers, attached: attached, completion: completion)
        else { return }
        let temp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".sync-dump.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
#endif
