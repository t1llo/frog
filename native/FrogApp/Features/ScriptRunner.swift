import Combine
import Darwin
import Foundation
import FrogCore

struct ScriptResult: Sendable {
    let output: String
    let status: Int32
    let truncated: Bool
}

/// A script owns a process group: cancellation, timeout and normal completion
/// all clean up descendants. Pipes are drained concurrently with process exit.
enum ScriptProcess {
    static func run(_ script: String, timeout: TimeInterval = 60, outputLimit: Int = 256 * 1024) async throws -> ScriptResult {
        guard script.utf8.count <= 100_000, !script.contains("\0") else {
            throw FrogError.message("Scripts must contain at most 100,000 bytes and no null characters.")
        }
        let work = Task.detached(priority: .utility) { try execute(script, timeout: timeout, outputLimit: max(0, outputLimit)) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func execute(_ script: String, timeout: TimeInterval, outputLimit: Int) throws -> ScriptResult {
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
        posix_spawn_file_actions_addchdir_np(&actions, FileManager.default.homeDirectoryForCurrentUser.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ["/bin/zsh", "-f", "-c", script].map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { old, _ in old }
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
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw FrogError.message("The script exceeded its \(Int(timeout))-second time limit.") }
            drain()
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true; drain(); break }
            if result == -1, errno != EINTR { throw POSIXError(.ECHILD) }
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
    var needsQuitCleanup: Bool { task != nil }
    private var generation = UUID()
    func run(_ script: UtilityDocument) {
        guard script.kind == .script else { return }
        let previous = task
        stop()
        let token = generation
        running = script.id; resultID = script.id; output = ""; status = "Running…"
        task = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let result = try await ScriptProcess.run(script.text)
                guard let self, generation == token, !Task.isCancelled else { return }
                output = result.output
                status = "Exit \(result.status)" + (result.truncated ? " · Output limited to 256 KB" : "")
                running = nil; task = nil
                if result.status == 0 { onSuccessfulRun?() }
            } catch {
                guard let self, generation == token else { return }
                status = error is CancellationError ? "Stopped" : error.localizedDescription
                running = nil; task = nil
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel()
        if running != nil { status = "Stopped" }; running = nil
    }
    func stopAndWait() async { stop(); await task?.value; task = nil }
    isolated deinit { task?.cancel() }
}
