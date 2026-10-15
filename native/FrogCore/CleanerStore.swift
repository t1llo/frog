import Foundation
import Darwin

/// One "Move to Trash" that moved something, so the user can put the items back.
public struct RemovalRecord: Codable, Identifiable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var original: String
        /// nil when Finder did not report where the item went.
        public var trashed: String?
        public var bytes: Int64?
        public var route: TrashRoute
        /// The item's owner when it moved.
        public var owner: CleanerOwner
        public var restored: Bool
        /// Frog can put it back itself: it knows the Trash location and the item was the user's.
        /// Administrator items need Finder's Put Back (moving them back needs the password).
        public var restorable: Bool { trashed != nil && owner == .user }

        public init(original: String, trashed: String?, bytes: Int64?, route: TrashRoute, owner: CleanerOwner,
                    restored: Bool = false) {
            self.original = original
            self.trashed = trashed
            self.bytes = bytes
            self.route = route
            self.owner = owner
            self.restored = restored
        }
    }

    public var id: UUID
    public var date: Date
    /// "Slack", or "12 items".
    public var title: String
    public var entries: [Entry]

    public init(id: UUID = UUID(), date: Date, title: String, entries: [Entry]) {
        self.id = id
        self.date = date
        self.title = title
        self.entries = entries
    }
}

/// Serializes read/modify/write of the cleaner's files across store instances in this process.
private let cleanerLock = NSLock()

/// Machine-local cleaner state in `<data directory>/Cleaner`. It is never exported or synced. Later parts of the
/// cleaner add their own files in their own `MARK` section.
public final class CleanerStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Reads a private JSON file. A file that cannot be read or decoded is set aside as
    /// `<name>-unreadable-<UUID>.json` and counts as missing, so one bad file never blocks the cleaner.
    private func load<T: Decodable>(_ type: T.Type, from file: URL, maximumBytes: Int) throws -> T? {
        do {
            guard let data = try PrivateFile.read(file, maximumBytes: maximumBytes) else { return nil }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let name = file.deletingPathExtension().lastPathComponent
            let aside = directory.appendingPathComponent("\(name)-unreadable-\(UUID().uuidString).json")
            guard rename(file.path, aside.path) == 0 else {
                throw FrogError.message("Frog could not read \(file.lastPathComponent).")
            }
            return nil
        }
    }

    // MARK: - Removals

    private var removalsFile: URL { directory.appendingPathComponent("removals.json") }
    private static let removalsMaximumBytes = 4 * 1_024 * 1_024
    static let maximumRecords = 100
    static let maximumAge: TimeInterval = 30 * 86_400

    /// Newest first. Records older than 30 days are dropped, and at most 100 are kept.
    public func records(now: Date = Date()) throws -> [RemovalRecord] {
        cleanerLock.lock(); defer { cleanerLock.unlock() }
        let stored = try readRecords()
        let kept = bounded(stored, now: now)
        // Expired records leave the disk too, not only the list.
        if kept != stored { return try writeRecords(kept) }
        return kept
    }

    public func add(_ record: RemovalRecord, now: Date = Date()) throws {
        cleanerLock.lock(); defer { cleanerLock.unlock() }
        var records = try readRecords().filter { $0.id != record.id }
        records.append(record)
        _ = try writeRecords(bounded(records, now: now))
    }

    /// Saves a changed record, such as one with items put back. A record that has expired stays gone.
    public func replace(_ record: RemovalRecord) throws {
        cleanerLock.lock(); defer { cleanerLock.unlock() }
        var records = try readRecords()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        _ = try writeRecords(records)
    }

    public func delete(id: UUID) throws {
        cleanerLock.lock(); defer { cleanerLock.unlock() }
        let records = try readRecords()
        let kept = records.filter { $0.id != id }
        if kept != records { _ = try writeRecords(kept) }
    }

    private func readRecords() throws -> [RemovalRecord] {
        try load([RemovalRecord].self, from: removalsFile, maximumBytes: Self.removalsMaximumBytes) ?? []
    }

    /// Writes the records, newest first, leaving out the oldest while the file would pass its limit.
    private func writeRecords(_ records: [RemovalRecord]) throws -> [RemovalRecord] {
        var kept = records
        var data = try JSONEncoder().encode(kept)
        while data.count > Self.removalsMaximumBytes, kept.count > 1 {
            kept.removeLast()
            data = try JSONEncoder().encode(kept)
        }
        guard data.count <= Self.removalsMaximumBytes else { throw FrogError.message("The list for Put Back is too large to save.") }
        try PrivateFile.write(data, to: removalsFile)
        return kept
    }

    private func bounded(_ records: [RemovalRecord], now: Date) -> [RemovalRecord] {
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        return Array(records.filter { $0.date >= cutoff }
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
            .prefix(Self.maximumRecords))
    }

    // MARK: - Flags

    private var stateFile: URL { directory.appendingPathComponent("state.json") }
    private static let stateMaximumBytes = 64 * 1_024

    /// Small switches for notices the user dismissed on this Mac, stored in state.json.
    public func flag(_ name: String) -> Bool {
        cleanerLock.lock(); defer { cleanerLock.unlock() }
        guard let data = try? PrivateFile.read(stateFile, maximumBytes: Self.stateMaximumBytes),
              let flags = try? JSONDecoder().decode([String: Bool].self, from: data) else { return false }
        return flags[name] ?? false
    }

    public func setFlag(_ name: String, _ value: Bool) throws {
        cleanerLock.lock(); defer { cleanerLock.unlock() }
        var flags = try load([String: Bool].self, from: stateFile, maximumBytes: Self.stateMaximumBytes) ?? [:]
        guard flags[name] != (value ? true : nil) else { return }
        // A switch that is off is left out, so the file only lists what the user turned on.
        flags[name] = value ? true : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try PrivateFile.write(try encoder.encode(flags), to: stateFile)
    }
}
