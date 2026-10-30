import AppKit
import SwiftUI
import FrogCore

final class NotesPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "notes", name: "Notes", symbol: "note.text", tint: .yellow, category: .navigate,
                                 summary: "Markdown notes and text to paste")
    func page() -> AnyView? { legacyPage(UtilityDocumentsView(documents: model.documents, kind: .note)) }
}

final class ScriptsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "scripts", name: "Scripts", symbol: "terminal", tint: .gray, category: .navigate,
                                 summary: "Run your shell scripts")
    func page() -> AnyView? { legacyPage(UtilityDocumentsView(documents: model.documents, kind: .script)) }
}
