import FrogCore

/// Plugin actions in the command bar: those that need nothing typed, such as "Stay awake on or off".
@MainActor final class PluginActionRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let host = context.model.pluginHost
        return host.actions.filter { $0.surfaces.contains(.commandBar) && !$0.parameters.contains(where: \.required) }.map { action in
            let plugin = host.descriptor(action.pluginID)?.info.name ?? "Frog"
            return CommandBarRow(
                record: SearchRecord(id: "action:\(action.id)", title: action.title, subtitle: plugin,
                                     keywords: "\(plugin) \(action.keywords)", symbol: action.symbol),
                primary: CommandRowAction(title: "Run") { [weak host] in
                    _ = try await host?.run(action.id, ActionInput(source: .commandBar))
                })
        }
    }
}
