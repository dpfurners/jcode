import Foundation

/// Recovers reasoning ("thinking") from history payloads.
///
/// jcode persists reasoning as a history-only trace and, when a client
/// reloads a session, inlines it into the message *content* as dim/italic
/// markdown lines of the form `*⁣escaped body⁣*  \n` (asterisk emphasis with
/// an invisible U+2063 sentinel just inside both ends — see jcode's
/// `jcode-render-core/src/reasoning.rs`). The TUI renders those literally;
/// The app splits them back out so reopened sessions show thinking in the
/// same collapsible block used while streaming.
public enum ReasoningMarkup {
    /// U+2063 INVISIBLE SEPARATOR, jcode's reasoning-line sentinel.
    public static let sentinel = "\u{2063}"

    /// Splits a history message's content into visible text and reasoning.
    /// Lines wrapped in `*⁣…⁣*` are reasoning; everything else is text.
    public static func split(content: String) -> (text: String, reasoning: String) {
        guard content.contains(sentinel) else { return (content, "") }
        var textLines: [String] = []
        var reasoningLines: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if let body = reasoningBody(of: String(line)) {
                reasoningLines.append(body)
            } else {
                textLines.append(String(line))
            }
        }
        // Trim the blank separator lines that framed the reasoning block.
        let text = textLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, reasoningLines.joined(separator: "\n"))
    }

    /// If `line` is a reasoning-markup line, returns its unescaped body.
    private static func reasoningBody(of line: String) -> String? {
        // Strip the CommonMark hard-break trailing spaces.
        var s = line
        while s.hasSuffix(" ") { s.removeLast() }
        let open = "*" + sentinel
        let close = sentinel + "*"
        guard s.hasPrefix(open), s.hasSuffix(close),
              s.count >= open.count + close.count else { return nil }
        let body = String(s.dropFirst(open.count).dropLast(close.count))
        return unescape(body)
    }

    /// Reverses jcode's `escape_reasoning_inline_markdown` (backslash-escaped
    /// inline markdown characters).
    private static func unescape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\", let next = iterator.next() {
                out.append(next)
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
