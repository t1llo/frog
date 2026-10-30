import Foundation

/// Something a plugin can do. One action is reachable from the command bar, a keyboard shortcut, the menu bar
/// and `frog run` alike, so anything a person can do an agent can do too.
struct PluginAction: Identifiable {
    /// `<plugin>.<name>`, such as `dictation.toggle`; stable, since shortcuts and agents name it.
    let id: String
    let title: String
    var symbol = "bolt"
    /// More words the command bar matches.
    var keywords = ""
    var parameters: [ActionParameter] = []
    var surfaces: ActionSurfaces = .all
    let run: @MainActor (ActionInput) async throws -> ActionResult

    var pluginID: String { String(id.prefix { $0 != "." }) }
    var name: String { String(id.drop { $0 != "." }.dropFirst()) }
}

struct ActionSurfaces: OptionSet, Sendable {
    let rawValue: Int
    static let commandBar = ActionSurfaces(rawValue: 1 << 0)
    static let shortcut = ActionSurfaces(rawValue: 1 << 1)
    static let agent = ActionSurfaces(rawValue: 1 << 2)
    static let all: ActionSurfaces = [.commandBar, .shortcut, .agent]
}

struct ActionParameter: Sendable {
    enum Kind: Sendable, Equatable {
        case text, integer, boolean
        case choice([String])
    }
    let name: String
    var kind: Kind = .text
    var required = false
    /// One line for `frog actions <id>` and the shortcut editor.
    var help = ""
}

struct ActionInput: Sendable {
    enum Source: String, Sendable { case commandBar, shortcut, menu, agent }
    var values: [String: String] = [:]
    /// Text given on standard input or selected in the command bar.
    var text: String?
    var source: Source

    func value(_ name: String) -> String? { values[name] }
    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw ActionError.missing(name) }
        return value
    }
    func integer(_ name: String) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let number = Int(text) else { throw ActionError.invalid(name, "a whole number") }
        return number
    }
    func boolean(_ name: String) throws -> Bool? {
        guard let text = values[name]?.lowercased() else { return nil }
        switch text {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw ActionError.invalid(name, "true or false")
        }
    }
}

/// What an action answers: a line for people, and the same as JSON for `--json`.
struct ActionResult {
    var text: String
    var json: String
    /// What `frog run` exits with, such as a script's own status; 0 is success.
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

    static func done(_ message: String = "Done.") -> ActionResult {
        ActionResult(["ok": true], text: message)
    }
}

enum ActionError: LocalizedError {
    case missing(String)
    case invalid(String, String)
    case unknown(String)
    case pluginOff(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing --\(name)."
        case .invalid(let name, let expected): "--\(name) takes \(expected)."
        case .unknown(let id): "No action “\(id)”. Run `frog actions` for the list."
        case .pluginOff(let name): "\(name) is off. Turn it on in Frog → Plugins, or with `frog plugins enable`."
        case .failed(let message): message
        }
    }
}
