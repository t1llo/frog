import Foundation
import FrogAgent
import FrogCore

/// One command of the `frog` tool, such as `frog windows list`.
struct AgentCommand {
    /// The words that name it, such as ["windows", "list"].
    let words: [String]
    /// What follows the words in the usage line, such as "<layout> [--window ID]".
    var arguments = ""
    /// One line for `frog help`.
    let summary: String
    /// More for `frog help <command>`: what each argument means, with an example or two.
    var details = ""
    /// Options that take a value, without the leading "--".
    var options: [String] = []
    /// Options that stand alone, without the leading "--".
    var flags: [String] = []
    /// A feature that must be on; the command says how to turn it on otherwise.
    var feature: FeatureID?
    let run: @MainActor (AgentCall) async throws -> AgentResult

    var usage: String { (["frog"] + words + (arguments.isEmpty ? [] : [arguments])).joined(separator: " ") }
}

/// One run of a command: its arguments, already split into positional values, options and flags.
@MainActor struct AgentCall {
    let model: AppModel
    let command: AgentCommand
    let positional: [String]
    let options: [String: String]
    let flags: Set<String>
    /// The folder the command was typed in.
    let directory: URL?
    /// Text from standard input, when the command was given `--stdin`.
    let input: String?

    func argument(_ index: Int, _ name: String) throws -> String {
        guard positional.indices.contains(index) else { throw AgentCommandError.usage("Missing <\(name)>. Usage: \(command.usage)") }
        return positional[index]
    }
    func optionalArgument(_ index: Int) -> String? { positional.indices.contains(index) ? positional[index] : nil }
    func option(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    func integer(_ name: String, default value: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let text = options[name] else { return value }
        guard let number = Int(text), range.contains(number) else {
            throw AgentCommandError.usage("--\(name) takes a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    /// Text given as the remaining arguments from `index`, as `--text`, or on standard input with `--stdin`.
    func text(from index: Int, _ name: String = "text") throws -> String {
        if let input { return input }
        if let text = options["text"] { return text }
        let words = positional.dropFirst(index)
        guard !words.isEmpty else { throw AgentCommandError.usage("Missing <\(name)>. Pass it as arguments, with --text, or on standard input with --stdin.") }
        return words.joined(separator: " ")
    }

    /// A path as typed, relative to the folder the command was typed in.
    func path(_ text: String) -> URL {
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
    }
}

/// What a command answers: text for people, and the same as JSON for `--json`.
struct AgentResult {
    let text: String
    let json: String
    /// For a command that passes on an exit code, such as a script's.
    var exitCode: Int32 = 0
    /// A line for standard error, such as why the exit code is not 0.
    var notice = ""

    init<Value: Encodable>(_ value: Value, text: String) {
        self.text = text
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        json = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// A command that did something and has nothing more to show.
    static func done(_ message: String) -> AgentResult { AgentResult(AgentMessage(ok: true, message: message), text: message) }
}

struct AgentMessage: Encodable {
    let ok: Bool
    let message: String
}

enum AgentCommandError: LocalizedError {
    /// The words or arguments were wrong; exits with 2.
    case usage(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .usage(let message), .failed(let message): message
        }
    }
}

/// Columns padded to line up, for text output.
enum AgentTable {
    static func render(_ rows: [[String]], separator: String = "  ") -> String {
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        let widths = (0..<width).map { column in
            rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: separator)
        }.joined(separator: "\n")
    }
}

extension FeatureID {
    /// The name the `frog` tool uses, such as "window-switcher".
    var agentName: String {
        switch self {
        case .scratchpad: "notes"
        case .applicationShortcuts: "shortcuts"
        case .cleaner: "app-cleaner"
        default: rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "-" + character.lowercased() } else { name.append(character) }
        }
        }
    }

    /// A feature by its tool name, its ID or its title, in any case.
    static func agentNamed(_ text: String) -> FeatureID? {
        let wanted = text.lowercased().replacingOccurrences(of: " ", with: "-")
        return allCases.first { feature in
            [feature.agentName, feature.rawValue.lowercased(), feature.title.lowercased().replacingOccurrences(of: " ", with: "-")].contains(wanted)
        }
    }
}
