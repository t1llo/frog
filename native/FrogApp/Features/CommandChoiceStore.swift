import Foundation
import FrogCore

/// What the command bar learned from the rows picked for typed text, while Learn from your choices is on. The bar
/// asks `index` on every keystroke; a pick changes the memory and the index at once and reaches the file on a serial
/// queue, so it never waits for the disk.
@MainActor final class CommandChoiceStore: ObservableObject {
    /// "Frog remembers N choices": the pairs of typed text and row.
    @Published private(set) var count = 0
    /// Set when the file cannot be read or saved. Learning pauses, and the bar ranks as it always has, until the
    /// learned choices are forgotten.
    @Published private(set) var issue: String?
    /// The strongest learned files that still exist, so they are listed before Spotlight answers.
    @Published private(set) var learnedFiles: [SearchRecord] = []
    private(set) var index: CommandChoiceIndex = .empty
    /// Learning is on and the file could be read: the bar ranks with what was learned.
    var isActive: Bool { enabled && issue == nil }
    /// Serial, so picks reach the file in the order they were made and forgetting never overtakes a pick still
    /// being saved.
    let queue: DispatchQueue
    private let persistence: CommandChoicesPersistence
    private let now: () -> Date
    private var enabled = false
    private var choices = CommandChoices()
    /// Renewed when the choices are forgotten, so a late reply about older choices changes nothing.
    private var epoch = 0
    private var fileCheck = 0
    static let staleIndex: TimeInterval = 3_600
    static let checkedFiles = 30

    init(directory: URL?, queue: DispatchQueue = DispatchQueue(label: "frog.command-choices", qos: .utility), now: @escaping () -> Date = Date.init) {
        persistence = CommandChoicesPersistence(directory: directory)
        self.queue = queue; self.now = now
    }

    /// On, reads the file once. Off, nothing is held, and a file learned until now is deleted: turning the switch
    /// or the Command bar off forgets, wherever the change came from.
    func configure(enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { load() } else { forget() }
    }

    /// Strengths fade with time; an index built more than an hour ago is built again when the bar opens.
    func refreshIfStale() {
        let date = now()
        guard isActive, date.timeIntervalSince(index.builtAt) > Self.staleIndex else { return }
        choices.prune(now: date)
        publish(date, checkFiles: false)
    }

    /// A row picked after typing `typed`. Clipboard rows, windows and calculations are never kept.
    func record(typed: String, id: String) {
        guard isActive, CommandChoices.isRememberable(id) else { return }
        let date = now()
        choices.record(typed: typed, id: id, now: date)
        publish(date)
        save { try $0.record(typed: typed, id: id, now: date) }
    }

    /// Deletes the file, also one that could not be read, and learning starts again.
    func forget() {
        epoch += 1
        choices = CommandChoices(); issue = nil
        publish(now())
        let epoch = self.epoch
        queue.async { [persistence, weak self] in
            do { try persistence.clear() } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { if self?.epoch == epoch { self?.issue = message } }
            }
        }
    }

    /// Forgets one row, such as a learned file that could not be opened.
    func forget(id: String) {
        guard isActive else { return }
        let date = now()
        choices.forget(id: id)
        publish(date)
        save { try $0.forget(id: id, now: date) }
    }

    /// Returns once every pick is saved. Frog calls it before it quits.
    func waitForWrites() { queue.sync {} }

    private func load() {
        epoch += 1
        let date = now()
        do {
            choices = try queue.sync { [persistence] in try persistence.load(now: date) }
            issue = nil
        } catch {
            choices = CommandChoices()
            issue = "Frog could not read its learned choices, so learning is paused. Forget them to start again."
        }
        publish(date)
    }

    private func save(_ change: @escaping (CommandChoicesPersistence) throws -> CommandChoices) {
        let epoch = self.epoch
        queue.async { [persistence, weak self] in
            do { _ = try change(persistence) } catch {
                DispatchQueue.main.async {
                    guard let self, self.epoch == epoch, self.enabled else { return }
                    self.issue = "Frog could not save its learned choices, so learning is paused. Forget them to start again."
                }
            }
        }
    }

    private func publish(_ date: Date, checkFiles: Bool = true) {
        index = enabled ? choices.index(now: date) : .empty
        if count != choices.count { count = choices.count }
        if checkFiles { self.checkFiles() }
    }

    /// Looks for the strongest learned files on a background task, after a load or a pick, never per keystroke.
    private func checkFiles() {
        fileCheck += 1
        let check = fileCheck
        let ids = enabled ? Array(index.items(withPrefix: "file:").prefix(Self.checkedFiles)) : []
        guard !ids.isEmpty else {
            if !learnedFiles.isEmpty { learnedFiles = [] }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let files = ids.compactMap(CommandChoiceStore.existingFile)
            guard let store = self else { return }
            await store.show(files, check: check)
        }
    }

    private func show(_ files: [SearchRecord], check: Int) {
        guard fileCheck == check, learnedFiles != files else { return }
        learnedFiles = files
    }

    /// A row as the file search builds it.
    nonisolated static func existingFile(_ id: String) -> SearchRecord? {
        guard id.hasPrefix("file:") else { return nil }
        let url = URL(fileURLWithPath: String(id.dropFirst(5)))
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return nil }
        let package = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        return SearchRecord(id: id, title: url.lastPathComponent,
                            subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                            symbol: directory.boolValue && !package ? "folder" : "doc")
    }
}
