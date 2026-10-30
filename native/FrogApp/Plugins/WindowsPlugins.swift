import AppKit
import SwiftUI
import FrogCore

final class WindowsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "windows", name: "Windows", symbol: "rectangle.split.2x1", tint: .purple, category: .windows,
                                 summary: "Snap and tile windows with keys", permissions: [.accessibility], recommended: true)
    func page() -> AnyView? { legacyPage(WindowsView()) }
    var actions: [PluginAction] {
        WindowAction.allCases.map { action in
            PluginAction(id: "windows.\(WritingPlugin.slug(action.title))", title: action.title, symbol: "rectangle.split.2x1",
                         keywords: "window layout move resize", surfaces: [.shortcut, .agent]) { [model] _ in
                model.runWindowAction(action); return .done()
            }
        }
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "windows.arrange", order: 40) { [model] in
            guard model.windowLayout.pickerAvailable else { return AnyView(EmptyView()) }
            return AnyView(MenuActionRow(title: "Arrange window…", symbol: "rectangle.split.2x1", closes: true) {
                model.windowLayout.handle(.layoutPicker, pressed: true)
            })
        }]
    }
}

final class WindowSwitcherPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "window-switcher", name: "Window switcher", symbol: "macwindow.on.rectangle", tint: .indigo,
                                 category: .windows, summary: "Switch between windows, not apps", enabledByDefault: true,
                                 permissions: [.accessibility], recommended: true)
    func page() -> AnyView? { legacyPage(WindowSwitcherView()) }
}
