import AppKit
import Combine
import FrogCore

/// The clipboard history, newest first, without sensitive entries. Return pastes into the app in front, ⌘↩ copies.
/// A copy made while the bar is open lists its entry; clear, delete and eviction take their rows away.
@MainActor final class ClipboardCommandRows: CommandBarRowProviding {
    private var observation: AnyCancellable?
    /// The entries the store will hold: its publisher emits before the store changes.
    private var pending: [ClipboardHistoryEntry]?

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let model = context.model
        guard model.configuration.preferences.featureEnabled(.clipboard) else { return [] }
        let store = model.clipboardHistoryStore
        // Paste only goes ahead in the history generation its row was built in, which the store renews before it
        // changes its entries. The rows are therefore rebuilt whenever the entries change.
        let target = context.pasteTarget, retention = store.retentionGeneration, pasteboard = context.pasteboard
        let waitForRelease = context.waitForRelease, toolUse = context.toolUse
        return (pending ?? store.entries).filter { !$0.isSensitive }.map { entry in
            let copy = CommandRowAction(title: "Copy") { [weak model] in
                guard let model, model.configuration.preferences.featureEnabled(.clipboard), model.clipboardHistoryStore.copy(entry) else {
                    throw FrogError.message("The clipboard item is no longer available.")
                }
            }
            return CommandBarRow(
                record: SearchRecord(id: "clipboard:\(entry.id)", title: String(entry.text.prefix(100)), subtitle: "Clipboard · Paste · ⌘↩ Copy",
                                     keywords: String(entry.text.prefix(512)), symbol: "clipboard"),
                primary: CommandRowAction(title: "Paste") { [weak model] in
                    guard let model else { return }
                    try await ClipboardHistoryDelivery.paste(entry, plainText: false, pasteboard: pasteboard, target: target, isCurrent: {
                        model.configuration.preferences.featureEnabled(.clipboard) && model.clipboardHistoryStore.retentionGeneration == retention
                            && model.clipboardHistoryStore.entries.contains(where: { $0.id == entry.id })
                    }, waitForRelease: waitForRelease)
                    toolUse(.clipboardPaste)
                },
                secondary: copy)
        }
    }

    func open(in context: CommandBarContext, changed: @escaping @MainActor () -> Void) {
        pending = nil
        observation = context.model.clipboardHistoryStore.$entries.dropFirst().sink { [weak self] entries in
            self?.pending = entries
            changed()
            self?.pending = nil
        }
    }

    func close() { observation = nil; pending = nil }
}

/// Notes, notes that paste as snippets, and scripts, from `DocumentCommandRows`. They are in memory once the store
/// has been read; only that first read is waited for, and on its own, so a note that pastes is never missing while
/// apps are rescanned.
@MainActor final class DocumentRowsProvider: CommandBarRowProviding {
    private var loading: Task<Void, Never>?

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        guard context.model.documents.loaded else { return [] }
        return DocumentCommandRows.rows(in: context)
    }

    func open(in context: CommandBarContext, changed: @escaping @MainActor () -> Void) {
        let model = context.model
        guard [NotesPlugin.info.id, ScriptsPlugin.info.id].contains(where: model.pluginEnabled), !model.documents.loaded else { return }
        loading = Task { [weak model] in
            guard let model else { return }
            await model.documents.load()
            guard !Task.isCancelled else { return }
            changed()
        }
    }

    func close() { loading?.cancel(); loading = nil }
}
