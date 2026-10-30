import Combine
import Foundation
import FrogCore

@MainActor final class LocalDocuments: ObservableObject {
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
}
