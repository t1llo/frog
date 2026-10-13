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

/// Hands `line` every complete line of an append-only log from `offset` on and returns how many
/// bytes that was. The file is read a bounded piece at a time, so a long transcript is never
/// held in memory whole. A final line without a newline may still be being written, so it is
/// left for the next pass, like everything after a cancellation.
func usageLines(in url: URL, from offset: UInt64, chunk: Int = 1 << 20, _ line: (Data) -> Void) -> UInt64 {
    guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
    defer { try? h.close() }
    guard (try? h.seek(toOffset: offset)) != nil else { return 0 }
    var consumed: UInt64 = 0
    // The beginning of a line whose end is in a later piece.
    var carried = Data()
    var more = true
    while more {
        // Foundation releases each piece, and what `line` parses out of it, only when a pool
        // drains; without one of its own a whole scan would still pile up in memory.
        more = autoreleasepool {
            guard !Task.isCancelled, let data = try? h.read(upToCount: chunk), !data.isEmpty else { return false }
            var lineStart = data.startIndex
            while let lineEnd = data[lineStart...].firstIndex(of: 0x0A) {
                if Task.isCancelled { return false }
                consumed += UInt64(carried.count + (lineEnd - lineStart) + 1)
                if carried.isEmpty { line(data[lineStart..<lineEnd]) }
                else {
                    carried.append(data[lineStart..<lineEnd])
                    line(carried)
                    carried.removeAll(keepingCapacity: true)
                }
                lineStart = lineEnd + 1
            }
            carried.append(data[lineStart...])
            return true
        }
    }
    return consumed
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
