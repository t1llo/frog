import AppKit
import Darwin
import FrogCore

/// Running apps, launch jobs and Full Disk Access, for the cleaner. Quitting asks first and waits;
/// launch jobs stop through `/bin/launchctl` with fixed arguments in the user's own domain only.
struct SystemCleanerControl: CleanerSystemControl {
    func running(bundleIDs: Set<String>, inside bundlePath: String?) async -> [RunningAppInfo] {
        let own = getpid()
        return await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                let paths = [app.bundleURL?.path, app.executableURL?.path].compactMap { $0 }
                guard Self.matches(pid: app.processIdentifier, bundleID: app.bundleIdentifier, paths: paths,
                                   bundleIDs: bundleIDs, inside: bundlePath, ownPID: own) else { return nil }
                let name = app.localizedName ?? app.executableURL?.lastPathComponent ?? app.bundleIdentifier ?? "\(app.processIdentifier)"
                return RunningAppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: name,
                                      bundlePath: app.bundleURL?.path)
            }
        }
    }

    func quit(_ apps: [RunningAppInfo], timeout: Duration) async -> [RunningAppInfo] {
        await stop(apps, within: timeout) { $0.terminate() }
    }

    func forceQuit(_ apps: [RunningAppInfo]) async -> [RunningAppInfo] {
        await stop(apps, within: .seconds(3)) { $0.forceTerminate() }
    }

    func bootOut(label: String) async throws {
        let refused = FrogError.message("Frog cannot stop this service.")
        guard let arguments = LaunchJobCommand.bootout(label: label, uid: getuid()) else { throw refused }
        let result: (status: Int32, output: String)
        do { result = try await CleanerProcessRunner.run("/bin/launchctl", arguments) } catch { throw refused }
        guard LaunchJobCommand.stopped(status: result.status) else { throw refused }
    }

    func hasFullDiskAccess() async -> Bool? {
        await Task.detached(priority: .utility) {
            FullDiskAccessProbe.run(home: FileManager.default.homeDirectoryForCurrentUser)
        }.value
    }

    /// A process belongs to the app when its bundle ID is one of the app's or its bundle or executable lies
    /// inside the app's bundle. Frog never quits itself.
    static func matches(pid: pid_t, bundleID: String?, paths: [String], bundleIDs: Set<String>, inside bundlePath: String?,
                        ownPID: pid_t) -> Bool {
        guard pid != ownPID, pid > 0 else { return false }
        if let bundleID, bundleIDs.contains(bundleID) { return true }
        guard let bundlePath, !bundlePath.isEmpty else { return false }
        let folder = Self.normalized(bundlePath)
        return paths.contains { path in
            let path = Self.normalized(path)
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    private static func normalized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        if let real = realpath(path, nil) {
            path = String(cString: real)
            free(real)
        }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Sends `action` to each app, then checks every 100 ms until all are gone or the time is up.
    private func stop(_ apps: [RunningAppInfo], within timeout: Duration,
                      _ action: @escaping (NSRunningApplication) -> Void) async -> [RunningAppInfo] {
        let own = getpid()
        let targets = apps.filter { $0.pid != own && $0.pid > 0 }
        await MainActor.run {
            for app in targets { NSRunningApplication(processIdentifier: app.pid).map(action) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var remaining = targets.filter(Self.isRunning)
        while !remaining.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            remaining = remaining.filter(Self.isRunning)
        }
        return remaining
    }

    private static func isRunning(_ app: RunningAppInfo) -> Bool {
        if kill(app.pid, 0) != 0, errno == ESRCH { return false }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        return !running.isTerminated
    }
}

enum LaunchJobCommand {
    private static let maximumLabelLength = 255

    /// ["bootout", "gui/<uid>/<label>"], or nil for a label that is empty, longer than 255
    /// characters or contains anything but letters, digits, ".", "_" and "-".
    static func bootout(label: String, uid: uid_t) -> [String]? {
        guard isValid(label) else { return nil }
        return ["bootout", "gui/\(uid)/\(label)"]
    }

    /// Exit status 0, 3 ("No such process") and 113 ("Could not find service") mean stopped.
    static func stopped(status: Int32) -> Bool { [0, 3, 113].contains(status) }

    static func isValid(_ label: String) -> Bool {
        guard !label.isEmpty, label.unicodeScalars.count <= maximumLabelLength else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": true
            default: false
            }
        }
    }
}

/// Whether Frog has Full Disk Access, told by trying to open places only that access opens. Files open
/// read-only and close at once; nothing is read from them, and nothing asks the user.
enum FullDiskAccessProbe {
    /// The probe order from the research: open /Library/Preferences/com.apple.TimeMachine.plist, then
    /// ~/Library/Safari/Bookmarks.plist read-only, then list ~/Library/Mail. Success → true;
    /// EPERM or EACCES → false; ENOENT → try the next; all ENOENT → nil.
    static func evaluate(_ results: [Int32]) -> Bool? {
        for result in results {
            if result == 0 { return true }
            if result == EPERM || result == EACCES { return false }
        }
        return nil
    }

    static func run(home: URL) -> Bool? {
        let probes: [() -> Int32] = [
            { openFile("/Library/Preferences/com.apple.TimeMachine.plist") },
            { openFile(home.appendingPathComponent("Library/Safari/Bookmarks.plist").path) },
            { listFolder(home.appendingPathComponent("Library/Mail").path) }
        ]
        // Stops at the first answer, so later places are not touched when the first one tells.
        var results: [Int32] = []
        for probe in probes {
            results.append(probe())
            if let answer = evaluate(results) { return answer }
        }
        return evaluate(results)
    }

    private static func openFile(_ path: String) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        return 0
    }

    private static func listFolder(_ path: String) -> Int32 {
        guard let folder = opendir(path) else { return errno }
        defer { closedir(folder) }
        errno = 0
        if readdir(folder) == nil, errno != 0 { return errno }
        return 0
    }
}

/// Runs a fixed system tool without a shell: an absolute executable, fixed arguments, `LC_ALL=C`, output
/// capped, terminated at the timeout and killed one second later.
enum CleanerProcessRunner {
    enum Failure: Error, Equatable { case notAbsolute, timedOut }

    static let outputLimit = 64 * 1024

    /// Absolute executable, fixed arguments, no shell, LC_ALL=C, output capped at 64 KB,
    /// terminate at the timeout and SIGKILL one second later.
    static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(5)) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try runSynchronously(executable, arguments, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runSynchronously(_ executable: String, _ arguments: [String], timeout: Duration) throws -> (status: Int32, output: String) {
        guard executable.hasPrefix("/") else { throw Failure.notAbsolute }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // The pipe is drained on its own thread, so a chatty tool never blocks on a full pipe; past the
        // limit the bytes are dropped.
        let output = CappedOutput(limit: outputLimit)
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            // `read(upToCount:)` throws instead of raising an exception, and is nil at the end.
            while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                output.append(chunk)
            }
            drained.signal()
        }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if exited.wait(timeout: .now() + max(0, seconds)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 1)
            }
            throw Failure.timedOut
        }
        // A child the tool left behind may hold the pipe open; take what arrived.
        _ = drained.wait(timeout: .now() + 1)
        return (process.terminationStatus, output.text)
    }
}

/// Bytes up to a limit, shared between the reading thread and the caller.
final class CappedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - data.count
        if room > 0 { data.append(chunk.prefix(room)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
