import AppKit
import FrogCore

/// Each enabled writing, explain and dictation rule, run on the app that was in front when the bar opened.
@MainActor final class RuleCommandRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model, frontPID = context.frontPID
        // A text rule can stay out of the command bar; it still runs from its shortcut and the bubble.
        return model.configuration.rules.filter {
            $0.enabled && model.ruleFeatureEnabled($0) && $0.category != .application && $0.category != .system && ($0.category != .text || $0.showsInCommandBar)
        }.map { rule in
            CommandBarRow(record: SearchRecord(id: "rule:\(rule.id)", title: rule.action?.systemAction?.title ?? rule.name,
                                               subtitle: rule.answersInPanel ? "Shows the answer in a panel" : "Run \(rule.category.title.lowercased()) rule",
                                               symbol: rule.category == .audio ? "waveform" : "command"),
                          primary: CommandRowAction(title: "Run") { [weak model] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message(CommandBarContext.targetChanged) }
                model?.runRuleFromCommandBar(rule.id)
            })
        }
    }
}

/// The window layouts, applied to the front window.
@MainActor final class WindowLayoutCommandRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model, frontPID = context.frontPID
        guard model.configuration.preferences.windowActionsEnabled else { return [] }
        return WindowAction.allCases.map { action in
            CommandBarRow(record: SearchRecord(id: "layout:\(action.rawValue)", title: action.title, subtitle: "Arrange front window", keywords: "window layout", symbol: "macwindow"),
                          primary: CommandRowAction(title: "Arrange") { [weak model] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message(CommandBarContext.targetChanged) }
                model?.runWindowAction(action)
            })
        }
    }
}
