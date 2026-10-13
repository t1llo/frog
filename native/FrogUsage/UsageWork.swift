import Foundation
import Darwin

/// Synchronous parsers and credential reads run off the UI actor, with their
/// task cancellation linked to the optional module's lifetime.
func usageWork<Value>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    let task = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        return try operation()
    }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// Runs a tool to its end and returns what it printed, killing it at the deadline, on
/// cancellation, or when it prints more than a megabyte. Blocking; call it off the main thread.
func usageProcess(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                  directory: URL? = nil, timeout: TimeInterval) -> (status: Int32, output: Data)? {
    guard !Task.isCancelled else { return nil }
    let p = Process()
    p.executableURL = executable
    p.arguments = arguments
    if let environment { p.environment = environment }
    if let directory { p.currentDirectoryURL = directory }
    let out = Pipe()
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let descriptor = out.fileHandleForReading.fileDescriptor
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1000)))
    while true {
        if Task.isCancelled || ContinuousClock.now >= deadline || data.count > 1_048_576 {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            return nil
        }
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        else if !p.isRunning { break }
        else { usleep(10_000) }
    }
    p.waitUntilExit()
    return (p.terminationStatus, data)
}
