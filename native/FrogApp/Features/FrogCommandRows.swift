import AppKit
import FrogCore

/// Frog's own places: each plugin's page, the Plugins page, Settings, Models and History.
@MainActor final class FrogPageRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model
        // Record IDs keep the feature names they had before plugins, so learned choices still count.
        var rows = model.pluginHost.sidebar.flatMap(\.plugins).map { plugin in
            let id = BuiltinPlugins.legacyFeatures[plugin.id].map { "feature:\($0.rawValue)" } ?? "plugin-page:\(plugin.id)"
            return CommandBarRow(record: SearchRecord(id: id, title: plugin.name, subtitle: "Frog", keywords: "frog plugin \(plugin.summary)", symbol: plugin.symbol),
                                 primary: CommandRowAction(title: "Open") { [weak model] in model?.pluginHost.open(plugin.id) })
        }
        rows.append(CommandBarRow(record: SearchRecord(id: "features", title: "Plugins", subtitle: "Frog", keywords: "frog features manage turn on off", symbol: "puzzlepiece.extension"),
                                  primary: CommandRowAction(title: "Open") { [weak model] in model?.toolkit.select(.features); model?.showSettings() }))
        for (route, title, symbol) in [(ToolkitRoute.settings, "Settings", "gearshape"), (.models, "Models", "cpu"), (.history, "History", "clock.arrow.circlepath")] {
            rows.append(CommandBarRow(record: SearchRecord(id: "route:\(title)", title: title, subtitle: "Frog", keywords: "frog preferences configuration", symbol: symbol),
                                      primary: CommandRowAction(title: "Open") { [weak model] in model?.toolkit.select(route); model?.showSettings() }))
        }
        return rows
    }
}

/// Small tools that work on the clipboard and copy their result.
@MainActor final class TextToolRows: CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let copy = context.copy, pasteboard = context.pasteboard
        func row(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ run: @escaping () throws -> Void) -> CommandBarRow {
            CommandBarRow(record: SearchRecord(id: "quick:\(id)", title: title, subtitle: subtitle, symbol: symbol),
                          primary: CommandRowAction(title: "Copy") { try run() })
        }
        return [
            row("uuid", "Generate UUID", "Copy a new UUID", "number") { copy(UUID().uuidString) },
            row("url", "Clean clipboard URL", "Remove tracking parameters and copy", "link") {
                guard let cleaned = LinkCleaning.clean(pasteboard.string(forType: .string) ?? "") else { throw FrogError.message("Copy an HTTP or HTTPS URL first.") }
                copy(cleaned)
            },
            row("base64-encode", "Base64 encode clipboard", "Copy the clipboard text as Base64", "lock.doc") {
                guard let text = pasteboard.string(forType: .string), !text.isEmpty else { throw FrogError.message("Copy some text first.") }
                guard !pasteboard.holdsSensitiveText else { throw FrogError.message("The clipboard holds text marked as sensitive.") }
                copy(Base64Text.encoded(text))
            },
            row("base64-decode", "Base64 decode clipboard", "Copy the decoded text", "lock.open") {
                guard let decoded = Base64Text.decoded(pasteboard.string(forType: .string) ?? ""), !decoded.isEmpty else {
                    throw FrogError.message("The clipboard does not hold Base64 text.")
                }
                copy(decoded)
            }
        ]
    }
}
