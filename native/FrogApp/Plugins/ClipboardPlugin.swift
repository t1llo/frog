import AppKit
import SwiftUI
import FrogCore

final class ClipboardPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "clipboard", name: "Clipboard", symbol: "doc.on.clipboard", tint: .orange, category: .navigate,
                                 summary: "Search and paste what you copied", recommended: true)
    func page() -> AnyView? { legacyPage(ClipboardView()) }
    var actions: [PluginAction] {
        [PluginAction(id: "clipboard.show", title: "Clipboard history", symbol: "doc.on.clipboard", surfaces: [.commandBar, .shortcut, .agent]) { [model] _ in
            model.showClipboardHistory(); return .done()
        }]
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "clipboard.open", order: 21) { [model] in
            AnyView(MenuActionRow(title: "Clipboard history", symbol: "clipboard",
                                  key: HotkeyManager.display(model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey),
                                  closes: true) {
                model.showClipboardHistory()
            })
        }]
    }
}
