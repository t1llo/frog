import Foundation
import Darwin

struct PowerBattery: Equatable, Sendable {
    let onBattery: Bool
    let percent: Int?
}

protocol StayAwakeSystem: Sendable {
    func hasAccess() async throws -> Bool
    func sleepDisabled() async throws -> Bool
    func battery() async throws -> PowerBattery
    func setSleepDisabled(_ disabled: Bool) async throws
}

enum StayAwakeError: LocalizedError {
    case permission, command, timeout, unreadable, notApplied, lowBattery
    var errorDescription: String? {
        switch self {
        case .permission: "Allow Frog's two power commands using Set up access, then try again."
        case .command: "macOS could not change the sleep setting. Try again."
        case .timeout: "The power command timed out. Check the current setting before trying again."
        case .unreadable: "Could not read the Mac's power settings."
        case .notApplied: "macOS did not apply the sleep setting."
        case .lowBattery: "Connect power or charge above 20% before starting a stay-awake session."
        }
    }
}

/// Only these fixed pmset operations can be executed. No shell or password input.
struct NativeStayAwakeSystem: StayAwakeSystem {
    func hasAccess() async throws -> Bool {
        for value in ["0", "1"] {
            // Command-scoped verbose listing reports the effective rule without
            // executing pmset. Ignore cached sudo credentials so an admin login
            // cannot be mistaken for persistent passwordless access.
            let result = try await run("/usr/bin/sudo", ["-n", "-k", "-ll", "/usr/bin/pmset", "-a", "disablesleep", value])
            guard result.status == 0, Self.allowsWithoutPassword(result.output) else { return false }
        }
        return true
    }

    static func allowsWithoutPassword(_ output: String) -> Bool {
        let options = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Options:") }
        guard !options.isEmpty else { return false }
        return options.allSatisfy { line in
            let tokens = line.dropFirst("Options:".count).split { $0.isWhitespace || $0 == "," }
            return tokens.contains("!authenticate") && !tokens.contains("authenticate")
        }
    }

    func sleepDisabled() async throws -> Bool {
        let result = try await run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { throw StayAwakeError.unreadable }
        return try Self.parseSleepDisabled(result.output)
    }

    func battery() async throws -> PowerBattery {
        let result = try await run("/usr/bin/pmset", ["-g", "batt"])
        guard result.status == 0 else { throw StayAwakeError.unreadable }
        return try Self.parseBattery(result.output)
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        let result = try await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
        guard result.status == 0 else {
            if result.output.contains("sudo:") { throw StayAwakeError.permission }
            throw StayAwakeError.command
        }
    }

    static func parseSleepDisabled(_ output: String) throws -> Bool {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.first == "SleepDisabled" || fields.first == "disablesleep" {
                guard fields.count == 2, ["0", "1"].contains(fields[1]) else { throw StayAwakeError.unreadable }
                return fields[1] == "1"
            }
        }
        // macOS omits SleepDisabled entirely when the default (off) is in use.
        guard output.contains("System-wide power settings:"), output.contains("Currently in use:") else { throw StayAwakeError.unreadable }
        return false
    }

    static func parseBattery(_ output: String) throws -> PowerBattery {
        guard let source = output.split(separator: "\n").first,
              source.contains("'Battery Power'") || source.contains("'AC Power'") || source.contains("'UPS Power'") else { throw StayAwakeError.unreadable }
        let range = output.range(of: #"\b\d{1,3}(?=%)"#, options: .regularExpression)
        let percent = range.flatMap { Int(output[$0]) }
        if let percent, !(0...100).contains(percent) { throw StayAwakeError.unreadable }
        if source.contains("'Battery Power'"), percent == nil { throw StayAwakeError.unreadable }
        return PowerBattery(onBattery: source.contains("'Battery Power'"), percent: percent)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try Self.runSynchronously(executable, arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runSynchronously(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // pmset/sudo -n produce small, bounded diagnostic output. Both the
        // process wait and pipe read run off the UI actor, with a deadline.
        if exited.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 1)
            }
            throw StayAwakeError.timeout
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
