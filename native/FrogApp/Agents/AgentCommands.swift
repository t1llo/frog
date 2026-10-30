import Foundation
import FrogAgent
import FrogCore

/// Parses what the `frog` tool sends and runs the matching command. Commands live in one
/// file per area (`AgentCommands+Core.swift` and its siblings); `all` lists them in the order
/// `frog help` shows them.
@MainActor enum AgentCommands {
    static var all: [AgentCommand] { core + actions + windows + tools + plugins }

    /// The heading each command's first word is listed under in `frog help`.
    static let groups: [String: String] = [
        "status": "Frog", "version": "Frog", "features": "Frog", "open": "Frog", "actions": "Actions", "run": "Actions",
        "windows": "Windows", "apps": "Windows",
        "clipboard": "Clipboard", "rules": "Writing rules", "awake": "Stay awake",
        "monitor": "System monitor", "usage": "Mr. Usage", "plugin": "Community plugins"
    ]

    /// Commands of features that became part of others, with what to use instead. Skills installed
    /// before then still name them.
    static let retired: [String: String] = [
        "snippets": "Snippets are notes now. Run `frog run notes.list`, and `frog run notes.read --title <name> --expand true` to fill in their variables.",
        "shelf": "The shelf is gone; its items are notes now. Run `frog run notes.list`.",
        "notes": "Notes are actions now: `frog actions notes` lists them, such as `frog run notes.read --title <name>`.",
        "scripts": "Scripts are actions now: `frog actions scripts` lists them, such as `frog run scripts.run --title <name>`.",
        "plugins": "Plugin commands start with `frog plugin` now, such as `frog plugin list`; `frog plugin check` is `frog plugin validate`, `frog plugin pack` is `frog plugin publish`, and a plugin's commands run with `frog run community.<id>.<command>`."
    ]

    static func run(_ request: AgentRequest, model: AppModel) async -> AgentResponse {
        var words = request.arguments
        if words.first == "help" || words.first == "--help" {
            words.removeFirst()
            return help(for: words, model: model, json: request.json)
        }
        guard let command = match(words) else {
            // A group's first word alone, such as `frog windows`, lists its commands.
            if words.count == 1, all.contains(where: { $0.words.first == words[0] }) {
                return help(for: words, model: model, json: request.json)
            }
            if let first = words.first, let hint = retired[first] { return .failure(hint, exitCode: AgentExit.usage) }
            let typed = words.joined(separator: " ")
            return .failure("Unknown command “\(typed)”. Run `frog help` for the list.", exitCode: AgentExit.usage)
        }
        let rest = Array(words.dropFirst(command.words.count))
        if rest.contains("--help") { return help(for: command.words, model: model, json: request.json) }
        do {
            let parsed = try parse(rest, for: command)
            if let feature = command.feature, !model.configuration.preferences.featureEnabled(feature) {
                return .failure("\(feature.title) is off. Turn it on with `frog features enable \(feature.agentName)`.")
            }
            let call = AgentCall(model: model, command: command, positional: parsed.positional, options: parsed.options, flags: parsed.flags,
                                 directory: request.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }, input: request.input)
            let result = try await command.run(call)
            return AgentResponse(exitCode: result.exitCode, output: request.json ? result.json : result.text, error: result.notice)
        } catch AgentCommandError.usage(let message) {
            return .failure(message, exitCode: AgentExit.usage)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// The command whose words start `words`, preferring the longest.
    static func match(_ words: [String]) -> AgentCommand? {
        all.filter { words.starts(with: $0.words) }.max { $0.words.count < $1.words.count }
    }

    static func parse(_ tokens: [String], for command: AgentCommand) throws -> (positional: [String], options: [String: String], flags: Set<String>) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token == "--" { positional += tokens[index...]; break }
            guard token.hasPrefix("--"), token.count > 2 else { positional.append(token); continue }
            let body = token.dropFirst(2)
            if let equals = body.firstIndex(of: "=") {
                let name = String(body[..<equals])
                guard command.options.contains(name) else { throw unknownOption(name, command) }
                options[name] = String(body[body.index(after: equals)...])
            } else if command.flags.contains(String(body)) {
                flags.insert(String(body))
            } else if command.options.contains(String(body)) {
                guard index < tokens.count else { throw AgentCommandError.usage("--\(body) needs a value. Usage: \(command.usage)") }
                options[String(body)] = tokens[index]
                index += 1
            } else if command.anyOption {
                // `--name value`, or `--name` alone as true when no value follows.
                if index < tokens.count, !tokens[index].hasPrefix("--") { options[String(body)] = tokens[index]; index += 1 }
                else { options[String(body)] = "true" }
            } else {
                throw unknownOption(String(body), command)
            }
        }
        return (positional, options, flags)
    }

    private static func unknownOption(_ name: String, _ command: AgentCommand) -> AgentCommandError {
        .usage("Unknown option --\(name). Usage: \(command.usage)")
    }

    // MARK: Help

    private struct HelpEntry: Encodable {
        let usage: String
        let summary: String
        let details: String?
        let feature: String?
        let available: Bool
    }

    static func help(for words: [String], model: AppModel, json: Bool) -> AgentResponse {
        let preferences = model.configuration.preferences
        func available(_ command: AgentCommand) -> Bool { command.feature.map(preferences.featureEnabled) ?? true }
        func entry(_ command: AgentCommand) -> HelpEntry {
            HelpEntry(usage: command.usage, summary: command.summary, details: command.details.isEmpty ? nil : command.details,
                      feature: command.feature?.agentName, available: available(command))
        }
        // One command in full.
        if !words.isEmpty, let command = match(words), command.words.count == words.count || words.count > 1 {
            if json { return .success(AgentResult(entry(command), text: "").json) }
            var text = "\(command.usage)\n\n\(command.summary)"
            if !command.details.isEmpty { text += "\n\n\(command.details)" }
            if let feature = command.feature, !available(command) {
                text += "\n\n\(feature.title) is off. Turn it on with `frog features enable \(feature.agentName)`."
            }
            return .success(text)
        }
        let listed = words.isEmpty ? all : all.filter { $0.words.first == words[0] }
        guard !listed.isEmpty else {
            return .failure("Unknown command “\(words.joined(separator: " "))”. Run `frog help` for the list.", exitCode: AgentExit.usage)
        }
        if json { return .success(AgentResult(listed.map(entry), text: "").json) }
        var sections: [(title: String, commands: [AgentCommand])] = []
        for command in listed {
            let title = groups[command.words[0]] ?? command.words[0].capitalized
            if let index = sections.firstIndex(where: { $0.title == title }) { sections[index].commands.append(command) }
            else { sections.append((title, [command])) }
        }
        let width = min(44, listed.map { $0.usage.count }.max() ?? 0)
        var lines: [String] = []
        if words.isEmpty {
            lines += ["Frog \(AppVersion.current) from the command line, for you and your AI agents.", "",
                      "Usage: frog <command> [arguments] [--json] [--stdin]", ""]
        }
        for section in sections {
            let off = section.commands.allSatisfy { !available($0) }
            lines.append(section.title + (off ? " (off)" : ""))
            for command in section.commands {
                let usage = command.usage.dropFirst("frog ".count)
                let padded = usage.count < width - 5 ? usage.padding(toLength: width - 5, withPad: " ", startingAt: 0) : String(usage)
                lines.append("  \(padded)  \(command.summary)")
            }
            lines.append("")
        }
        lines += ["--json gives machine-readable output; --stdin passes standard input as the text.",
                  "Run `frog help <command>` for one command's details."]
        return .success(lines.joined(separator: "\n"))
    }
}

enum AppVersion {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
    static var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
}
