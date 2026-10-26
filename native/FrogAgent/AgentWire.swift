import Foundation

/// One command from the `frog` tool: the words as typed, and whether the answer should be JSON.
/// The app parses the words itself, so the tool never falls behind the commands of the running app.
public struct AgentRequest: Codable, Equatable, Sendable {
    public var arguments: [String]
    public var json: Bool
    /// The folder the command was typed in, for commands that take relative paths.
    public var directory: String?
    /// Standard input, read only when the command was given `--stdin`, so a tool that leaves
    /// standard input open never waits for it.
    public var input: String?
    public init(arguments: [String], json: Bool = false, directory: String? = nil, input: String? = nil) {
        self.arguments = arguments; self.json = json; self.directory = directory; self.input = input
    }
}

/// The app's answer: text for standard output, a message for standard error and the exit code.
public struct AgentResponse: Codable, Equatable, Sendable {
    public var exitCode: Int32
    public var output: String
    public var error: String
    public init(exitCode: Int32, output: String = "", error: String = "") {
        self.exitCode = exitCode; self.output = output; self.error = error
    }
    public static func success(_ output: String) -> Self { Self(exitCode: 0, output: output) }
    public static func failure(_ message: String, exitCode: Int32 = 1) -> Self { Self(exitCode: exitCode, error: message) }
}

/// Exit codes shared by the tool and the app.
public enum AgentExit {
    public static let failure: Int32 = 1
    /// The words did not name a command, or its arguments were wrong.
    public static let usage: Int32 = 2
    /// Frog is not running, or agent access is off.
    public static let unavailable: Int32 = 69
}

/// Requests and answers travel as one line of JSON each.
public enum AgentWire {
    public static let maximumMessageBytes = 16 << 20

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from line: Data) throws -> Value {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Where the app listens: next to its other data, so `FROG_DATA_DIRECTORY` moves both together.
public enum AgentSocketPath {
    public static let fileName = "agent.sock"

    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["FROG_DATA_DIRECTORY"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Frog", isDirectory: true)
    }

    public static func socket(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        dataDirectory(environment: environment).appendingPathComponent(fileName)
    }
}
