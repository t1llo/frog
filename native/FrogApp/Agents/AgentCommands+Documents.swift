import AppKit
import FrogAgent
import FrogCore
import os

/// Scripts, snippets, notes and the shelf: the items on those pages, read from and saved to the same store.
extension AgentCommands {
    static var documentTools: [AgentCommand] { scripts + snippets + notes + shelf }

    private static var scripts: [AgentCommand] {
        [
            AgentCommand(words: ["scripts", "list"], summary: "Your scripts.", feature: .scripts) { call in
                list(try await items(.script, call.model), kind: .script) { [$0.shownTitle, preview($0.text)] }
            },
            AgentCommand(words: ["scripts", "show"], arguments: "<name>", summary: "Print a script.",
                         details: "Takes a name from `frog scripts list`; the start of a name is enough when only one script begins with it.",
                         feature: .scripts) { call in
                show(try await document(.script, call))
            },
            AgentCommand(words: ["scripts", "run"], arguments: "<name> [--timeout SECONDS]", summary: "Run a script and print its output.",
                         details: """
                         Runs the script with zsh in your home folder, as its Run button does, for up to 60 seconds or \
                         the --timeout you give, at most 600. Output past 256 KB is cut off. The script stops when \
                         the command is interrupted or Frog quits.

                         The command exits with the script's own exit code, so any code, 2 included, can come from \
                         the script. A script that runs out of time or cannot start gives 1. With --json, status is \
                         the script's exit code, and is left out when the script did not finish.

                         Example: frog scripts run "Clean downloads" --timeout 120
                         """, options: ["timeout"], feature: .scripts) { call in
                let script = try await document(.script, call)
                let timeout = try call.integer("timeout", default: 60, in: 1...600)
                let printed = OSAllocatedUnfairLock(initialState: "")
                let run: ScriptRun
                do {
                    let result = try await call.model.scripts.runForAgent(script.text, timeout: TimeInterval(timeout)) { text in printed.withLock { $0 = text } }
                    run = ScriptRun(name: script.shownTitle, status: result.status, output: result.output, truncated: result.truncated, error: nil)
                    if result.status == 0 { call.model.statistics.recordToolUse(.scriptRun) }
                } catch {
                    // What it printed before it ran out of time is still worth showing.
                    run = ScriptRun(name: script.shownTitle, status: nil, output: printed.withLock { $0 },
                                    truncated: (error as? ScriptTimeout)?.truncated ?? false, error: error.localizedDescription)
                }
                var result = AgentResult(run, text: run.output)
                result.exitCode = run.status ?? AgentExit.failure
                result.notice = [run.error, run.status.flatMap { $0 == 0 ? nil : "“\(run.name)” exited with status \($0)." },
                                 run.truncated ? "Its output was cut off at 256 KB." : nil].compactMap { $0 }.joined(separator: " ")
                return result
            }
        ]
    }

    private static var snippets: [AgentCommand] {
        [
            AgentCommand(words: ["snippets", "list"], summary: "Your snippets.", feature: .snippets) { call in
                list(try await items(.snippet, call.model), kind: .snippet) { [$0.shownTitle, preview($0.text)] }
            },
            AgentCommand(words: ["snippets", "show"], arguments: "<name> [--expand]", summary: "Print a snippet.",
                         details: """
                         With --expand, {{date}}, {{time}} and {{clipboard}} are filled in as pasting the snippet would. \
                         Text an app marked as sensitive, such as a password, is never filled in.

                         Example: frog snippets show signature --expand
                         """, flags: ["expand"], feature: .snippets) { call in
                let snippet = try await document(.snippet, call)
                guard call.flag("expand") else { return show(snippet) }
                let pasteboard = call.model.clipboardHistoryStore.pasteboard
                if snippet.text.contains("{{clipboard}}"), pasteboard.holdsSensitiveText {
                    throw AgentCommandError.failed("The clipboard holds text marked as sensitive, so {{clipboard}} is not filled in.")
                }
                return show(snippet, text: SnippetExpansion.expand(snippet.text, clipboard: pasteboard.string(forType: .string) ?? ""))
            }
        ]
    }

    private static var notes: [AgentCommand] {
        [
            AgentCommand(words: ["notes", "list"], summary: "Your notes, with when each changed.", feature: .scratchpad) { call in
                list(try await items(.note, call.model), kind: .note) { [$0.shownTitle, $0.modified.formatted(date: .abbreviated, time: .shortened)] }
            },
            AgentCommand(words: ["notes", "show"], arguments: "<name>", summary: "Print a note.",
                         details: "Takes a name from `frog notes list`; the start of a name is enough when only one note begins with it.",
                         feature: .scratchpad) { call in
                show(try await document(.note, call))
            },
            AgentCommand(words: ["notes", "add"], arguments: "<title> [text]", summary: "Add a note.",
                         details: """
                         The text follows the title, comes from --text, or from standard input with --stdin. Notes are Markdown.

                         Examples:
                           frog notes add "Call Anna" "About the offer, before Friday"
                           git log -5 --oneline | frog notes add "Recent commits" --stdin
                         """, options: ["text"], feature: .scratchpad) { call in
                let title = try call.argument(0, "title").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw AgentCommandError.usage("Give the note a title.") }
                let given = call.positional.count > 1 || call.option("text") != nil || call.input != nil
                let text = given ? try call.text(from: 1) : ""
                try checkSize(text)
                let documents = try await loadedDocuments(call.model)
                if documents.items.contains(where: { $0.kind == .note && $0.title == title }) {
                    throw AgentCommandError.failed("A note named “\(title)” already exists. Add to it with `frog notes append`.")
                }
                try checkRoom(documents, for: 1)
                let note = UtilityDocument(kind: .note, title: title, text: text)
                documents.add(note)
                try await save(documents) { documents.remove(note.id) }
                return AgentResult(Entry(note, text: true), text: "Added the note “\(title)”.")
            },
            AgentCommand(words: ["notes", "append"], arguments: "<name> [text]", summary: "Add text to the end of a note.",
                         details: """
                         The text follows the name, comes from --text, or from standard input with --stdin. It starts on a new line.

                         Example: frog notes append "Call Anna" "She prefers mornings"
                         """, options: ["text"], feature: .scratchpad) { call in
                let addition = try call.text(from: 1)
                let documents = try await loadedDocuments(call.model)
                let note = try find(.note, call, in: documents.items)
                var updated = note
                updated.text = note.text.isEmpty || note.text.hasSuffix("\n") ? note.text + addition : note.text + "\n" + addition
                try checkSize(updated.text)
                documents.update(updated)
                try await save(documents) { documents.update(note) }
                return .done("Added to the note “\(note.shownTitle)”.")
            }
        ]
    }

    private static var shelf: [AgentCommand] {
        [
            AgentCommand(words: ["shelf", "list"], summary: "What is on the shelf: files with their paths, links and text.", feature: .shelf) { call in
                list(try await items(.shelf, call.model), kind: .shelf, files: true) { item in
                    [item.shownTitle, item.files.isEmpty ? preview(item.text) : item.files.map(\.path).joined(separator: ", ")]
                }
            },
            AgentCommand(words: ["shelf", "add"], arguments: "<path or link>…", summary: "Put files or links on the shelf.",
                         details: """
                         Each file or http(s) link becomes a shelf item, ready to drag into another app. Paths are relative to \
                         the folder the command is typed in.

                         Example: frog shelf add report.pdf ~/Desktop/chart.png
                         """, feature: .shelf) { call in
                guard !call.positional.isEmpty else { throw AgentCommandError.usage("Missing <path>. Usage: \(call.command.usage)") }
                guard call.positional.count <= 100 else { throw AgentCommandError.usage("Add up to 100 items at a time.") }
                let added = try call.positional.map { word -> UtilityDocument in
                    if let link = URL(string: word), ["http", "https"].contains(link.scheme?.lowercased() ?? ""), link.host != nil {
                        return ShelfDrop.document(url: link)
                    }
                    let file = call.path(word)
                    guard FileManager.default.fileExists(atPath: file.path) else { throw AgentCommandError.usage("Nothing found at \(file.path).") }
                    return ShelfDrop.document(url: file)
                }
                let documents = try await loadedDocuments(call.model)
                try checkRoom(documents, for: added.count)
                added.forEach { documents.add($0) }
                try await save(documents) { added.forEach { documents.remove($0.id) } }
                let text = added.count == 1 ? "Put “\(added[0].shownTitle)” on the shelf." : "Put \(added.count) items on the shelf."
                return AgentResult(added.map { Entry($0, text: true, files: true) }, text: text)
            }
        ]
    }

    // MARK: Store

    private static func loadedDocuments(_ model: AppModel) async throws -> LocalDocuments {
        let documents = model.documents
        await documents.load()
        guard documents.loaded else { throw AgentCommandError.failed(documents.issue ?? "Frog could not open its documents.") }
        return documents
    }

    private static func items(_ kind: UtilityDocument.Kind, _ model: AppModel) async throws -> [UtilityDocument] {
        try await loadedDocuments(model).items.filter { $0.kind == kind }
    }

    /// The item of `kind` that the first argument names.
    private static func document(_ kind: UtilityDocument.Kind, _ call: AgentCall) async throws -> UtilityDocument {
        try find(kind, call, in: try await loadedDocuments(call.model).items)
    }

    private static func find(_ kind: UtilityDocument.Kind, _ call: AgentCall, in items: [UtilityDocument]) throws -> UtilityDocument {
        try item(named: try call.argument(0, "name"), in: items.filter { $0.kind == kind }, kind: kind.noun,
                 list: "frog \(kind.command) list", id: { $0.id.uuidString }, title: \.title)
    }

    /// Waits until the change is on disk, so the next command, or the page, finds it. A change that could not be
    /// saved is taken back with `undo`, so trying again does not add it twice.
    private static func save(_ documents: LocalDocuments, undo: () -> Void) async throws {
        guard await documents.flush() else {
            let issue = documents.issue
            undo()
            throw AgentCommandError.failed(issue ?? "Frog could not save the change.")
        }
    }

    private static func checkSize(_ text: String) throws {
        guard text.utf8.count <= 1_000_000 else { throw AgentCommandError.failed("A note holds at most 1 MB of text.") }
    }

    /// Notes, snippets, scripts and the shelf share one store of up to 1,000 items.
    private static func checkRoom(_ documents: LocalDocuments, for count: Int) throws {
        let free = 1000 - documents.items.count
        guard count <= free else {
            throw AgentCommandError.failed("Frog keeps up to 1,000 notes, snippets, scripts and shelf items together. There is room for \(max(0, free)) more.")
        }
    }

    private static func list(_ items: [UtilityDocument], kind: UtilityDocument.Kind, files: Bool = false,
                             columns: (UtilityDocument) -> [String]) -> AgentResult {
        AgentResult(items.map { Entry($0, text: files, files: files) },
                    text: items.isEmpty ? kind.empty : AgentTable.render(items.map(columns)))
    }

    private static func show(_ item: UtilityDocument, text: String? = nil) -> AgentResult {
        var entry = Entry(item)
        entry.text = text ?? item.text
        return AgentResult(entry, text: text ?? item.text)
    }

    private struct Entry: Encodable {
        let id: UUID
        let name: String
        let modified: Date
        var text: String?
        var files: [String]?
        init(_ item: UtilityDocument, text: Bool = false, files: Bool = false) {
            id = item.id; name = item.title; modified = item.modified
            self.text = text ? item.text : nil
            self.files = files ? item.files.map(\.path) : nil
        }
    }

    private struct ScriptRun: Encodable {
        let name: String
        /// Nil when the script did not finish: it ran out of time or could not start.
        let status: Int32?
        let output: String
        let truncated: Bool
        let error: String?
    }
}

private extension UtilityDocument {
    var shownTitle: String { title.isEmpty ? "Untitled" : title }
}

private extension UtilityDocument.Kind {
    var noun: String {
        switch self { case .note: "note"; case .snippet: "snippet"; case .shelf: "shelf item"; case .script: "script" }
    }
    /// The first word of its commands.
    var command: String {
        switch self { case .note: "notes"; case .snippet: "snippets"; case .shelf: "shelf"; case .script: "scripts" }
    }
    var empty: String {
        switch self { case .note: "No notes yet."; case .snippet: "No snippets yet."; case .shelf: "The shelf is empty."; case .script: "No scripts yet." }
    }
}
