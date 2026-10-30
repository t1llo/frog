import Combine
import Foundation
import FrogCore

/// The notes and scripts on this Mac, in one file that the Notes and Scripts plugins share. Reads the file on first
/// use and saves a quarter second after the last change.
@MainActor final class LocalDocuments: ObservableObject {
    /// Notes and scripts together.
    static let maximumItems = 1000
    static let maximumTextBytes = 1_000_000

    @Published private(set) var items: [UtilityDocument] = []
    @Published private(set) var issue: String?
    /// Items the file holds that this version of Frog cannot read. They stay out of `items`, and the first save leaves them out of the file.
    @Published private(set) var unreadable: UtilityDocumentStore.Unreadable?
    @Published var selection: [UtilityDocument.Kind: UUID] = [:]
    private let store: UtilityDocumentStore
    private(set) var loaded = false
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var revision = 0
    private var unsaved = false
    var needsFlush: Bool { unsaved }
    /// The file to show in Finder while one needs attention: the documents file that could not be opened or holds unreadable items, or its copy once a save has kept it.
    var fileToReveal: URL? {
        guard !loaded || unreadable != nil else { return nil }
        return [unreadable?.backup, store.file].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    init(directory: URL) { store = UtilityDocumentStore(directory: directory) }
    func load() async {
        if let loading { await loading.value; return }
        guard !loaded else { return }
        let task = Task {
            do { items = try await store.load(); unreadable = await store.unreadable; loaded = true; issue = nil }
            catch { issue = "Could not open local documents: \(error.localizedDescription)" }
        }
        loading = task; await task.value; loading = nil
    }
    @discardableResult func add(_ item: UtilityDocument) -> UUID {
        guard loaded else { return item.id }
        items.append(item); persist(); return item.id
    }
    func update(_ item: UtilityDocument) {
        guard loaded, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var item = item; item.modified = Date(); items[index] = item; persist()
    }
    func remove(_ id: UUID) { guard loaded else { return }; items.removeAll { $0.id == id }; persist() }
    func flush() async -> Bool {
        if unsaved, saving == nil { persist() }
        // An edit made while waiting replaces the save with its own. A save that fails ends the wait.
        while let saving { await saving.value }
        return !unsaved
    }
    private func persist() {
        unsaved = true
        revision += 1; let token = revision, snapshot = items
        saving?.cancel()
        saving = Task {
            defer { if revision == token { saving = nil } }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await store.save(snapshot, revision: token)
                if revision == token { issue = nil; unsaved = false }
            } catch is CancellationError { }
            catch { if revision == token { issue = error.localizedDescription } }
        }
    }

    // MARK: For actions

    /// Loads the file, or says why it cannot be read.
    func loadForAction() async throws {
        await load()
        guard loaded else { throw ActionError.failed(issue ?? "Frog could not open its notes and scripts.") }
    }

    func items(_ kind: UtilityDocument.Kind) -> [UtilityDocument] { items.filter { $0.kind == kind } }

    /// The item of `kind` titled `name`: the exact title or its id first, then, unless `exactly`, the one title that
    /// starts with it, ignoring case.
    func item(_ kind: UtilityDocument.Kind, titled name: String, exactly: Bool = false) throws -> UtilityDocument {
        let candidates = items(kind)
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = candidates.first(where: { $0.title == wanted }) ?? candidates.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return exact
        }
        let noun = kind == .note ? "note" : "script"
        guard !exactly else {
            throw ActionError.failed("No \(noun) is titled exactly “\(wanted)”. List them with `frog run \(kind.pluginID).list`.")
        }
        let matching = candidates.filter { $0.title.lowercased().hasPrefix(wanted.lowercased()) }
        switch matching.count {
        case 1: return matching[0]
        case 0: throw ActionError.failed("No \(noun) “\(wanted)”. List them with `frog run \(kind.pluginID).list`.")
        default:
            throw ActionError.failed("“\(wanted)” starts \(matching.count) \(noun)s: \(matching.prefix(5).map { "“\($0.shownTitle)”" }.joined(separator: ", ")). Give more of the title.")
        }
    }

    /// Waits until the change is on disk, so the next action or the page finds it. A change that could not be saved
    /// is taken back with `undo`, so trying again does not apply it twice.
    func commit(undo: () -> Void) async throws {
        guard await flush() else {
            let issue = issue
            undo()
            throw ActionError.failed(issue ?? "Frog could not save the change.")
        }
    }

    func checkRoom() throws {
        guard items.count < Self.maximumItems else {
            throw ActionError.failed("Frog keeps up to \(Self.maximumItems) notes and scripts together. Delete one to add another.")
        }
    }

    static func checkSize(_ text: String) throws {
        guard text.utf8.count <= maximumTextBytes else { throw ActionError.failed("A note or script holds at most 1 MB of text.") }
    }
}

extension UtilityDocument {
    var shownTitle: String { title.isEmpty ? "Untitled" : title }

    /// A deleted item cannot be brought back, so Frog asks before it deletes one that holds something, a title of
    /// its own included. An item that was only just created is removed without a question.
    var deletionAsksFirst: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(title.isEmpty || title == kind.newItemTitle)
    }
}

extension UtilityDocument.Kind {
    /// The title of an item that New creates.
    var newItemTitle: String {
        switch self { case .note: "Untitled note"; case .script: "New script" }
    }
    var pluginID: String {
        switch self { case .note: "notes"; case .script: "scripts" }
    }
}
