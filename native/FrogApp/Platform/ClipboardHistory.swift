import AppKit
import Combine

/// Only text and bounded text formatting are retained, never arbitrary clipboard payloads.
struct ClipboardHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let text: String
    let formatting: [String: Data]
    let isSensitive: Bool
    var preview: String { String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ") }

    init(text: String, formatting: [String: Data] = [:], isSensitive: Bool = false, timestamp: Date = Date()) {
        id = UUID(); self.timestamp = timestamp; self.text = text; self.formatting = formatting; self.isSensitive = isSensitive
    }

    func displayPreview(revealed: Bool) -> String {
        !isSensitive || revealed ? preview : "Sensitive text · Click to reveal"
    }

    func write(to pasteboard: NSPasteboard, plainText: Bool) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if isSensitive { item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        if !plainText {
            for (type, data) in formatting { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
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

    func read(after previousCount: Int) -> Observation {
        let pasteboard = NSPasteboard(name: name)
        if Task.isCancelled { return Observation(changeCount: previousCount, entry: nil, retry: false) }
        let state = gate.state
        let count = pasteboard.changeCount
        var entry: ClipboardHistoryEntry?
        var retry = false
        if count != previousCount, !state.suppressed, !gate.ignores(name: name, count: count) {
            let items = pasteboard.pasteboardItems ?? []
            if items.count == 1, let item = items.first {
                let sensitive = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
                    .contains { item.types.contains(NSPasteboard.PasteboardType($0)) }
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
    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var enabled = false
    private let pasteboard: NSPasteboard
    private let reader: ClipboardHistoryReader
    private var changeCount: Int
    private var epoch = UUID()
    private var polling: Task<Void, Never>?
    private var pendingCount: Int?
    private var pendingAttempts = 0
    var retentionGeneration: UUID { epoch }

    init(pasteboard: NSPasteboard = .general, gate: ClipboardHistoryCaptureGate = .shared) {
        self.pasteboard = pasteboard
        reader = ClipboardHistoryReader(name: pasteboard.name, gate: gate)
        changeCount = pasteboard.changeCount
    }

    func configure(enabled: Bool, automaticallyPoll: Bool = true) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled; epoch = UUID()
        pendingCount = nil; pendingAttempts = 0
        polling?.cancel(); polling = nil
        entries = []
        guard enabled else { return }
        // Never ingest the clipboard that predates opt-in.
        changeCount = pasteboard.changeCount
        if automaticallyPoll {
            let reader = reader
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let request = self?.readRequest else { return }
                    // Do not retain the UI store across promised-data IPC, which
                    // AppKit does not expose a cancellation/timeout API for.
                    let observation = await reader.read(after: request.count)
                    guard !Task.isCancelled else { return }
                    self?.receive(observation, epoch: request.epoch)
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

    private func receive(_ observation: ClipboardHistoryReader.Observation, epoch current: UUID) {
        guard enabled, current == epoch else { return }
        if observation.retry {
            if pendingCount != observation.changeCount { pendingCount = observation.changeCount; pendingAttempts = 0 }
            pendingAttempts += 1
            if pendingAttempts < 3 { return }
        }
        pendingCount = nil; pendingAttempts = 0
        changeCount = observation.changeCount
        guard let entry = observation.entry else { return }
        record(entry)
    }

    private func record(_ entry: ClipboardHistoryEntry) {
        guard enabled else { return }
        let sensitive = entry.isSensitive || entries.contains { $0.text == entry.text && $0.formatting == entry.formatting && $0.isSensitive }
        let retained = sensitive == entry.isSensitive ? entry : ClipboardHistoryEntry(text: entry.text, formatting: entry.formatting, isSensitive: sensitive, timestamp: entry.timestamp)
        entries.removeAll { $0.text == entry.text && $0.formatting == entry.formatting }
        entries.insert(retained, at: 0)
        if entries.count > 5 { entries.removeLast(entries.count - 5) }
    }

    /// Explicitly include Frog results even if a subsequent compatibility Copy
    /// temporarily suppresses clipboard polling/restores that same result.
    func recordCopiedText(_ text: String) {
        guard enabled, !text.isEmpty, text.utf8.count <= 512 * 1024 else { return }
        epoch = UUID(); pendingCount = nil; pendingAttempts = 0
        record(ClipboardHistoryEntry(text: text))
        changeCount = pasteboard.changeCount
    }

    @discardableResult
    func copy(_ entry: ClipboardHistoryEntry) -> Bool {
        guard enabled, entries.contains(where: { $0.id == entry.id }) else { return false }
        guard entry.write(to: pasteboard, plainText: false) else { return false }
        epoch = UUID(); pendingCount = nil; pendingAttempts = 0
        record(entry); changeCount = pasteboard.changeCount
        return true
    }

    func delete(id: UUID) {
        epoch = UUID(); entries.removeAll { $0.id == id }
        pendingCount = nil; pendingAttempts = 0
        changeCount = pasteboard.changeCount
    }

    func clear() {
        epoch = UUID(); entries = []
        pendingCount = nil; pendingAttempts = 0
        changeCount = pasteboard.changeCount
    }

    isolated deinit { polling?.cancel() }
}
