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
