import AppKit
import FrogCore

/// The one way a note reaches the clipboard or a text field, for the Notes page, its actions and the command bar.
/// A note that pastes has `{{date}}`, `{{time}}` and `{{clipboard}}` filled in; text an app marked as sensitive stays
/// marked when it is filled in, and is never shown to an agent.
@MainActor struct NotePaste {
    let pasteboard: NSPasteboard
    /// Counts a copy or paste of a note that pastes, for the activity statistics.
    var recordUse: () -> Void = {}

    /// What the note puts on the clipboard.
    func entry(_ note: UtilityDocument) -> ClipboardHistoryEntry {
        guard note.pastes else { return ClipboardHistoryEntry(text: note.text, isSensitive: false) }
        let text = SnippetExpansion.expand(note.text, clipboard: pasteboard.string(forType: .string) ?? "")
        return ClipboardHistoryEntry(text: text, isSensitive: note.text.contains("{{clipboard}}") && pasteboard.holdsSensitiveText)
    }

    /// Copies the note: its files when it holds files, otherwise its text.
    func copy(_ note: UtilityDocument) throws {
        if !note.files.isEmpty {
            pasteboard.clearContents()
            guard pasteboard.writeObjects(note.files as [NSURL]) else { throw FrogError.message("Could not copy the note's files.") }
            return
        }
        guard entry(note).write(to: pasteboard, plainText: true) else { throw FrogError.message("Could not copy the note.") }
        if note.pastes { recordUse() }
    }

    /// Pastes the note into `target`, the field that had focus. Without one it is copied, and the error says so.
    func paste(_ note: UtilityDocument, into target: (any ClipboardHistoryPasteTarget)?, isCurrent: () -> Bool,
               waitForRelease: () async throws -> Void) async throws {
        try await ClipboardHistoryDelivery.paste(entry(note), plainText: true, pasteboard: pasteboard, target: target,
                                                 isCurrent: isCurrent, waitForRelease: waitForRelease)
        recordUse()
    }

    /// The note's text as pasting it would give it, for an agent. Refuses rather than reveal sensitive text.
    func expandedText(_ note: UtilityDocument) throws -> String {
        var note = note
        note.pastes = true
        let entry = entry(note)
        guard !entry.isSensitive else {
            throw ActionError.failed("The clipboard holds text marked as sensitive, so {{clipboard}} is not filled in.")
        }
        return entry.text
    }
}
