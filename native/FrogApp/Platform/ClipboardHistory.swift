import AppKit
import Combine

/// Only text and bounded text formatting are retained, never arbitrary clipboard payloads.
struct ClipboardHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let text: String
    let formatting: [String: Data]
    /// Marked sensitive by the app it was copied from, or a key or password by its look.
    let isSensitive: Bool
    /// What kind of credential the text looks like; nil for ordinary text and for text only its app marked.
    let secret: ClipboardSecret?
    var preview: String { String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ") }

    init(text: String, formatting: [String: Data] = [:], isSensitive: Bool = false, timestamp: Date = Date()) {
        id = UUID(); self.timestamp = timestamp; self.text = text; self.formatting = formatting
        secret = ClipboardSecret.detect(text)
        self.isSensitive = isSensitive || secret != nil
    }

    /// Hidden text shows as a password field does, in dots of one length that says nothing of its own.
    static let mask = String(repeating: "•", count: 12)

    func displayPreview(revealed: Bool) -> String {
        !isSensitive || revealed ? preview : Self.mask
    }

    /// "API key", "Password", or "Sensitive" for text its app marked.
    var sensitivityLabel: String { secret?.label ?? "Sensitive" }
    /// "Copied API key", or "Sensitive copied text" for text its app marked.
    var sensitiveTitle: String { secret?.title ?? "Sensitive copied text" }

    func write(to pasteboard: NSPasteboard, plainText: Bool) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if isSensitive { item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        if !plainText {
            for (type, data) in formatting { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        }
        pasteboard.prepareForNewContents(with: contentsOptions)
        return pasteboard.writeObjects([item])
    }

    /// Marked-sensitive text stays on this Mac. Universal Clipboard would otherwise offer it to
    /// the person's other devices again, long after the copy in the source application expired.
    var contentsOptions: NSPasteboard.ContentsOptions { isSensitive ? .currentHostOnly : [] }
}

extension NSPasteboard.PasteboardType {
    /// The types with which apps mark copied text as sensitive, such as a password. Clipboard History hides it.
    static let sensitiveMarks = [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]
}

extension NSPasteboard {
    /// Whether the text on the pasteboard is marked as sensitive, such as a password.
    var holdsSensitiveText: Bool { types?.contains(where: NSPasteboard.PasteboardType.sensitiveMarks.contains) == true }
}

/// Prevent compatibility-selection Copy requests/restoration from becoming clipboard history.
final class ClipboardHistoryCaptureGate: @unchecked Sendable {
    static let shared = ClipboardHistoryCaptureGate()
    private let lock = NSLock()
    private var depth = 0
    private var generation: UInt64 = 0
    private var ignoredCounts: [NSPasteboard.Name: Int] = [:]
    var state: (suppressed: Bool, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (depth > 0, generation)
    }
    func begin() { lock.lock(); depth += 1; generation &+= 1; lock.unlock() }
    func end(pasteboard: NSPasteboard? = nil) {
        let count = pasteboard?.changeCount
        lock.lock(); defer { lock.unlock() }
        if let pasteboard, let count { ignoredCounts[pasteboard.name] = count }
        depth -= 1; generation &+= 1
    }
    func ignores(name: NSPasteboard.Name, count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ignoredCounts[name] == count
    }
}

/// Pasteboard IPC and format reads run away from the UI/input thread.
actor ClipboardHistoryReader {
    struct Observation: Sendable {
        let changeCount: Int
        let entry: ClipboardHistoryEntry?
        let retry: Bool
    }
    let name: NSPasteboard.Name
    let gate: ClipboardHistoryCaptureGate
    init(name: NSPasteboard.Name, gate: ClipboardHistoryCaptureGate) { self.name = name; self.gate = gate }

    /// The count alone, which is all the watch needs to know while nothing is copied.
    func changeCount() -> Int { NSPasteboard(name: name).changeCount }

    func read(after previousCount: Int) -> Observation {
        let pasteboard = NSPasteboard(name: name)
        if Task.isCancelled { return Observation(changeCount: previousCount, entry: nil, retry: false) }
        let state = gate.state
        let count = pasteboard.changeCount
        var entry: ClipboardHistoryEntry?
        var retry = false
        if count != previousCount, !state.suppressed, !gate.ignores(name: name, count: count) {
            let items = pasteboard.pasteboardItems ?? []
            // A copied file carries its name as text, and the name is not what was copied.
            // File names declared the old way reach the item as a file URL as well.
            if items.count == 1, let item = items.first, !item.types.contains(.fileURL) {
                let sensitive = item.types.contains(where: NSPasteboard.PasteboardType.sensitiveMarks.contains)
                if let text = item.string(forType: .string) {
                    retry = text.isEmpty
                    if !text.isEmpty, text.utf8.count <= 512 * 1024 {
                        var formatting: [String: Data] = [:]
                        for type in [NSPasteboard.PasteboardType.rtf, .html] {
                            if Task.isCancelled { break }
                            if let data = item.data(forType: type), data.count <= 1024 * 1024 { formatting[type.rawValue] = data }
                        }
                        if !Task.isCancelled, pasteboard.changeCount == count, gate.state.generation == state.generation {
                            entry = ClipboardHistoryEntry(text: text, formatting: formatting, isSensitive: sensitive)
                        }
                    }
                } else {
                    retry = item.types.contains(.string)
                }
            }
        }
        return Observation(changeCount: count, entry: entry, retry: retry)
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let capacity = 100
    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var enabled = false
    let pasteboard: NSPasteboard
    private let reader: ClipboardHistoryReader
    private var changeCount: Int
    /// Read generation: every write of Frog's own makes a read already under way stale.
    private var epoch = UUID()
    private var polling: Task<Void, Never>?
    private var pendingCount: Int?
    private var pendingAttempts = 0
    private let pollPause: @Sendable () async throws -> Void
    /// Changes only when entries are forgotten, so that a paste waiting for an item stops,
    /// while a result Frog copies in the meantime leaves it alone.
    private(set) var retentionGeneration = UUID()

    init(pasteboard: NSPasteboard = .general, gate: ClipboardHistoryCaptureGate = .shared,
         pollPause: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(500), tolerance: .milliseconds(100))
         }) {
        self.pasteboard = pasteboard
        reader = ClipboardHistoryReader(name: pasteboard.name, gate: gate)
        changeCount = pasteboard.changeCount
        self.pollPause = pollPause
    }

    func configure(enabled: Bool, automaticallyPoll: Bool = true) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled; epoch = UUID(); retentionGeneration = UUID()
        pendingCount = nil; pendingAttempts = 0
        polling?.cancel(); polling = nil
        entries = []
        guard enabled else { return }
        // Never ingest the clipboard that predates opt-in.
        changeCount = pasteboard.changeCount
        if automaticallyPoll {
            let reader = reader, pause = pollPause
            // Twice a second, and nearly every time nothing was copied. The watch runs away
            // from the main actor and turns to it only when there is something to settle.
            polling = Task.detached(priority: .utility) { [weak self] in
                // The change count the store has dealt with; nil until it says so.
                var settled: Int?
                while !Task.isCancelled {
                    do { try await pause() } catch { return }
                    if let settled, await reader.changeCount() == settled { continue }
                    guard let request = await self?.readRequest else { return }
                    // Do not retain the UI store across promised-data IPC, which
                    // AppKit does not expose a cancellation/timeout API for.
                    let observation = await reader.read(after: request.count)
                    guard !Task.isCancelled else { return }
                    guard let store = self else { return }
                    settled = await store.receive(observation, epoch: request.epoch)
                }
            }
        }
    }

    func poll() async {
        guard enabled else { return }
        let request = readRequest
        let observation = await reader.read(after: request.count)
        receive(observation, epoch: request.epoch)
    }

    private var readRequest: (count: Int, epoch: UUID) { (changeCount, epoch) }

    /// The change count that needs no further look; nil while the text of a copy is awaited.
    private var settledCount: Int? { pendingCount == nil ? changeCount : nil }

    @discardableResult
    private func receive(_ observation: ClipboardHistoryReader.Observation, epoch current: UUID) -> Int? {
        guard enabled, current == epoch else { return settledCount }
        if observation.retry {
            if pendingCount != observation.changeCount { pendingCount = observation.changeCount; pendingAttempts = 0 }
            pendingAttempts += 1
            if pendingAttempts < 3 { return settledCount }
        }
        pendingCount = nil; pendingAttempts = 0
        changeCount = observation.changeCount
        if let entry = observation.entry { record(entry) }
        return settledCount
    }

    private func record(_ entry: ClipboardHistoryEntry) {
        guard enabled else { return }
        let sensitive = entry.isSensitive || entries.contains { $0.text == entry.text && $0.formatting == entry.formatting && $0.isSensitive }
        let retained = sensitive == entry.isSensitive ? entry : ClipboardHistoryEntry(text: entry.text, formatting: entry.formatting, isSensitive: sensitive, timestamp: entry.timestamp)
        // One change of the list per copy: an open panel searches all of it again on each one.
        entries = Array(([retained] + entries.filter { $0.text != entry.text || $0.formatting != entry.formatting }).prefix(Self.capacity))
    }

    /// Explicitly include Frog results even if a subsequent compatibility Copy
    /// temporarily suppresses clipboard polling/restores that same result.
    func recordCopiedText(_ text: String) {
        guard enabled, !text.isEmpty, text.utf8.count <= 512 * 1024 else { return }
        epoch = UUID(); pendingCount = nil; pendingAttempts = 0
        record(ClipboardHistoryEntry(text: text))
        changeCount = pasteboard.changeCount
    }

    /// Writing through the store keeps the item's row, also as plain text, and the next
    /// look at the clipboard does not take Frog's own write for a new copy.
    @discardableResult
    func copy(_ entry: ClipboardHistoryEntry, plainText: Bool = false) -> Bool {
        guard enabled, entries.contains(where: { $0.id == entry.id }) else { return false }
        guard entry.write(to: pasteboard, plainText: plainText) else { return false }
        epoch = UUID(); pendingCount = nil; pendingAttempts = 0
        record(entry); changeCount = pasteboard.changeCount
        return true
    }

    func delete(id: UUID) {
        epoch = UUID(); retentionGeneration = UUID(); entries.removeAll { $0.id == id }
        pendingCount = nil; pendingAttempts = 0
        changeCount = pasteboard.changeCount
    }

    func clear() {
        epoch = UUID(); retentionGeneration = UUID(); entries = []
        pendingCount = nil; pendingAttempts = 0
        changeCount = pasteboard.changeCount
    }

    isolated deinit { polling?.cancel() }
}
