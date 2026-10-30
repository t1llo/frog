import Foundation
import FrogCore
@testable import FrogApp

/// A fake home and system root under the temporary folder, with every leftover location and both Applications
/// folders. The roots keep the temporary folder's `/var` spelling, so tests also exercise `CleanerRoots.resolved(_:)`.
/// A copy of the FrogCore tests' fixture, which this target cannot see.
struct CleanerFixture {
    let root: URL, home: URL, system: URL
    var roots: CleanerRoots { CleanerRoots(home: home, system: system) }
    var applications: URL { system.appendingPathComponent("Applications", isDirectory: true) }
    var homeApplications: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    var appleApplications: URL { system.appendingPathComponent("System/Applications", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-cleaner-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        system = root.appendingPathComponent("system", isDirectory: true)
        for location in LeftoverLocation.allCases {
            for domain in location.domains {
                let library = domain == .user ? home : system
                try FileManager.default.createDirectory(at: library.appendingPathComponent("Library/" + location.relativePath, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
        }
        for folder in [applications, homeApplications, appleApplications] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A bundle with an Info.plist, an empty executable and `payload` bytes of resources, in the system
    /// Applications folder unless `folder` is given.
    @discardableResult
    func app(_ name: String, bundleID: String, in folder: URL? = nil, bundleName: String? = nil, payload: Int = 0) throws -> URL {
        let bundle = (folder ?? applications).appendingPathComponent(name + ".app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": bundleName ?? name,
                                    "CFBundleShortVersionString": "1.0", "CFBundleExecutable": name]
        try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  to: contents.appendingPathComponent("Info.plist"))
        try write(Data(), to: contents.appendingPathComponent("MacOS/" + name))
        if payload > 0 { try write(Data(count: payload), to: contents.appendingPathComponent("Resources/payload")) }
        return bundle
    }

    /// A folder holding `bytes` in one file (or nothing), in a leftover location of the user's Library.
    @discardableResult
    func item(_ location: LeftoverLocation, _ name: String, bytes: Int = 0) throws -> URL {
        let url = home.appendingPathComponent("Library/" + location.relativePath, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if bytes > 0 { try write(Data(count: bytes), to: url.appendingPathComponent("data")) }
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

extension CleanerDependencies {
    /// The cleaner inside a fixture: roots below `root`, fake Trash and system, the store in `root`. The catalogue
    /// lists the apps directly inside the fixture's Applications folders unless `applications` is given.
    static func fake(root: URL, trash: (any CleanerTrash)? = nil, system: (any CleanerSystemControl)? = nil,
                     signatures: any CodeSignatureReading = NoCodeSignatures(), applications: [URL]? = nil,
                     protectedPaths: [URL] = []) -> CleanerDependencies {
        let roots = CleanerRoots(home: root.appendingPathComponent("home", isDirectory: true),
                                 system: root.appendingPathComponent("system", isDirectory: true))
        let folders = [root.appendingPathComponent("system/Applications"), root.appendingPathComponent("home/Applications"),
                       root.appendingPathComponent("system/System/Applications")]
        return CleanerDependencies(
            roots: roots, safety: CleanerSafety(roots: roots, protectedPaths: protectedPaths),
            inspector: AppBundleInspector(signatures: signatures),
            trash: trash ?? FakeCleanerTrash(folder: root.appendingPathComponent("Trash", isDirectory: true)),
            system: system ?? FakeCleanerSystem(),
            store: CleanerStore(directory: root.appendingPathComponent("data/Cleaner", isDirectory: true)),
            applications: {
                applications ?? folders.flatMap { folder in
                    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                        .filter { $0.hasSuffix(".app") }
                        .map { folder.appendingPathComponent($0, isDirectory: true) }
                }
            },
            displayName: { $0.deletingPathExtension().lastPathComponent },
            ownBundleID: "xyz.beffa.frog")
    }
}

/// Code signatures by bundle file name.
struct FakeCodeSignatures: CodeSignatureReading {
    var signatures: [String: CodeSignatureInfo]
    func signature(of bundle: URL) -> CodeSignatureInfo? { signatures[bundle.lastPathComponent] }
}

/// Holds callers until it is opened, so a test can act while the model waits.
actor CleanerGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    var waiters: Int { waiting.count }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// One call log both fakes write to, so a test sees the order of steps across the Trash and the system.
final class CleanerCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func append(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

/// Moves items into `folder` instead of the Trash, with Finder's " 2" on a name clash.
actor FakeCleanerTrash: CleanerTrash {
    let folder: URL
    let log: CleanerCallLog
    private var failing: Set<String> = []
    private var automation = AutomationStatus.allowed

    init(folder: URL, log: CleanerCallLog = CleanerCallLog()) {
        self.folder = folder
        self.log = log
    }

    /// `trash` refuses this item as macOS does without the needed permission.
    func fail(_ url: URL) { failing.insert(url.standardizedFileURL.path) }
    func setAutomation(_ status: AutomationStatus) { automation = status }

    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Moves wait until `release`, so a test can act while a removal is under way.
    func hold() { holding = true }
    func release() { holding = false; held.forEach { $0.resume() }; held = [] }
    private func waitWhileHeld() async { if holding { await withCheckedContinuation { held.append($0) } } }

    func trash(_ url: URL) async throws -> URL {
        await waitWhileHeld()
        log.append("trash \(url.lastPathComponent)")
        if failing.contains(url.standardizedFileURL.path) { throw CocoaError(.fileWriteNoPermission) }
        return try move(url)
    }

    func trashWithFinder(_ urls: [URL]) async throws -> [URL?] {
        await waitWhileHeld()
        log.append("finder " + urls.map(\.lastPathComponent).joined(separator: ","))
        return try urls.map { try move($0) }
    }

    func finderAutomation() async -> AutomationStatus { automation }

    func putBack(_ trashed: URL, to original: URL) async throws {
        log.append("putBack \(original.lastPathComponent)")
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    private func move(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(url.lastPathComponent), number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(number)")
            number += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

/// A pretend set of running apps; nothing is quit for real.
actor FakeCleanerSystem: CleanerSystemControl {
    let log: CleanerCallLog
    private var apps: [RunningAppInfo] = []
    private var survivingQuit = 0, survivingForceQuit = 0
    private var fullDiskAccess: Bool?
    private var fullDiskAccessGate: CleanerGate?

    init(log: CleanerCallLog = CleanerCallLog()) { self.log = log }

    func setRunning(_ apps: [RunningAppInfo]) { self.apps = apps }
    /// How many of the apps asked to quit are still running afterwards.
    func setSurvivors(quit: Int, forceQuit: Int = 0) { survivingQuit = quit; survivingForceQuit = forceQuit }
    func setFullDiskAccess(_ value: Bool?) { fullDiskAccess = value }
    /// The next Full Disk Access questions wait for the gate.
    func holdFullDiskAccess(at gate: CleanerGate) { fullDiskAccessGate = gate }

    func running(bundleIDs: Set<String>, inside bundlePath: String?) async -> [RunningAppInfo] {
        log.append("running")
        return apps.filter { app in
            app.bundleID.map(bundleIDs.contains) == true
                || (bundlePath.map { path in app.bundlePath.map { $0 == path || $0.hasPrefix(path + "/") } ?? false } ?? false)
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

    func bootOut(label: String) async throws { log.append("bootOut \(label)") }

    func hasFullDiskAccess() async -> Bool? {
        log.append("fullDiskAccess")
        if let fullDiskAccessGate { await fullDiskAccessGate.wait() }
        return fullDiskAccess
    }
}
