import Foundation

/// Every plugin action, the same ones the command bar and shortcuts run, by its ID.
extension AgentCommands {
    static var actions: [AgentCommand] {
        [
            AgentCommand(words: ["actions"], arguments: "[plugin or action]",
                         summary: "What the plugins that are on can do.",
                         details: "With a plugin ID, only its actions; with an action ID, its parameters. Run one with `frog run <action>`.") { call in
                let host = call.model.pluginHost
                let listed = host.actions.filter { $0.surfaces.contains(.agent) }
                if let name = call.optionalArgument(0), let action = listed.first(where: { $0.id == name }) {
                    let entry = ActionEntry(action)
                    var lines = ["frog run \(action.id)" + action.parameters.map { $0.required ? " --\($0.name) <\($0.name)>" : " [--\($0.name) <\($0.name)>]" }.joined(),
                                 "", action.title]
                    if !action.parameters.isEmpty {
                        lines.append("")
                        lines.append(AgentTable.render(action.parameters.map { ["--\($0.name)", ActionEntry.kind($0.kind), $0.help] }))
                    }
                    return AgentResult(entry, text: lines.joined(separator: "\n"))
                }
                let shown = call.optionalArgument(0).map { plugin in listed.filter { $0.pluginID == plugin } } ?? listed
                if let name = call.optionalArgument(0), shown.isEmpty {
                    if let descriptor = host.descriptor(name), !host.enabled(name) { throw ActionError.pluginOff(descriptor.info.name) }
                    throw AgentCommandError.usage("No plugin or action named “\(name)”. Run `frog actions` for the list.")
                }
                return AgentResult(shown.map(ActionEntry.init), text: AgentTable.render(shown.map { [$0.id, $0.title] }))
            },
            AgentCommand(words: ["run"], arguments: "<action> [--parameter value …]",
                         summary: "Run a plugin action, as the command bar would.",
                         details: "Parameters are given as options, such as `frog run shortcuts.open-app --app Safari`. --stdin passes text to actions that take it.",
                         anyOption: true) { call in
                let id = try call.argument(0, "action")
                guard let action = call.model.pluginHost.action(id), action.surfaces.contains(.agent) else {
                    // Lets the host say whether the plugin is off or the action does not exist.
                    _ = try await call.model.pluginHost.run(id, ActionInput(source: .agent))
                    throw ActionError.unknown(id)
                }
                let known = Set(action.parameters.map(\.name))
                if let unknown = call.options.keys.sorted().first(where: { !known.contains($0) }) {
                    throw AgentCommandError.usage("\(id) takes no --\(unknown). Run `frog actions \(id)` for its parameters.")
                }
                let input = ActionInput(values: call.options, text: call.input, source: .agent)
                let result = try await call.model.pluginHost.run(id, input)
                return AgentResult(text: result.text, json: result.json)
            }
        ]
    }

    private struct ActionEntry: Encodable {
        struct Parameter: Encodable {
            let name: String
            let kind: String
            let required: Bool
            let help: String
            let choices: [String]?
        }
        let id: String
        let plugin: String
        let title: String
        let parameters: [Parameter]

        init(_ action: PluginAction) {
            id = action.id; plugin = action.pluginID; title = action.title
            parameters = action.parameters.map { parameter in
                var choices: [String]?
                if case .choice(let options) = parameter.kind { choices = options }
                return Parameter(name: parameter.name, kind: Self.kind(parameter.kind), required: parameter.required, help: parameter.help, choices: choices)
            }
        }

        static func kind(_ kind: ActionParameter.Kind) -> String {
            switch kind {
            case .text: "text"
            case .integer: "integer"
            case .boolean: "boolean"
            case .choice(let options): options.joined(separator: "|")
            }
        }
    }
}
