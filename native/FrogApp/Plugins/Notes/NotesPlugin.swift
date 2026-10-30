import AppKit
import FrogCore
import SwiftUI

/// Markdown notes, some of which paste text with the date, time or clipboard filled in. Shares its store with Scripts.
final class NotesPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "notes", name: "Notes", symbol: "note.text", tint: .yellow, category: .navigate,
                                 summary: "Markdown notes and text to paste")

    /// Finds the field a note pastes into; tests have none.
    var captureTarget: @MainActor () -> (any ClipboardHistoryPasteTarget)? = { NativeClipboardHistoryPasteTarget.capture() }

    private var documents: LocalDocuments { model.documents }
    private var paste: NotePaste {
        NotePaste(pasteboard: model.clipboardHistoryStore.pasteboard) { [model] in model.statistics.recordToolUse(.snippetCopy) }
    }

    func page() -> AnyView? {
        AnyView(NotesPage(documents: documents, paste: paste, report: { [context] in context.report($0) }))
    }

    /// Shows the note on the Notes page.
    func open(_ note: UtilityDocument) {
        documents.selection[.note] = note.id
        context.openPage()
    }

    var actions: [PluginAction] {
        let title = ActionParameter(name: "title", required: true, help: "The note's title; its start is enough when only one note begins with it")
        return [
            PluginAction(id: "notes.new", title: "New note", symbol: "square.and.pencil", keywords: "note write markdown") { [weak self] _ in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                try documents.checkRoom()
                let note = UtilityDocument(kind: .note, title: UtilityDocument.Kind.note.newItemTitle)
                documents.add(note)
                open(note)
                return ActionResult(Entry(note), text: "Opened a new note.")
            },
            PluginAction(id: "notes.list", title: "List notes", symbol: "list.bullet", surfaces: .agent) { [weak self] _ in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let notes = documents.items(.note)
                let rows = notes.map { [$0.shownTitle, $0.modified.formatted(date: .abbreviated, time: .shortened), $0.pastes ? "pastes" : ""] }
                return ActionResult(notes.map { Entry($0) }, text: notes.isEmpty ? "No notes yet." : AgentTable.render(rows))
            },
            PluginAction(id: "notes.read", title: "Read a note", symbol: "doc.text",
                         parameters: [title, ActionParameter(name: "expand", kind: .boolean,
                                                             help: "Fill in {{date}}, {{time}} and {{clipboard}} as pasting it would")],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let note = try documents.item(.note, titled: try input.required("title"))
                let text = try input.boolean("expand") == true ? try paste.expandedText(note) : note.text
                return ActionResult(Entry(note, text: text), text: text)
            },
            PluginAction(id: "notes.add", title: "Add a note", symbol: "plus",
                         parameters: [ActionParameter(name: "title", required: true, help: "A title no other note has")],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                let name = try input.required("title").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ActionError.missing("title") }
                let text = input.text ?? ""
                try LocalDocuments.checkSize(text)
                try await documents.loadForAction()
                guard !documents.items(.note).contains(where: { $0.title == name }) else {
                    throw ActionError.failed("A note named “\(name)” already exists. Add to it with notes.append.")
                }
                try documents.checkRoom()
                let note = UtilityDocument(kind: .note, title: name, text: text)
                documents.add(note)
                try await documents.commit { [documents] in documents.remove(note.id) }
                return ActionResult(Entry(note, text: text), text: "Added the note “\(name)”.")
            },
            PluginAction(id: "notes.append", title: "Add to a note", symbol: "text.append", parameters: [title],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                guard let addition = input.text, !addition.isEmpty else { throw ActionError.failed("Give the text to add on standard input.") }
                try await documents.loadForAction()
                let note = try documents.item(.note, titled: try input.required("title"))
                var updated = note
                updated.text = note.text.isEmpty || note.text.hasSuffix("\n") ? note.text + addition : note.text + "\n" + addition
                try LocalDocuments.checkSize(updated.text)
                documents.update(updated)
                try await documents.commit { [documents] in documents.update(note) }
                return .done("Added to the note “\(note.shownTitle)”.")
            },
            PluginAction(id: "notes.copy", title: "Copy a note", symbol: "doc.on.doc", parameters: [title],
                         surfaces: [.shortcut, .agent]) { [weak self] input in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let note = try documents.item(.note, titled: try input.required("title"))
                try paste.copy(note)
                return .done("Copied “\(note.shownTitle)”.")
            },
            PluginAction(id: "notes.paste", title: "Paste a note", symbol: "text.badge.plus", parameters: [title],
                         surfaces: [.shortcut, .agent]) { [weak self] input in
                guard let self else { throw CancellationError() }
                try await documents.loadForAction()
                let note = try documents.item(.note, titled: try input.required("title"))
                guard note.files.isEmpty else { throw ActionError.failed("“\(note.shownTitle)” holds files; copy it instead.") }
                guard let target = captureTarget() else {
                    try paste.copy(note)
                    return .done("Copied “\(note.shownTitle)”: no text field has focus to paste into.")
                }
                // A shortcut's keys must be up before Frog presses ⌘V; an agent pressed none.
                let wait: () async throws -> Void = input.source == .shortcut ? { try await ClipboardSelection.waitForShortcutRelease() } : {}
                try await paste.paste(note, into: target, isCurrent: { true }, waitForRelease: wait)
                return .done("Pasted “\(note.shownTitle)”.")
            },
        ]
    }

    struct Entry: Encodable {
        let id: UUID
        let title: String
        let modified: Date
        var text: String?
        /// Files a note that was a shelf item holds.
        var files: [String]?
        /// Whether choosing it in the command bar pastes it.
        let pastes: Bool
        init(_ note: UtilityDocument, text: String? = nil) {
            id = note.id; title = note.title; modified = note.modified; self.text = text
            files = note.files.isEmpty ? nil : note.files.map(\.path)
            pastes = note.pastes
        }
    }
}

/// The Notes page: the list, and the chosen note to edit or preview.
struct NotesPage: View {
    @ObservedObject var documents: LocalDocuments
    let paste: NotePaste
    let report: (Error) -> Void
    @State private var preview = false

    var body: some View {
        DocumentsPage(documents: documents, kind: .note, title: "Notes", symbol: "note.text",
                      emptyMessage: "Write one here, or have an agent add one with frog run notes.add.") { note in
            CompactSegments(values: [false, true], selected: preview, width: 140, compact: true, title: { $0 ? "Preview" : "Edit" }) { preview = $0 }
            Toggle("Pastes", isOn: documents.binding(note.id, \.pastes)).toggleStyle(.switch).controlSize(.mini)
                .font(FrogType.small).foregroundStyle(FrogStyle.muted)
                .help("Choosing it in the command bar pastes its text, with {{date}}, {{time}} and {{clipboard}} filled in")
            CopyAction(labeled: true) {
                do { try paste.copy(note) } catch { report(error) }
            }
        } content: { note in
            if preview {
                MarkdownPreviewView(markdown: note.text).id(note.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            } else {
                DocumentTextEditor(text: documents.binding(note.id, \.text))
            }
        }
    }
}
