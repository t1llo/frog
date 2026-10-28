import Foundation
import FrogCore

/// Text in and out: the clipboard and its history, and Writing rules run on text.
extension AgentCommands {
    static var textTools: [AgentCommand] { clipboard + rules }

    private static var clipboard: [AgentCommand] {
        [
            AgentCommand(words: ["clipboard", "list"], arguments: "[--limit N]", summary: "Text you copied recently, newest first.",
                         details: """
                         Shows the last 20 items, or as many as --limit gives, up to \(ClipboardHistoryStore.capacity). Text an app \
                         marked as sensitive, and text that looks like a password, API key, token or private key, stays hidden, also \
                         with --json, which names its kind.

                         Example: frog clipboard list --limit 5
                         """, options: ["limit"], feature: .clipboard) { call in
                let limit = try call.integer("limit", default: 20, in: 1...ClipboardHistoryStore.capacity)
                let items = call.model.clipboardHistoryStore.entries.prefix(limit).map(ClipboardItem.init)
                let rows = items.map { [shortTime($0.copied), $0.text.map { preview($0, length: 80) } ?? "\($0.kind ?? "Sensitive text"), hidden"] }
                return AgentResult(items, text: items.isEmpty ? "Nothing copied yet." : AgentTable.render(rows))
            },
            AgentCommand(words: ["clipboard", "copy"], arguments: "<text>", summary: "Put text on the clipboard.",
                         details: """
                         The text comes as arguments, from --text, or from standard input with --stdin.

                         Examples:
                           frog clipboard copy "See you at 10"
                           git rev-parse HEAD | frog clipboard copy --stdin
                         """, options: ["text"]) { call in
                let text = try call.text(from: 0)
                guard !text.isEmpty else { throw AgentCommandError.usage("There is no text to copy.") }
                let history = call.model.clipboardHistoryStore
                guard ClipboardHistoryEntry(text: text).write(to: history.pasteboard, plainText: true) else {
                    throw AgentCommandError.failed("Could not copy the text.")
                }
                history.recordCopiedText(text)
                return .done("Copied.")
            }
        ]
    }

    private static var rules: [AgentCommand] {
        [
            AgentCommand(words: ["rules", "list"], summary: "Your Writing rules, and the model each one uses.", feature: .writing) { call in
                let rules = writingRules(call.model).map { WritingRule(id: $0.id, name: $0.name, on: $0.enabled, model: call.model.ruleModelLabel($0)) }
                let rows = rules.map { [$0.on ? "on" : "off", $0.name, $0.model] }
                return AgentResult(rules, text: rules.isEmpty ? "No Writing rules yet." : AgentTable.render(rows))
            },
            AgentCommand(words: ["rules", "run"], arguments: "<rule> <text>", summary: "Run a Writing rule on text and print the result.",
                         details: """
                         The text follows the rule's name, comes from --text, or from standard input with --stdin. Nothing is \
                         pasted or copied. History keeps the run while it is on, as it keeps any other.

                         Examples:
                           frog rules run Proofread "Thank you for you're help"
                           pbpaste | frog rules run "Polish email" --stdin
                         """, options: ["text"], feature: .writing) { call in
                let rule = try item(named: try call.argument(0, "rule"), in: writingRules(call.model), kind: "Writing rule",
                                    list: "frog rules list", id: { $0.id.uuidString }, title: \.name)
                guard rule.enabled else { throw AgentCommandError.failed("“\(rule.name)” is off. Turn it on on the Writing page first.") }
                let text = try call.text(from: 1)
                let run = try await call.model.runRule(rule.id, on: text)
                var result = AgentResult(RuleRun(rule: rule.name, result: run.result), text: run.result)
                result.notice = run.historyIssue ?? ""
                return result
            }
        ]
    }

    /// The rules on the Writing page: text rules that replace the selection, not Explain's answers.
    private static func writingRules(_ model: AppModel) -> [Rule] {
        model.configuration.rules.filter { $0.category == .text && !$0.answersInPanel }
    }

    /// The time for today, the day and time before.
    nonisolated static func shortTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// One clipboard item. Sensitive text is left out, not masked, so nothing of it leaves Frog.
    private struct ClipboardItem: Encodable {
        let copied: Date
        let sensitive: Bool
        /// "API key", "Password" and the like, for text that looks like one.
        let kind: String?
        let text: String?
        init(_ entry: ClipboardHistoryEntry) {
            copied = entry.timestamp; sensitive = entry.isSensitive; kind = entry.secret?.label
            text = entry.isSensitive ? nil : entry.text
        }
    }

    private struct WritingRule: Encodable {
        let id: UUID
        let name: String
        let on: Bool
        let model: String
    }

    private struct RuleRun: Encodable {
        let rule: String
        let result: String
    }
}
