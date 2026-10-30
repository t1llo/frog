import AppKit
import SwiftUI
import FrogCore

/// Writing rules: a trigger (the rule's shortcut, the selection bubble, the command bar or an agent) and an action
/// (rewrite the text with the rule's instructions and model, then replace the selection, copy or show the result).
final class WritingPlugin: LegacyPlugin, FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "writing", name: "Writing", symbol: "text.cursor", tint: .green, category: .write,
                                 summary: "Rewrite selected text with your rules", enabledByDefault: true,
                                 permissions: [.accessibility], recommended: true)
    @Published private(set) var settings = WritingConfig()
    private(set) var bubble: WritingBubble?

    func start() async {
        seed()
        settings = context.settings(WritingConfig.self)
        let bubble = WritingBubble(model: model, settings: settings.bubble)
        self.bubble = bubble
        bubble.start()
    }

    func stop() async {
        bubble?.stop()
        bubble = nil
    }

    func settingsChanged() {
        let read = context.settings(WritingConfig.self)
        guard read != settings else { return }
        settings = read
        bubble?.update(read.bubble)
    }

    func save(_ new: WritingConfig) throws {
        try new.validate()
        try context.save(new)
        settings = new
        bubble?.update(new.bubble)
    }

    /// The first start writes `[writing]` from what Explain kept for the bubble, and rules left out of the bubble
    /// say so themselves from then on.
    private func seed() {
        let legacy = model.configuration.preferences.explainSettings
        do {
            guard try model.settingsFile.seedSection(Self.info.id, { WritingConfig(legacy: legacy) }) else { return }
            let hidden = Set(legacy.bubbleHiddenRules)
            guard !hidden.isEmpty else { return }
            try model.updateRules { rules in
                for index in rules.indices where hidden.contains(rules[index].id) { rules[index].showsInBubble = false }
            }
        } catch { context.report(error) }
    }

    // MARK: Actions

    /// The rules this page lists, in their order.
    var rules: [Rule] { model.configuration.rules.filter(\.isWritingRule) }

    var actions: [PluginAction] {
        let names = rules.filter(\.enabled).map { Self.slug($0.name) }
        let rule = ActionParameter(name: "rule", kind: names.isEmpty ? .text : .choice(names), required: true,
                                   help: "The rule's name, as `writing.list` shows it")
        return [
            PluginAction(id: "writing.run", title: "Run a writing rule on text", symbol: "text.cursor", keywords: "rewrite rule",
                         parameters: [rule, ActionParameter(name: "text", help: "The text; standard input when left out")],
                         surfaces: [.agent]) { [unowned self] input in
                let rule = try self.rule(named: input.required("rule"))
                guard let text = input.value("text") ?? input.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ActionError.failed("Give the text with --text or on standard input.")
                }
                if rule.answersInPanel {
                    let answer = try await self.model.answer(text, rule: rule)
                    return ActionResult(RuleRun(rule: rule.name, result: answer, notice: nil), text: answer)
                }
                let run = try await self.model.runRule(rule.id, on: text)
                return ActionResult(RuleRun(rule: rule.name, result: run.result, notice: run.historyIssue), text: run.result)
            },
            PluginAction(id: "writing.selection", title: "Run a writing rule on the selection", symbol: "text.cursor",
                         keywords: "rewrite selected", parameters: [rule], surfaces: [.agent, .shortcut]) { [unowned self] input in
                let rule = try self.rule(named: input.required("rule"))
                self.model.runRuleFromCommandBar(rule.id)
                return .done("Running \(rule.name) on the selected text.")
            },
            PluginAction(id: "writing.list", title: "List writing rules", symbol: "list.bullet", surfaces: [.agent]) { [unowned self] _ in
                let listed = self.rules.map { ListedRule($0, model: self.model.ruleModelLabel($0)) }
                let text = listed.map { "\($0.name)\t\($0.then)\t\($0.on ? "on" : "off")\t\($0.model)" }.joined(separator: "\n")
                return ActionResult(listed, text: text.isEmpty ? "No writing rules." : text)
            },
            PluginAction(id: "writing.bubble", title: settings.bubble.on ? "Turn off the selection bubble" : "Turn on the selection bubble",
                         symbol: "text.bubble", keywords: "selection bubble popup",
                         parameters: [ActionParameter(name: "on", kind: .boolean, help: "Switches it when left out")]) { [unowned self] input in
                var new = self.settings
                new.bubble.on = try input.boolean("on") ?? !new.bubble.on
                try self.save(new)
                return .done(new.bubble.on ? "The selection bubble is on." : "The selection bubble is off.")
            },
        ]
    }

    /// A rule by its name or the slug `writing.list` shows, ignoring case.
    private func rule(named name: String) throws -> Rule {
        let wanted = Self.slug(name)
        guard let rule = rules.first(where: { Self.slug($0.name) == wanted }) else {
            throw ActionError.failed("No writing rule “\(name)”. Run `frog run writing.list` for the list.")
        }
        guard rule.enabled else { throw ActionError.failed("“\(rule.name)” is off. Turn it on on the Writing page first.") }
        return rule
    }

    nonisolated static func slug(_ name: String) -> String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }

    private struct RuleRun: Encodable {
        let rule: String
        let result: String
        let notice: String?
    }

    private struct ListedRule: Encodable {
        let name: String
        let slug: String
        let on: Bool
        let then: String
        let shortcut: String?
        let bubble: Bool
        let commandBar: Bool
        let model: String
        init(_ rule: Rule, model: String) {
            name = rule.name; slug = WritingPlugin.slug(rule.name); on = rule.enabled
            then = rule.textOutput.rawValue == "panel" ? "show" : rule.textOutput.rawValue
            shortcut = rule.hotkey.flatMap { (try? Shortcut($0))?.description }
            bubble = rule.showsInBubble; commandBar = rule.showsInCommandBar; self.model = model
        }
    }

    func page() -> AnyView? { AnyView(WritingView(plugin: self).environmentObject(model)) }
}

/// Explain: select text anywhere, press the shortcut or pick Explain in the bubble, and read the answer in a panel.
final class ExplainPlugin: LegacyPlugin, FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "explain", name: "Explain", symbol: "questionmark.bubble", tint: .teal, category: .write,
                                 summary: "Ask about selected text", permissions: [.accessibility])
    @Published private(set) var settings = ExplainConfig()

    func start() async {
        let legacy = model.configuration.preferences.explainSettings
        do { try model.settingsFile.seedSection(Self.info.id) { ExplainConfig(legacy: legacy) } } catch { context.report(error) }
        settings = context.settings(ExplainConfig.self)
        model.adoptExplainPresetIfNeeded()
    }

    func stop() async {}

    func settingsChanged() {
        let read = context.settings(ExplainConfig.self)
        if read != settings { settings = read }
    }

    func save(_ new: ExplainConfig) throws {
        try new.validate()
        try context.save(new)
        settings = new
    }

    /// The rule Frog added for Explain; nil after the person deleted it.
    var rule: Rule? { model.configuration.rules.first(where: \.isExplainRule) }

    /// Adds the Explain rule again, with the newest text model still available.
    func addRule() throws {
        var rule = Rule.explainPreset
        model.configuration.recentModels?.last { $0.category == .text && model.configuration.selectionAvailable($0, installed: model.localModels.installed) }?
            .apply(to: &rule)
        try model.saveRule(rule)
    }

    var actions: [PluginAction] {
        [
            PluginAction(id: "explain.selection", title: "Explain the selection", symbol: "questionmark.bubble",
                         keywords: "explain answer selected define", surfaces: [.agent, .shortcut]) { [unowned self] _ in
                guard let rule = self.rule, rule.enabled else { throw ActionError.failed(Self.noRule) }
                self.model.runRuleFromCommandBar(rule.id)
                return .done("Explaining the selected text.")
            },
            PluginAction(id: "explain.text", title: "Explain text", symbol: "questionmark.bubble", keywords: "explain answer",
                         parameters: [ActionParameter(name: "text", help: "The text; standard input when left out"),
                                      ActionParameter(name: "context", help: "The sentence or paragraph around it")],
                         surfaces: [.agent]) { [unowned self] input in
                guard let rule = self.rule, rule.enabled else { throw ActionError.failed(Self.noRule) }
                guard let text = input.value("text") ?? input.text else { throw ActionError.failed("Give the text with --text or on standard input.") }
                let answer = try await self.model.answer(text, rule: rule, context: self.settings.context ? input.value("context") : nil)
                return ActionResult(["answer": answer], text: answer)
            },
        ]
    }

    private static let noRule = "Explain has no rule. Add it on the Explain page."

    func page() -> AnyView? { AnyView(ExplainView(plugin: self).environmentObject(model)) }
}

/// Saved results of rules, answers and dictation. Others record through `AppModel.recordHistory`.
final class HistoryPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "history", name: "History", symbol: "clock.arrow.circlepath", tint: .gray, category: .write,
                                 summary: "Earlier results of your rules")

    func page() -> AnyView? { legacyPage(HistoryView()) }

    var actions: [PluginAction] {
        [
            PluginAction(id: "history.list", title: "List history", symbol: "clock.arrow.circlepath",
                         parameters: [ActionParameter(name: "search", help: "Words the entry contains"),
                                      ActionParameter(name: "kind", kind: .choice(["text", "answers", "audio"]), help: "Only this kind"),
                                      ActionParameter(name: "limit", kind: .integer, help: "At most this many, newest first (20)")],
                         surfaces: [.agent]) { [unowned self] input in
                let kind = input.value("kind").flatMap(HistoryFilter.init(rawValue:))
                let limit = try input.integer("limit") ?? 20
                guard limit > 0 else { throw ActionError.invalid("limit", "a number above 0") }
                let entries = self.model.historyEntries(search: input.value("search") ?? "", kind: kind, limit: limit)
                let hidden = self.model.configuration.preferences.hideHistoryText
                let listed = entries.map { ListedEntry($0, hidden: hidden) }
                let text = listed.map { "\(AgentCommands.shortTime($0.time))  \($0.rule)\n\($0.result ?? "(hidden)")" }
                    .joined(separator: "\n\n")
                return ActionResult(listed, text: text.isEmpty ? "No history." : text)
            },
            PluginAction(id: "history.delete", title: "Delete a history entry", symbol: "trash",
                         parameters: [ActionParameter(name: "id", required: true, help: "The entry's id, as history.list shows it")],
                         surfaces: [.agent]) { [unowned self] input in
                guard let id = UUID(uuidString: try input.required("id")), self.model.history.contains(where: { $0.id == id }) else {
                    throw ActionError.failed("No history entry with that id.")
                }
                try self.model.deleteHistory(id: id)
                return .done("Deleted.")
            },
            PluginAction(id: "history.clear", title: "Clear history", symbol: "trash", keywords: "delete history",
                         surfaces: [.agent]) { [unowned self] _ in
                let count = self.model.history.count
                try self.model.clearHistory()
                return .done(count == 1 ? "Deleted 1 entry." : "Deleted \(count) entries.")
            },
        ]
    }

    /// One entry for agents. With Hide history text on, the texts stay in Frog.
    private struct ListedEntry: Encodable {
        let id: UUID
        let time: Date
        let kind: String
        let rule: String
        let model: String
        let original: String?
        let result: String?
        init(_ entry: HistoryEntry, hidden: Bool) {
            id = entry.id; time = entry.timestamp; rule = entry.ruleName; model = entry.model
            kind = entry.kind.rawValue
            original = hidden ? nil : entry.originalText
            result = hidden ? nil : entry.processedText
        }
    }
}
