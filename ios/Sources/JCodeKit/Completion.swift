import Foundation

/// Composer completion: `/skill` and `@path` tokens.
///
/// Pure functions over the draft string so the popup logic is unit tested;
/// the view only renders `rows` and calls `apply`.
public enum Completion {
    public static let builtinCommands = ["model", "compact", "clear", "rename", "cancel"]

    public enum Kind: String, Equatable, Sendable {
        case slash
        case file
    }

    /// The token under the cursor (end of draft) that wants completion.
    public struct Token: Equatable, Sendable {
        public var kind: Kind
        /// Text after the sigil.
        public var query: String
        /// Range of the whole token (sigil included) in the draft.
        public var range: Range<String.Index>
    }

    /// Finds a `/` or `@` token at the end of `draft`. `/` only counts at the
    /// start of a whitespace-delimited token; `@` likewise. Whitespace after
    /// the token means the user moved on: no completion.
    public static func token(in draft: String) -> Token? {
        guard let last = draft.last, !last.isWhitespace else { return nil }
        var start = draft.endIndex
        while start > draft.startIndex {
            let prev = draft.index(before: start)
            if draft[prev].isWhitespace { break }
            start = prev
        }
        let word = draft[start...]
        guard let sigil = word.first else { return nil }
        let kind: Kind
        switch sigil {
        case "/": kind = .slash
        case "@": kind = .file
        default: return nil
        }
        return Token(kind: kind, query: String(word.dropFirst()), range: start..<draft.endIndex)
    }

    /// Slash rows: installed skills plus builtins, prefix-filtered,
    /// case-insensitive, deduplicated, skills first in their server order.
    public static func slashRows(skills: [String], query: String) -> [String] {
        var seen = Set<String>()
        let all = skills + builtinCommands
        let q = query.lowercased()
        return all.filter { name in
            guard seen.insert(name.lowercased()).inserted else { return false }
            return q.isEmpty || name.lowercased().hasPrefix(q)
        }
    }

    /// Replaces the token with `/name ` or `@path ` (trailing space so the
    /// next keystroke starts a new word).
    public static func apply(_ token: Token, replacement: String, to draft: String) -> String {
        let sigil = token.kind == .slash ? "/" : "@"
        return draft.replacingCharacters(in: token.range, with: sigil + replacement + " ")
    }

    /// The skill a message activates: a leading `/name` token whose name is
    /// an installed skill. Builtins are not skills.
    public static func activeSkill(in message: String, skills: [String]) -> String? {
        guard message.hasPrefix("/") else { return nil }
        let name = message.dropFirst().prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        return skills.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
