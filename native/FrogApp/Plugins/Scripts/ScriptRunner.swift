import Combine
import Darwin
import Foundation
import FrogCore

struct ScriptResult: Sendable {
    let output: String
    let status: Int32
    let truncated: Bool
}

/// A script that ran out of time. `truncated`: what it printed before went past the output limit.
struct ScriptTimeout: LocalizedError {
    let seconds: Int
    let truncated: Bool
    var errorDescription: String? { "The script exceeded its \(seconds)-second time limit." }
}

/// A script owns a process group: cancellation, timeout and normal completion
/// all clean up descendants. Pipes are drained concurrently with process exit.
enum ScriptProcess {
    /// `onOutput` receives everything printed so far while the script runs, and once more as it ends, including
    /// when it is stopped or runs out of time, so what it printed until then is not lost.
    /// `arguments` become `$1`, `$2` and so on; `directory` is where it runs, the home folder by default; `environment`
    /// is added to Frog's own.
    static func run(_ script: String, arguments: [String] = [], directory: URL? = nil, environment: [String: String] = [:],
                    timeout: TimeInterval = 60, outputLimit: Int = 256 * 1024, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ScriptResult {
        guard script.utf8.count <= 100_000, !script.contains("\0") else {
            throw FrogError.message("Scripts must contain at most 100,000 bytes and no null characters.")
        }
        guard !(arguments + environment.keys + environment.values).contains(where: { $0.contains("\0") }) else {
            throw FrogError.message("Script arguments cannot contain null characters.")
        }
        let launch = Launch(script: script, arguments: arguments, directory: directory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path, environment: environment)
        let work = Task.detached(priority: .utility) { try execute(launch, timeout: timeout, outputLimit: max(0, outputLimit), onOutput: onOutput) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The length of `bytes` without a character whose last bytes have not arrived yet.
    static func wholeCharacterCount(_ bytes: Data) -> Int {
        var start = bytes.endIndex
        while start > bytes.startIndex, bytes.endIndex - start < 4 {
            start -= 1
            let byte = bytes[start]
            guard byte & 0xC0 == 0x80 else {
                let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return bytes.endIndex - start < length ? start - bytes.startIndex : bytes.count
            }
        }
        return bytes.count
    }

    /// Frog started from the Dock or at login inherits the system directories only, and the script's shell runs
    /// without the startup files that add Homebrew's.
    static func searchPath(inherited: String?) -> String {
        var seen = Set<String>()
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"] + (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        return directories.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private struct Launch: Sendable {
        let script: String
        let arguments: [String]
        let directory: String
        let environment: [String: String]
    }

    private static func execute(_ launch: Launch, timeout: TimeInterval, outputLimit: Int, onOutput: (@Sendable (String) -> Void)?) throws -> ScriptResult {
        try Task.checkCancellation()
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addchdir_np(&actions, launch.directory)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        // After -c, the next word is $0 and the ones after it $1, $2 and so on.
        let argv = (["/bin/zsh", "-f", "-c", launch.script] + (launch.arguments.isEmpty ? [] : ["zsh"] + launch.arguments)).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath(inherited: environment["PATH"])
        environment.merge(launch.environment) { $1 }
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        // Keep our write descriptor open until defer; reads below are nonblocking.
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var reaped = false
        defer {
            // Children may still hold the pipe after their shell exits.
            kill(-pid, SIGKILL)
            if !reaped { var status: Int32 = 0; while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(max(0, timeout) * 1000)))
        var output = Data(), truncated = false, status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound each pass so a continuously writing child cannot prevent cancellation.
            for _ in 0..<32 {
                let count = read(descriptors[0], &buffer, buffer.count)
                guard count > 0 else { break }
                let remaining = max(0, outputLimit - output.count)
                output.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { truncated = true }
            }
        }
        var reported = 0, lastReport = ContinuousClock.now - .seconds(1)
        func report(now: Bool) {
            guard let onOutput else { return }
            let shown = wholeCharacterCount(output)
            guard shown != reported, now || lastReport.duration(to: .now) >= .milliseconds(100) else { return }
            reported = shown; lastReport = .now
            onOutput(String(decoding: output.prefix(shown), as: UTF8.self))
        }
        // Declared after the process cleanup, so it runs first: on timeout and cancellation the last drain is reported
        // before the process group is killed.
        defer { report(now: true) }
        while true {
            drain()
            if Task.isCancelled || ContinuousClock.now >= deadline {
                // What arrived up to now is reported on the way out.
                try Task.checkCancellation()
                throw ScriptTimeout(seconds: Int(timeout), truncated: truncated)
            }
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true; drain(); break }
            if result == -1, errno != EINTR { throw POSIXError(.ECHILD) }
            report(now: false)
            usleep(10_000)
        }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ScriptResult(output: String(decoding: output, as: UTF8.self), status: exitCode, truncated: truncated)
    }
}

@MainActor final class ScriptRunner: ObservableObject {
    @Published private(set) var running: UUID?
    @Published private(set) var resultID: UUID?
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    var onSuccessfulRun: (() -> Void)?
    private var task: Task<Void, Never>?
    /// Scripts the `frog` tool started. Quitting stops them as it stops the page's.
    private var agentRuns: [UUID: Task<ScriptResult, Error>] = [:]
    var needsQuitCleanup: Bool { task != nil || !agentRuns.isEmpty }
    private var generation = UUID()
    /// The run whose output is shown and whose task `task` holds. Stop keeps showing what the stopped script printed;
    /// only a new run replaces it.
    private var shown = UUID()
    func run(_ script: UtilityDocument, timeout: TimeInterval = 60) {
        guard script.kind == .script else { return }
        let previous = task
        stop()
        let token = generation, runID = UUID()
        shown = runID
        running = script.id; resultID = script.id; output = ""; status = "Running…"
        let printed = ScriptOutputRelay { [weak self] text in
            guard let self, shown == runID else { return }
            output = text
        }
        task = Task { [weak self] in
            // A stopped task ends with an old generation; it still releases the handle once its process is gone.
            defer { if let self, shown == runID { task = nil } }
            await previous?.value
            do {
                try Task.checkCancellation()
                let result = try await ScriptProcess.run(script.text, timeout: timeout, onOutput: { printed.send($0) })
                printed.finish()
                guard let self, generation == token, !Task.isCancelled else { return }
                output = result.output
                status = "Exit \(result.status)" + (result.truncated ? " · Output limited to 256 KB" : "")
                running = nil
                if result.status == 0 { onSuccessfulRun?() }
            } catch {
                printed.finish()
                guard let self, generation == token else { return }
                status = error is CancellationError ? "Stopped" : error.localizedDescription
                running = nil
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel()
        if running != nil { status = "Stopped" }; running = nil
    }
    func stopAndWait() async {
        stop()
        // A run an agent starts while these end is stopped as well.
        var stopped = Set<UUID>()
        while case let waiting = agentRuns.filter({ !stopped.contains($0.key) }), !waiting.isEmpty {
            waiting.values.forEach { $0.cancel() }
            for (id, run) in waiting { stopped.insert(id); _ = try? await run.value }
        }
        await task?.value; task = nil
    }

    /// Runs a script for the `frog` tool, beside the page's own run. Cancelling the caller stops the script.
    func runForAgent(_ script: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> ScriptResult {
        let id = UUID()
        let run = Task { try await ScriptProcess.run(script, timeout: timeout, onOutput: onOutput) }
        agentRuns[id] = run
        defer { agentRuns[id] = nil }
        return try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
    }
    isolated deinit { task?.cancel() }
}

/// Brings a running script's output to the main actor. Only the latest text is kept, so a slower main actor skips
/// texts instead of showing them out of order.
final class ScriptOutputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: String?
    private var finished = false
    private let show: @MainActor (String) -> Void
    init(show: @escaping @MainActor (String) -> Void) { self.show = show }

    func send(_ text: String) {
        lock.lock()
        let scheduled = latest != nil || finished
        if !finished { latest = text }
        lock.unlock()
        guard !scheduled else { return }
        Task { @MainActor in self.deliver() }
    }

    /// Shows the text still on its way. Texts arriving later are ignored, so they cannot replace the final result.
    @MainActor func finish() {
        deliver()
        lock.lock(); finished = true; latest = nil; lock.unlock()
    }

    @MainActor private func deliver() {
        lock.lock(); let text = latest; latest = nil; let done = finished; lock.unlock()
        if let text, !done { show(text) }
    }
}
