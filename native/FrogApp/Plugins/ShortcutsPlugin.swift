import AppKit
import SwiftUI
import FrogCore

final class ShortcutsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "shortcuts", name: "Shortcuts", symbol: "command", tint: .blue, category: .navigate,
                                 summary: "Keys that open apps and run actions", enabledByDefault: true, recommended: true)
    func page() -> AnyView? { legacyPage(RulesView(applications: true)) }
    var actions: [PluginAction] {
        [PluginAction(id: "shortcuts.open-app", title: "Open an app", symbol: "app",
                      parameters: [ActionParameter(name: "app", required: true, help: "The app's name or bundle ID")],
                      surfaces: [.agent]) { input in
            let name = try input.required("app")
            let workspace = NSWorkspace.shared
            let url = workspace.urlForApplication(withBundleIdentifier: name)
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities"].lazy
                    .map { URL(fileURLWithPath: $0).appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url else { throw ActionError.failed("No app named \(name).") }
            _ = try await workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return .done("Opened \(url.deletingPathExtension().lastPathComponent).")
        }]
    }
}
