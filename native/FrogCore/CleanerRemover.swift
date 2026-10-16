import Foundation
import Darwin

/// A running process the cleaner may have to quit before its files move.
public struct RunningAppInfo: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var bundlePath: String?
    public var id: Int32 { pid }

    public init(pid: Int32, bundleID: String?, name: String, bundlePath: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// Whether macOS lets Frog send Finder Apple Events.
public enum AutomationStatus: Sendable, Equatable { case allowed, notDetermined, denied, unavailable }

/// The Trash, behind a protocol so the whole removal is tested without touching it.
public protocol CleanerTrash: Sendable {
    /// FileManager route. Returns where the item is in the Trash.
    func trash(_ url: URL) async throws -> URL
    /// Finder route: one Apple Event for all URLs, so Finder asks for a password at most once.
    /// Returns the Trash location per URL when Finder reports it.
    func trashWithFinder(_ urls: [URL]) async throws -> [URL?]
    func finderAutomation() async -> AutomationStatus
    /// Moves an item from the Trash back. Throws when the original place is taken.
    func putBack(_ trashed: URL, to original: URL) async throws
}

/// Running apps and launch jobs, behind a protocol so no test quits an app or stops a job.
public protocol CleanerSystemControl: Sendable {
    /// Running processes with one of the bundle IDs, or whose bundle lies inside `bundlePath`.
    func running(bundleIDs: Set<String>, inside bundlePath: String?) async -> [RunningAppInfo]
    /// Asks politely and waits; returns what is still running after the timeout.
    func quit(_ apps: [RunningAppInfo], timeout: Duration) async -> [RunningAppInfo]
    func forceQuit(_ apps: [RunningAppInfo]) async -> [RunningAppInfo]
    /// `launchctl bootout gui/<uid>/<label>`; a job that is not loaded counts as stopped.
    func bootOut(label: String) async throws
    /// nil when it cannot be told.
    func hasFullDiskAccess() async -> Bool?
}

public struct RemovalFailure: Sendable, Equatable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct RemovalOutcome: Sendable, Equatable {
    public var moved: [RemovalRecord.Entry]
    public var failures: [RemovalFailure]
    public var notes: [String]
    public var cancelled: Bool
    public var record: RemovalRecord?
    public var movedBytes: Int64 { moved.reduce(0) { $0 + ($1.bytes ?? 0) } }

    public init(moved: [RemovalRecord.Entry] = [], failures: [RemovalFailure] = [], notes: [String] = [],
                cancelled: Bool = false, record: RemovalRecord? = nil) {
        self.moved = moved
        self.failures = failures
        self.notes = notes
        self.cancelled = cancelled
        self.record = record
    }
}

/// Carries out a `RemovalPlan` in a fixed order: check every item again, quit the app, stop its launch agents,
/// move Finder's items (the app among them) in one batch and the user's items one by one, then save what moved
/// for Put Back.
public struct CleanerRemover: Sendable {
    private let trash: any CleanerTrash
    private let system: any CleanerSystemControl
    private let store: CleanerStore?
    private let safety: CleanerSafety
    private let exists: @Sendable (URL) -> Bool
    private let fileNumber: @Sendable (URL) -> UInt64?
    private let now: @Sendable () -> Date

    /// lstat, so a link counts as there whatever it points to. A path macOS does not let Frog read (the Trash
    /// without Full Disk Access) counts as there too: only "no such file" says for sure that nothing is.
    public static let lstatExists: @Sendable (URL) -> Bool = { url in
        var info = stat()
        return lstat(url.path, &info) == 0 || ![ENOENT, ENOTDIR].contains(errno)
    }

    /// lstat's inode number, or nil when the item is missing.
    public static let lstatFileNumber: @Sendable (URL) -> UInt64? = { url in
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    public init(trash: any CleanerTrash, system: any CleanerSystemControl, store: CleanerStore?,
                safety: CleanerSafety, exists: @escaping @Sendable (URL) -> Bool = CleanerRemover.lstatExists,
                fileNumber: @escaping @Sendable (URL) -> UInt64? = CleanerRemover.lstatFileNumber,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.trash = trash
        self.system = system
        self.store = store
        self.safety = safety
        self.exists = exists
        self.fileNumber = fileNumber
        self.now = now
    }

    static let gone = "It is no longer there."
    public static let needsFullDiskAccess = "Frog needs Full Disk Access to move this item."
    static let notAllowed = "macOS did not allow Frog to move this item."
    static let couldNotMove = "Frog could not move this item."
    public static let automationDenied = "Frog may not control Finder. Allow it in System Settings → Privacy & Security → Automation."
    static let passwordCancelled = "You cancelled the password prompt."
    static let finderCouldNotMove = "Finder could not move this item."
    static let recordNotSaved = "Frog could not save the list for Put Back."
    static let useFinder = "Use Put Back in the Trash in Finder."
    static let placeTaken = "Something else is now at the original place."
    static let leftTheTrash = "It is no longer in the Trash."
    static let folderGone = "The folder it was in is gone."
    static let couldNotPutBack = "Frog could not put this item back."
    static func stillRunning(_ name: String) -> String { "\(name) is still running. Nothing was moved." }
    static func notStopped(_ label: String) -> String { "Frog could not stop \(label). It stops after you log out or restart." }
    static func appStayed(_ name: String) -> String { "\(name) did not move, so Frog left its other files where they are." }

    /// The AppleScript error Finder returns when the user cancels its password prompt.
    private static let userCancelled = -128
    /// errAEEventNotPermitted: the user answered "Don't Allow" when macOS asked whether Frog may control Finder.
    private static let eventNotPermitted = -1743

    private static func finderSentence(for error: Error) -> String {
        switch (error as NSError).code {
        case userCancelled: passwordCancelled
        case eventNotPermitted: automationDenied
        default: finderCouldNotMove
        }
    }

    public func perform(_ plan: RemovalPlan, title: String,
                        confirmForceQuit: @escaping @Sendable ([RunningAppInfo]) async -> Bool,
                        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async -> RemovalOutcome {
        var outcome = RemovalOutcome()

        // 1. Check again: the disk may have changed while the confirmation sheet was open.
        var remaining: [PlannedRemoval] = []
        for removal in plan.removals {
            let item = removal.item
            if !exists(item.url) {
                outcome.failures.append(RemovalFailure(path: item.id, message: Self.gone))
            } else if let reason = safety.refusal(for: item.url, purpose: item.kind == .application ? .application : plan.purpose) {
                outcome.failures.append(RemovalFailure(path: item.id, message: reason))
            } else {
                remaining.append(removal)
            }
        }
        guard !remaining.isEmpty else { return outcome }

        // 2. Quit the app and its helpers, so nothing writes into a folder while it moves.
        if !plan.quitBundleIDs.isEmpty {
            let running = await system.running(bundleIDs: Set(plan.quitBundleIDs), inside: plan.removesApp ? plan.app?.path : nil)
            if !running.isEmpty {
                var still = await system.quit(running, timeout: .seconds(10))
                if !still.isEmpty {
                    guard await confirmForceQuit(still) else { return RemovalOutcome(cancelled: true) }
                    still = await system.forceQuit(still)
                    if !still.isEmpty {
                        let app = still.first { $0.bundleID == plan.app?.bundleID || $0.bundlePath == plan.app?.path }
                        let name = app.flatMap { _ in plan.app?.name } ?? still[0].name
                        let path = app?.bundlePath ?? still[0].bundlePath ?? plan.app?.path ?? ""
                        return RemovalOutcome(failures: [RemovalFailure(path: path, message: Self.stillRunning(name))],
                                              cancelled: true)
                    }
                }
            }
        }

        // 3. Stop the launch agents whose files move; a job left running would start the app again.
        let movingLabels = Set(remaining.filter { $0.item.kind == .launchAgent }.map(\.item.jobLabel))
        for label in plan.launchLabelsToStop where movingLabels.contains(label) {
            do { try await system.bootOut(label: label) } catch { outcome.notes.append(Self.notStopped(label)) }
        }

        let total = remaining.count
        var done = 0
        var askedFullDiskAccess = false, fullDiskAccess: Bool?

        // 4. Finder's items in one Apple Event, so Finder asks for the password at most once. They go first: the
        //    app bundle is one of them, and whether it moves decides whether the rest may.
        let finderItems = remaining.filter { $0.route == .finder }
        if !finderItems.isEmpty {
            if await trash.finderAutomation() == .denied {
                outcome.failures += finderItems.map { RemovalFailure(path: $0.item.id, message: Self.automationDenied) }
            } else {
                var reported: [URL?] = [], failure = Self.finderCouldNotMove
                do {
                    reported = try await trash.trashWithFinder(finderItems.map(\.item.url))
                } catch {
                    failure = Self.finderSentence(for: error)
                    reported = []
                }
                // Finder can move some items of one event and then stop, so the disk says what moved.
                for (index, removal) in finderItems.enumerated() {
                    if exists(removal.item.url) {
                        outcome.failures.append(RemovalFailure(path: removal.item.id, message: failure))
                    } else {
                        let trashed = index < reported.count ? reported[index] : nil
                        outcome.moved.append(entry(removal, trashed: trashed?.path))
                    }
                }
            }
            done += finderItems.count
            progress(done, total)
        }

        // 5. The user's own items, one at a time, so one failure leaves the rest moving. An app that stayed keeps
        //    its settings and caches too, so a cancelled password prompt never leaves it installed but reset.
        let userItems = remaining.filter { $0.route == .fileManager }
        if let app = plan.removals.first(where: { $0.item.kind == .application }), exists(app.item.url), !userItems.isEmpty {
            outcome.notes.append(Self.appStayed(plan.app?.name ?? app.item.url.deletingPathExtension().lastPathComponent))
        } else {
            for removal in userItems {
                let item = removal.item
                do {
                    let trashed = try await trash.trash(item.url)
                    outcome.moved.append(entry(removal, trashed: trashed.path))
                } catch {
                    if !askedFullDiskAccess, Self.isPermissionError(error) {
                        askedFullDiskAccess = true
                        fullDiskAccess = await system.hasFullDiskAccess()
                    }
                    outcome.failures.append(RemovalFailure(path: item.id, message: sentence(for: error, item: item,
                                                                                             fullDiskAccess: fullDiskAccess)))
                }
                done += 1
                progress(done, total)
            }
        }

        // 6. Remember what moved, for Put Back.
        outcome.moved.sort { $0.original < $1.original }
        outcome.failures.sort { $0.path < $1.path }
        if !outcome.moved.isEmpty {
            let date = now()
            let record = RemovalRecord(id: UUID(), date: date, title: title, entries: outcome.moved)
            outcome.record = record
            do { try store?.add(record, now: date) } catch { outcome.notes.append(Self.recordNotSaved) }
        }
        return outcome
    }

    /// Puts back what Frog may restore itself and explains the rest. The changed record is saved.
    public func putBack(_ record: RemovalRecord) async -> (record: RemovalRecord, failures: [RemovalFailure]) {
        var record = record, failures: [RemovalFailure] = []
        for index in record.entries.indices where !record.entries[index].restored {
            let entry = record.entries[index]
            let original = URL(fileURLWithPath: entry.original)
            guard entry.restorable, let trashed = entry.trashed else {
                failures.append(RemovalFailure(path: entry.original, message: Self.useFinder))
                continue
            }
            // The Trash was emptied, or the item was dragged out of it, or another item now has its name there.
            guard isInTrash(entry) else {
                failures.append(RemovalFailure(path: entry.original, message: Self.leftTheTrash))
                continue
            }
            if exists(original) {
                failures.append(RemovalFailure(path: entry.original, message: Self.placeTaken))
                continue
            }
            guard exists(original.deletingLastPathComponent()) else {
                failures.append(RemovalFailure(path: entry.original, message: Self.folderGone))
                continue
            }
            do {
                try await trash.putBack(URL(fileURLWithPath: trashed), to: original)
                record.entries[index].restored = true
            } catch {
                failures.append(RemovalFailure(path: entry.original, message: Self.couldNotPutBack))
            }
        }
        // What moved back stays moved back; a list that cannot be saved only offers it again.
        try? store?.replace(record)
        return (record, failures)
    }

    /// False when the item Frog moved is no longer at its place in the Trash: the place is empty, or it holds an
    /// item with another file number. True when Frog does not know the place or cannot read it, since it cannot
    /// tell then.
    public func isInTrash(_ entry: RemovalRecord.Entry) -> Bool {
        guard let trashed = entry.trashed.map({ URL(fileURLWithPath: $0) }) else { return true }
        guard exists(trashed) else { return false }
        guard let expected = entry.fileNumber, let found = fileNumber(trashed) else { return true }
        return found == expected
    }

    private func entry(_ removal: PlannedRemoval, trashed: String?) -> RemovalRecord.Entry {
        RemovalRecord.Entry(original: removal.item.id, trashed: trashed, bytes: removal.item.size, route: removal.route,
                            owner: removal.item.owner, fileNumber: trashed.flatMap { fileNumber(URL(fileURLWithPath: $0)) })
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        return error.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(error.code))
    }

    private func sentence(for error: Error, item: CleanerItem, fullDiskAccess: Bool?) -> String {
        if Self.isPermissionError(error) {
            // Full Disk Access only helps with protected places, and only when Frog does not have it yet.
            let protected = item.needsFullDiskAccess || [.container, .groupContainer].contains(item.kind)
            return protected && fullDiskAccess != true ? Self.needsFullDiskAccess : Self.notAllowed
        }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) {
            return Self.gone
        }
        if error.domain == NSPOSIXErrorDomain, Int32(error.code) == ENOENT { return Self.gone }
        return Self.couldNotMove
    }
}
