import FrogCore

/// Plugin actions in the command bar. One that needs nothing typed runs at once; one with a single required
/// parameter asks for it in the search field, offering the choices when it has them. Actions that need more
/// stay with `frog run` and shortcuts.
@MainActor final class PluginActionRows: CommandBarRowProviding {
    private let actions: (@MainActor (PluginHost) -> [PluginAction])?

    init(actions: (@MainActor (PluginHost) -> [PluginAction])? = nil) { self.actions = actions }

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let host = context.model.pluginHost
        return (actions?(host) ?? host.actions).filter { $0.surfaces.contains(.commandBar) }.compactMap { action in
            let required = action.parameters.filter(\.required)
            guard required.count <= 1 else { return nil }
            let plugin = host.descriptor(action.pluginID)?.info.name ?? "Frog"
            let record = SearchRecord(id: "action:\(action.id)", title: action.title, subtitle: plugin,
                                      keywords: "\(plugin) \(action.keywords)", symbol: action.symbol)
            // Through the host, which checks the values, unless the actions were handed in.
            let run: @MainActor (ActionInput) async throws -> Void = actions == nil
                ? { [weak host, id = action.id] input in _ = try await host?.run(id, input) }
                : { input in _ = try await action.run(input) }
            guard let parameter = required.first else {
                return CommandBarRow(record: record, primary: CommandRowAction(title: "Run") { try await run(ActionInput(source: .commandBar)) })
            }
            let prompt = CommandRowPrompt(placeholder: parameter.help.isEmpty ? parameter.name.capitalized : parameter.help,
                                          options: Self.options(parameter.kind)) { value in
                try await run(ActionInput(values: [parameter.name: value], source: .commandBar))
            }
            return CommandBarRow(record: record, primary: CommandRowAction(title: "Run", prompt: prompt) {})
        }
    }

    static func options(_ kind: ActionParameter.Kind) -> [String] {
        switch kind {
        case .choice(let options): options
        case .boolean: ["on", "off"]
        case .text, .integer: []
        }
    }
}
