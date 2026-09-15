import Foundation

#if DEBUG
/// Harness-only side door for `jcode://` URLs.
///
/// `xcrun simctl openurl` triggers SpringBoard's "Open in jcode?" sheet, which
/// no script can confirm. Debug builds therefore also poll
/// `<container>/tmp/jcode-debug-url` (written via `simctl get_app_container`)
/// and feed every line through the same handler as `onOpenURL`. Compiled out
/// of release builds; the production path stays the real deep link.
@MainActor
enum DebugURLChannel {
    static let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("jcode-debug-url")

    /// Harness actions that stand in for UI automation (DEBUG only):
    /// - `jcode://debug/answer?request_id=…&text=…` answers the pending
    ///   prompt through the same path as the prompt card's Send.
    /// - `jcode://debug/compose?text=…` sets the composer draft so the
    ///   completion popup (and the sync dump's `completion`) computes.
    /// Returns true when the URL was a debug action.
    static func handleDebugAction(_ url: URL, model: AppModel) -> Bool {
        guard url.scheme?.lowercased() == "jcode", url.host?.lowercased() == "debug",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.path {
        case "/answer":
            guard let text = value("text") else { return true }
            if let wanted = value("request_id"), !wanted.isEmpty,
                model.session.pendingPrompt?.requestID != wanted
            {
                return true
            }
            model.answerPrompt(text)
        case "/compose":
            model.draft = value("text") ?? ""
        default:
            break
        }
        return true
    }

    static func start(handler: @escaping @MainActor (URL) -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: fileURL),
                    let text = String(data: data, encoding: .utf8)
                {
                    try? FileManager.default.removeItem(at: fileURL)
                    for line in text.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if let url = URL(string: trimmed) { handler(url) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
#endif
