import AppKit
import FrogCore

/// Each enabled writing, explain and dictation rule, run on the app that was in front when the bar opened. The
/// subtitle and tile name the feature the rule belongs to, as every command's do. Window shortcuts are left to
/// `WindowLayoutCommandRows`, which lists every layout once.
@MainActor final class RuleCommandRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model, frontPID = context.frontPID
        // A text rule can stay out of the command bar; it still runs from its shortcut and the bubble.
        return model.configuration.rules.filter {
            $0.enabled && model.ruleFeatureEnabled($0) && ($0.category == .audio || ($0.category == .text && $0.showsInCommandBar))
        }.map { rule in
            let owner = Self.owner(of: rule)
            return CommandBarRow(record: SearchRecord(id: "rule:\(rule.id)", title: rule.action?.systemAction?.title ?? rule.name,
                                                      subtitle: owner.name, keywords: owner.name,
                                                      symbol: rule.category == .audio ? "waveform" : SelectionBubbleItems.symbol(for: rule)),
                                 primary: CommandRowAction(title: "Run") { [weak model] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message(CommandBarContext.targetChanged) }
                model?.runRuleFromCommandBar(rule.id)
            }, tint: owner.tint, rule: rule.category == .text ? rule : nil)
        }
    }

    /// The feature a rule belongs to: its name and tile colour.
    static func owner(of rule: Rule) -> (name: String, tint: PluginTint) {
        if rule.category == .audio { return ("Dictation", .red) }
        return rule.isExplainRule ? ("Explain", .teal) : ("Writing", .green)
    }
}

/// The window layouts, applied to the front window.
@MainActor final class WindowLayoutCommandRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model, frontPID = context.frontPID
        guard model.configuration.preferences.windowActionsEnabled else { return [] }
        return WindowAction.allCases.map { action in
            CommandBarRow(record: SearchRecord(id: "layout:\(action.rawValue)", title: action.title, subtitle: "Windows", keywords: "window layout arrange front window " + action.searchKeywords, symbol: "macwindow"),
                          primary: CommandRowAction(title: "Arrange") { [weak model] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message(CommandBarContext.targetChanged) }
                model?.runWindowAction(action)
            }, tint: .purple)
        }
    }
}
