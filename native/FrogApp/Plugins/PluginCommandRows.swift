import Foundation
import FrogCore

/// A row to open each plugin's page and one per command its plugin.json lists, for plugins that run.
@MainActor final class PluginCommandRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model
        guard model.configuration.preferences.featureEnabled(.plugins), let runtime = model.pluginRuntime else { return [] }
        return runtime.items.filter(\.runs).flatMap { item -> [CommandBarRow] in
            guard let manifest = item.manifest else { return [] }
            let symbol = PluginSymbol.name(item.symbol)
            var rows: [CommandBarRow] = []
            if item.hasPage {
                rows.append(CommandBarRow(
                    record: SearchRecord(id: "plugin:\(item.id)", title: item.name, subtitle: "Plugin", keywords: manifest.description, symbol: symbol),
                    primary: CommandRowAction(title: "Open") { @MainActor [weak model] in model?.openPlugin(item.id) }))
            }
            for command in manifest.commands {
                rows.append(CommandBarRow(
                    record: SearchRecord(id: "plugin:\(item.id):\(command.id)", title: command.title, subtitle: "\(item.name) · Plugin",
                                         keywords: command.keywords ?? "", symbol: symbol),
                    primary: CommandRowAction(title: command.opensPage && item.hasPage ? "Open" : "Run") { @MainActor [weak model] in
                        try await model?.plugins.run(command: command.id, of: item.id)
                    }))
            }
            return rows
        }
    }
}
