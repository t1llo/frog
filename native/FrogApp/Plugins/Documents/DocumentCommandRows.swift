import AppKit
import FrogCore

/// A row per note and script for the command bar, once the store is read. A note that pastes pastes into the field
/// that had focus when the bar opened (⌘↩ copies it); another note opens on its page; a script runs on its page.
/// Record IDs keep the names they had before plugins, so the choices the bar learned still count.
@MainActor enum DocumentCommandRows {
    static func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model
        let notes = model.pluginEnabled(NotesPlugin.info.id), scripts = model.pluginEnabled(ScriptsPlugin.info.id)
        let paste = NotePaste(pasteboard: context.pasteboard) { [weak model] in model?.statistics.recordToolUse(.snippetCopy) }
        return model.documents.items.compactMap { item in
            switch item.kind {
            case .note where item.pastes:
                guard notes else { return nil }
                return pasteRow(item, paste: paste, context: context)
            case .note:
                guard notes else { return nil }
                return CommandBarRow(record: SearchRecord(id: "note:\(item.id)", title: item.title, subtitle: "Notes",
                                                          keywords: String(item.text.prefix(512)), symbol: "note.text"),
                                     primary: CommandRowAction(title: "Open") { [weak model] in
                                         model?.documents.selection[.note] = item.id
                                         model?.pluginHost.open(NotesPlugin.info.id)
                                     })
            case .script:
                guard scripts else { return nil }
                return CommandBarRow(record: SearchRecord(id: "script:\(item.id)", title: item.title, subtitle: "Run saved script", symbol: "terminal"),
                                     primary: CommandRowAction(title: "Run") { [weak model] in
                                         (model?.pluginHost.running[ScriptsPlugin.info.id] as? ScriptsPlugin)?.runOnPage(item)
                                     })
            }
        }
    }

    private static func pasteRow(_ item: UtilityDocument, paste: NotePaste, context: CommandBarContext) -> CommandBarRow {
        let model = context.model, target = context.pasteTarget, waitForRelease = context.waitForRelease
        // The note may have changed or stopped pasting while the bar was open, or Notes been turned off.
        let current: () -> UtilityDocument? = { [weak model] in
            guard let model, model.pluginEnabled(NotesPlugin.info.id) else { return nil }
            return model.documents.items.first { $0.id == item.id && $0.pastes }
        }
        return CommandBarRow(
            record: SearchRecord(id: "snippet:\(item.id)", title: item.title, subtitle: "Note · Paste · ⌘↩ Copy", symbol: "text.badge.plus"),
            primary: CommandRowAction(title: "Paste") {
                guard let note = current() else { return }
                try await paste.paste(note, into: target, isCurrent: { current() != nil }, waitForRelease: waitForRelease)
            },
            secondary: CommandRowAction(title: "Copy") {
                guard let note = current() else { return }
                try paste.copy(note)
            })
    }
}
