import AppKit
import SwiftUI
import FrogCore

/// Web plugins people build and share: each runs in its own sandboxed page. The runtime stays on the app model,
/// since the sidebar and the review sheet need it before this plugin starts; it runs only while this plugin does.
final class CommunityPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "community", name: "Community plugins", symbol: "puzzlepiece.extension", tint: .purple,
                                 category: .community, summary: "Plugins you build or install")

    func start() async { model.plugins.configure(enabled: true) }
    func stop() async { model.pluginRuntime?.configure(enabled: false) }

    func page() -> AnyView? { legacyPage(PluginsView(plugins: model.plugins)) }

    /// `community.<plugin id>.<name>` for every action and command of the plugins that run. Commands keep their
    /// command bar rows; these add them to shortcuts and `frog run`.
    var actions: [PluginAction] {
        guard let runtime = model.pluginRuntime else { return [] }
        return runtime.items.filter(\.runs).flatMap { item -> [PluginAction] in
            guard let manifest = item.manifest else { return [] }
            let symbol = PluginSymbol.name(item.symbol)
            let commands = manifest.commands.map { command in
                PluginAction(id: Self.actionID(item.id, command.id), title: command.title, symbol: symbol,
                             keywords: "\(item.name) \(command.keywords ?? "")", surfaces: [.shortcut, .agent]) { [weak runtime] _ in
                    guard let runtime else { throw CancellationError() }
                    try await runtime.run(command: command.id, of: item.id)
                    return .done("Sent “\(command.title)” to \(item.name).")
                }
            }
            let actions = manifest.actions.map { action in
                PluginAction(id: Self.actionID(item.id, action.id), title: action.title, symbol: symbol,
                             keywords: "\(item.name) \(action.keywords ?? "")", parameters: action.parameters.map(Self.parameter),
                             surfaces: [.shortcut, .agent]) { [weak runtime] input in
                    guard let runtime else { throw CancellationError() }
                    let answer = try await runtime.perform(action.id, of: item.id, values: input.values, text: input.text)
                    var result = ActionResult(["ok": true], text: answer.text)
                    result.json = answer.json
                    return result
                }
            }
            return commands + actions
        }
    }

    static func actionID(_ plugin: String, _ name: String) -> String { "\(info.id).\(plugin).\(name)" }

    private static func parameter(_ parameter: PluginManifestAction.Parameter) -> ActionParameter {
        let kind: ActionParameter.Kind = switch parameter.type {
        case .text: .text
        case .integer: .integer
        case .boolean: .boolean
        case .choice: .choice(parameter.choices ?? [])
        }
        return ActionParameter(name: parameter.name, kind: kind, required: parameter.required ?? false, help: parameter.help ?? "")
    }
}
