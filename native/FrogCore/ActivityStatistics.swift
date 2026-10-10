import Foundation
import Darwin

/// Fixed categories only: never persist rule names, model IDs, text, or target applications.
public enum ActivityRuleKind: String, Codable, CaseIterable, Sendable {
    case local, remote, cli, dictation, application, window, system
}

public enum ActivityToolKind: String, Codable, CaseIterable, Sendable {
    case clipboardPaste, applicationCommand, windowCommand, systemCommand
    case commandSelection, scriptRun, snippetCopy
}

/// Call once at the successful completion boundary, not on start or keyboard input.
public enum ActivityStatisticsEvent: Sendable {
    case rule(ActivityRuleKind)
    case dictation(recordingSeconds: Double, words: Int)
    case tool(ActivityToolKind)
}

public struct ActivityStatisticsTotals: Codable, Equatable, Sendable {
    public private(set) var dictations = 0
    public private(set) var recordingSeconds: Double = 0
    public private(set) var words = 0
    private var rules: [ActivityRuleKind: Int] = [:]
    private var tools: [ActivityToolKind: Int] = [:]

    public init() {}
    public var ruleRuns: Int { rules.values.reduce(0, +) }
    public var wordsPerMinute: Double? { recordingSeconds > 0 ? Double(words) * 60 / recordingSeconds : nil }
    public func ruleRuns(_ kind: ActivityRuleKind) -> Int { rules[kind, default: 0] }
    public func toolUses(_ kind: ActivityToolKind) -> Int { tools[kind, default: 0] }

    // Saturating bounds also keep aggregation of 365 decoded daily buckets safe.
    private static let maximumCount = 1_000_000_000_000
    private static let maximumSeconds = 1_000_000_000_000.0
    fileprivate var isValid: Bool {
        ([dictations, words] + Array(rules.values) + Array(tools.values)).allSatisfy { (0...Self.maximumCount).contains($0) }
            && recordingSeconds.isFinite && (0...Self.maximumSeconds).contains(recordingSeconds)
    }
    fileprivate mutating func add(_ other: Self) {
        dictations = min(Self.maximumCount, dictations + other.dictations)
        words = min(Self.maximumCount, words + other.words)
        recordingSeconds = min(Self.maximumSeconds, recordingSeconds + other.recordingSeconds)
        for (kind, count) in other.rules { rules[kind] = min(Self.maximumCount, rules[kind, default: 0] + count) }
        for (kind, count) in other.tools { tools[kind] = min(Self.maximumCount, tools[kind, default: 0] + count) }
    }
    fileprivate init(event: ActivityStatisticsEvent) throws {
        self.init()
        switch event {
        case .rule(let kind): rules[kind] = 1
        case .tool(let kind): tools[kind] = 1
        case .dictation(let seconds, let count):
            guard seconds.isFinite, seconds > 0, seconds <= Self.maximumSeconds,
                  count > 0, count <= Self.maximumCount else {
                throw FrogError.message("Statistics require a positive recording duration and word count.")
            }
            dictations = 1; recordingSeconds = seconds; words = count
        }
    }
}

public struct ActivityStatisticsSnapshot: Codable, Equatable, Sendable {
    public private(set) var version = 1
    public private(set) var recordingEnabled = true
    public private(set) var allTime = ActivityStatisticsTotals()
    /// Gregorian civil dates in the device's time zone when the action completed.
    public private(set) var daily: [String: ActivityStatisticsTotals] = [:]

    public init() {}

    /// Includes today; empty days contribute zero. All-time totals survive daily pruning.
    public func totals(lastDays: Int, endingAt date: Date = Date(), timeZone: TimeZone = .current) -> ActivityStatisticsTotals {
        let range = Self.dayRange(days: min(365, max(1, lastDays)), date: date, timeZone: timeZone)
        return daily.filter { range.contains($0.key) }.values.reduce(into: ActivityStatisticsTotals()) { $0.add($1) }
    }

    /// Uses native Unicode word segmentation; punctuation and emoji alone are not words.
    /// The text is used transiently and is never passed to persistence.
    public static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word, word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { count += 1 }
        }
        return count
    }

    fileprivate mutating func record(_ event: ActivityStatisticsEvent, at date: Date, timeZone: TimeZone) throws {
        guard recordingEnabled else { return }
        let delta = try ActivityStatisticsTotals(event: event)
        allTime.add(delta)
        daily[Self.dayKey(date, timeZone: timeZone), default: ActivityStatisticsTotals()].add(delta)
        prune(at: date, timeZone: timeZone)
    }
    fileprivate mutating func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }
    fileprivate mutating func prune(at date: Date, timeZone: TimeZone) {
        let range = Self.dayRange(days: 365, date: date, timeZone: timeZone)
        daily = daily.filter { range.contains($0.key) }
    }
    fileprivate var isValid: Bool {
        version == 1 && allTime.isValid && daily.count <= 365 && daily.allSatisfy { key, value in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard key.count == 10, parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  Self.dayKey(date, timeZone: calendar.timeZone) == key else { return false }
            return value.isValid
        }
    }
    private static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private static func dayRange(days: Int, date: Date, timeZone: TimeZone) -> ClosedRange<String> {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: date)!
        return dayKey(first, timeZone: timeZone)...dayKey(date, timeZone: timeZone)
    }
}

private let activityStatisticsLock = NSLock()

/// Small, independent device-local file. All read/modify/write transactions are serialized.
/// Corrupt/unsupported data is preserved until the user explicitly resets statistics.
public final class ActivityStatisticsPersistence: @unchecked Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("statistics.json") }
    private let maximumBytes = 1_024 * 1_024

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Frog", isDirectory: true)
    }

    public func load(at date: Date = Date(), timeZone: TimeZone = .current) throws -> ActivityStatisticsSnapshot {
        activityStatisticsLock.lock(); defer { activityStatisticsLock.unlock() }
        var result = try read()
        result.prune(at: date, timeZone: timeZone)
        return result
    }

    @discardableResult
    public func record(_ event: ActivityStatisticsEvent, at date: Date = Date(), timeZone: TimeZone = .current) throws -> ActivityStatisticsSnapshot {
        activityStatisticsLock.lock(); defer { activityStatisticsLock.unlock() }
        var result = try read()
        guard result.recordingEnabled else { return result }
        try result.record(event, at: date, timeZone: timeZone)
        try write(result)
        return result
    }

    @discardableResult
    public func setRecordingEnabled(_ enabled: Bool, at date: Date = Date(), timeZone: TimeZone = .current) throws -> ActivityStatisticsSnapshot {
        activityStatisticsLock.lock(); defer { activityStatisticsLock.unlock() }
        var result = try read()
        result.setRecordingEnabled(enabled)
        result.prune(at: date, timeZone: timeZone)
        try write(result)
        return result
    }

    /// Clears every counter while preserving the supplied device-local recording choice.
    /// This is the only operation allowed to replace corrupt or future-version statistics.
    @discardableResult
    public func reset(recordingEnabled: Bool) throws -> ActivityStatisticsSnapshot {
        activityStatisticsLock.lock(); defer { activityStatisticsLock.unlock() }
        var result = ActivityStatisticsSnapshot()
        result.setRecordingEnabled(recordingEnabled)
        try write(result)
        return result
    }

    private func read() throws -> ActivityStatisticsSnapshot {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return ActivityStatisticsSnapshot() }
            throw FrogError.message("Could not read local statistics. The original file was preserved.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumBytes else {
            throw FrogError.message("Unsupported statistics file. Reset statistics to start again.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximumBytes else { throw FrogError.message("Could not read local statistics safely.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let result = try? JSONDecoder().decode(ActivityStatisticsSnapshot.self, from: data), result.isValid else {
            throw FrogError.message("Local statistics could not be opened. The original file was preserved; reset statistics to start again.")
        }
        return result
    }

    private func write(_ snapshot: ActivityStatisticsSnapshot) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw FrogError.message("Local statistics are too large to save.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw FrogError.message("Could not open the local statistics directory safely.")
        }
        let temporary = directory.appendingPathComponent(".statistics-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FrogError.message("Could not create a private statistics file.") }
        defer { close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FrogError.message("Could not save local statistics.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else {
            throw FrogError.message("Could not finish saving local statistics. Previous statistics were preserved.")
        }
    }
}
