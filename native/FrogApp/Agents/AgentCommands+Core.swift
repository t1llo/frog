import AppKit
import FrogCore

/// Frog itself: its state, its features and its pages.
extension AgentCommands {
    static var core: [AgentCommand] {
        [
            AgentCommand(words: ["status"], summary: "Version, permissions and which features are on.") { call in
                let model = call.model
                model.refreshSystemStatus()
                let preferences = model.configuration.preferences
                let on = FeatureID.allCases.filter(preferences.featureEnabled)
                let off = FeatureID.allCases.filter { !preferences.featureEnabled($0) }
                let status = Status(version: AppVersion.current, build: AppVersion.build, accessibility: model.accessibilityGranted,
                                    featuresOn: on.map(\.agentName), featuresOff: off.map(\.agentName))
                let text = AgentTable.render([
                    ["Frog", AppVersion.current],
                    ["Accessibility", model.accessibilityGranted ? "allowed" : "not allowed: window commands cannot move windows"],
                    ["On", on.map(\.agentName).joined(separator: ", ")],
                    ["Off", off.map(\.agentName).joined(separator: ", ")]
                ])
                return AgentResult(status, text: text)
            },
            AgentCommand(words: ["version"], summary: "Frog's version.") { _ in
                AgentResult(["version": AppVersion.current], text: AppVersion.current)
            },
            AgentCommand(words: ["features", "list"], summary: "Every feature, and whether it is on.") { call in
                let preferences = call.model.configuration.preferences
                let features = FeatureID.allCases.map { Feature(id: $0.agentName, title: $0.title, on: preferences.featureEnabled($0), detail: $0.detail) }
                let text = AgentTable.render(features.map { [$0.on ? "on" : "off", $0.id, $0.detail] })
                return AgentResult(features, text: text)
            },
            AgentCommand(words: ["features", "enable"], arguments: "<feature>", summary: "Turn a feature on.",
                         details: "Takes a name from `frog features list`, such as windows, scripts or stay-awake.") { call in
                try await setFeature(call, enabled: true)
            },
            AgentCommand(words: ["features", "disable"], arguments: "<feature>", summary: "Turn a feature off. Its settings are kept.") { call in
                try await setFeature(call, enabled: false)
            },
            AgentCommand(words: ["open"], arguments: "[page]", summary: "Bring Frog's window forward, on a page.",
                         details: "The page is a feature name from `frog features list`, or history, models, features, settings or statistics. Without one, Frog opens where it was.") { call in
                let model = call.model
                guard let name = call.optionalArgument(0) else {
                    model.showSettings()
                    return .done("Opened Frog.")
                }
                let pages: [String: ToolkitRoute] = ["history": .history, "models": .models, "features": .features, "settings": .settings, "statistics": .statistics]
                if let route = pages[name.lowercased()] {
                    model.toolkit.select(route)
                } else if let feature = FeatureID.agentNamed(name) {
                    guard model.configuration.preferences.featureEnabled(feature) else {
                        throw AgentCommandError.failed("\(feature.title) is off. Turn it on with `frog features enable \(feature.agentName)`.")
                    }
                    model.toolkit.select(.feature(feature))
                } else {
                    throw AgentCommandError.usage("No page named “\(name)”. Use a feature name, or history, models, features, settings or statistics.")
                }
                model.showSettings()
                NSApp.activate(ignoringOtherApps: true)
                return .done("Opened \(name).")
            }
        ]
    }

    private static func setFeature(_ call: AgentCall, enabled: Bool) async throws -> AgentResult {
        let name = try call.argument(0, "feature")
        guard let feature = FeatureID.agentNamed(name) else {
            throw AgentCommandError.usage("No feature named “\(name)”. Run `frog features list` for the names.")
        }
        try await call.model.setFeature(feature, enabled: enabled)
        return .done("\(feature.title) is \(enabled ? "on" : "off").")
    }

    private struct Status: Encodable {
        let version: String
        let build: String?
        let accessibility: Bool
        let featuresOn: [String]
        let featuresOff: [String]
    }

    private struct Feature: Encodable {
        let id: String
        let title: String
        let on: Bool
        let detail: String
    }
}
