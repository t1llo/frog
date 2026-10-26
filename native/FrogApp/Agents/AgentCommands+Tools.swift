import Foundation
import FrogCore

/// Frog's tools: scripts, snippets, notes, shelf, clipboard, writing rules, Stay awake,
/// System monitor and Mr. Usage. Each area has a file of its own; `tools` joins them.
extension AgentCommands {
    static var tools: [AgentCommand] { documentTools + textTools + systemTools }

    /// The item a name means: the one with that exact name or id, else the one with that name in any
    /// case, else the only one whose name starts with it. Anything else is a usage error that names
    /// the close matches.
    static func item<Item>(named name: String, in items: [Item], kind: String, list: String,
                           id: (Item) -> String? = { _ in nil }, title: (Item) -> String) throws -> Item {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { throw AgentCommandError.usage("Give the name of a \(kind).") }
        let steps = [
            items.filter { title($0) == wanted || id($0)?.caseInsensitiveCompare(wanted) == .orderedSame },
            items.filter { title($0).caseInsensitiveCompare(wanted) == .orderedSame },
            items.filter { title($0).lowercased().hasPrefix(wanted.lowercased()) }
        ]
        for matches in steps where !matches.isEmpty {
            guard matches.count == 1 else {
                throw AgentCommandError.usage("“\(wanted)” matches more than one \(kind): \(names(matches.map(title))). Use more of the name, or the id from `\(list) --json`.")
            }
            return matches[0]
        }
        let close = items.map(title).filter { $0.localizedCaseInsensitiveContains(wanted) }
        if close.isEmpty { throw AgentCommandError.usage("No \(kind) named “\(wanted)”. Run `\(list)` for the names.") }
        throw AgentCommandError.usage("No \(kind) named “\(wanted)”. Did you mean \(names(close))?")
    }

    /// Up to five names in quotes, such as “Deploy”, “Debug” and 2 more.
    private static func names(_ titles: [String]) -> String {
        let shown = titles.prefix(5).map { "“\($0.isEmpty ? "Untitled" : $0)”" }
        let more = titles.count > shown.count ? " and \(titles.count - shown.count) more" : ""
        return shown.joined(separator: ", ") + more
    }

    /// The first line with something on it, shortened for a table.
    nonisolated static func preview(_ text: String, length: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > length ? String(line.prefix(length - 1)) + "…" : line
    }
}
