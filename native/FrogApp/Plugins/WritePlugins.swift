import AppKit
import SwiftUI
import FrogCore

final class WritingPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "writing", name: "Writing", symbol: "text.cursor", tint: .green, category: .write,
                                 summary: "Rewrite selected text with your rules", enabledByDefault: true,
                                 permissions: [.accessibility], recommended: true)
    func page() -> AnyView? { legacyPage(RulesView(fixedCategory: .text)) }
    var actions: [PluginAction] {
        model.configuration.rules.filter { $0.enabled && $0.category == .text && !$0.answersInPanel }.map { rule in
            PluginAction(id: "writing.\(Self.slug(rule.name))", title: rule.name, symbol: "text.cursor",
                         keywords: "writing rule", surfaces: [.agent]) { [model] _ in
                model.runRuleFromCommandBar(rule.id)
                return .done("Running \(rule.name) on the selected text.")
            }
        }
    }
    static func slug(_ name: String) -> String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }
}

final class ExplainPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "explain", name: "Explain", symbol: "questionmark.bubble", tint: .teal, category: .write,
                                 summary: "Ask about selected text", permissions: [.accessibility])
    func page() -> AnyView? { legacyPage(ExplainView()) }
}

final class HistoryPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "history", name: "History", symbol: "clock.arrow.circlepath", tint: .gray, category: .write,
                                 summary: "Earlier results of your rules")
    func page() -> AnyView? { legacyPage(HistoryView()) }
}
