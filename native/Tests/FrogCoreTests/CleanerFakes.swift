import Foundation
@testable import FrogCore

/// One call log both fakes write to, so a test sees the order of steps across the Trash and the system.
final class CleanerCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func append(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

/// Moves items into `<folder>` instead of the Trash, with Finder's " 2" on a name clash.
actor FakeCleanerTrash: CleanerTrash {
    let folder: URL
    let log: CleanerCallLog
    private(set) var automation: AutomationStatus = .allowed
    private var failures: [String: any Error] = [:]
    private var finderFailure: (moved: Int, error: any Error)?
    private var finderReportsLocations = true

    init(folder: URL, log: CleanerCallLog = CleanerCallLog()) {
        self.folder = folder
        self.log = log
    }

    func fail(_ url: URL, with error: any Error) { failures[url.standardizedFileURL.path] = error }
    /// The next Finder call moves the first `moved` items and then throws.
    func failFinder(after moved: Int, with error: any Error) { finderFailure = (moved, error) }
    func setAutomation(_ status: AutomationStatus) { automation = status }
    func setFinderReportsLocations(_ value: Bool) { finderReportsLocations = value }

    func trash(_ url: URL) async throws -> URL {
        log.append("trash \(url.lastPathComponent)")
        if let error = failures[url.standardizedFileURL.path] { throw error }
        return try move(url)
    }

    func trashWithFinder(_ urls: [URL]) async throws -> [URL?] {
        log.append("finder " + urls.map(\.lastPathComponent).joined(separator: ","))
        if let failure = finderFailure {
            finderFailure = nil
            for url in urls.prefix(failure.moved) { _ = try move(url) }
            throw failure.error
        }
        let moved = try urls.map { try move($0) }
        return finderReportsLocations ? moved : urls.map { _ in nil }
    }

    func finderAutomation() async -> AutomationStatus {
        log.append("automation")
        return automation
    }

    func putBack(_ trashed: URL, to original: URL) async throws {
        log.append("putBack \(original.lastPathComponent)")
        if let error = failures[trashed.standardizedFileURL.path] { throw error }
        guard !FileManager.default.fileExists(atPath: original.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    private func move(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent, suffix = url.pathExtension
        var target = folder.appendingPathComponent(url.lastPathComponent), number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(suffix.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(suffix)")
            number += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

/// A pretend set of running apps and launch jobs.
actor FakeCleanerSystem: CleanerSystemControl {
    let log: CleanerCallLog
    private var apps: [RunningAppInfo] = []
    private var survivingQuit = 0, survivingForceQuit = 0
    private var failingBootOuts: Set<String> = []
    private var fullDiskAccess: Bool?

    init(log: CleanerCallLog = CleanerCallLog()) { self.log = log }

    func setRunning(_ apps: [RunningAppInfo]) { self.apps = apps }
    /// How many of the apps asked to quit are still running afterwards.
    func setSurvivors(quit: Int, forceQuit: Int = 0) { survivingQuit = quit; survivingForceQuit = forceQuit }
    func failBootOut(_ label: String) { failingBootOuts.insert(label) }
    func setFullDiskAccess(_ value: Bool?) { fullDiskAccess = value }

    func running(bundleIDs: Set<String>, inside bundlePath: String?) async -> [RunningAppInfo] {
        log.append("running")
        return apps.filter { app in
            app.bundleID.map(bundleIDs.contains) == true
                || (bundlePath != nil && app.bundlePath.map { $0 == bundlePath! || $0.hasPrefix(bundlePath! + "/") } == true)
        }
    }

    func quit(_ apps: [RunningAppInfo], timeout: Duration) async -> [RunningAppInfo] {
        log.append("quit " + apps.map(\.name).joined(separator: ","))
        return Array(apps.prefix(survivingQuit))
    }

    func forceQuit(_ apps: [RunningAppInfo]) async -> [RunningAppInfo] {
        log.append("forceQuit " + apps.map(\.name).joined(separator: ","))
        return Array(apps.prefix(survivingForceQuit))
    }

    func bootOut(label: String) async throws {
        log.append("bootOut \(label)")
        if failingBootOuts.contains(label) { throw POSIXError(.EPERM) }
    }

    func hasFullDiskAccess() async -> Bool? {
        log.append("fullDiskAccess")
        return fullDiskAccess
    }
}
