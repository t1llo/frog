import Darwin
import Foundation
import FrogCore
import FrogUsage

/// The Mac itself: Stay awake, a System monitor reading and the LLM usage plan limits.
extension AgentCommands {
    static var systemTools: [AgentCommand] { awake + [monitor, usage] }

    // MARK: Stay awake

    /// Short names for the Stay awake plugin's actions, which `frog run stay-awake.<verb>` reaches too.
    private static var awake: [AgentCommand] {
        [
            AgentCommand(words: ["awake", "status"], summary: "Whether Stay awake is on, and until when.", feature: .stayAwake) { call in
                try await awakeAction("stay-awake.status", call)
            },
            AgentCommand(words: ["awake", "on"], arguments: "[--for 90|1h|3h|17:30]", summary: "Keep the Mac awake.",
                         details: """
                         Lasts as long as the Stay awake page's duration, or for --for: minutes, 1h, 3h, or a time such \
                         as 17:30. Starting again while on restarts the time. Needs no setup; the lid-closed mode on the \
                         Stay awake page needs a one-time setup.

                         Example: frog awake on --for 1h
                         """, options: ["for"], feature: .stayAwake) { call in
                try await awakeAction("stay-awake.on", call, values: call.option("for").map { ["for": $0] } ?? [:])
            },
            AgentCommand(words: ["awake", "off"], summary: "Let the Mac sleep again.", feature: .stayAwake) { call in
                try await awakeAction("stay-awake.off", call)
            }
        ]
    }

    private static func awakeAction(_ id: String, _ call: AgentCall, values: [String: String] = [:]) async throws -> AgentResult {
        let result = try await call.model.pluginHost.run(id, ActionInput(values: values, source: .agent))
        return AgentResult(text: result.text, json: result.json)
    }

    // MARK: System monitor

    /// Works whether System monitor is on or not: it takes two readings, a second apart, and leaves nothing running.
    private static var monitor: AgentCommand {
        AgentCommand(words: ["monitor"], summary: "CPU, GPU, memory and battery right now.",
                     details: "Takes two readings a second apart, then stops. Works whether or not System monitor is on; `frog run system-monitor.status` is the same reading from the plugin.") { call in
            if call.model.pluginHost.action("system-monitor.status") != nil {
                let result = try await call.model.pluginHost.run("system-monitor.status", ActionInput(source: .agent))
                return AgentResult(text: result.text, json: result.json)
            }
            let sampler = SystemMonitorPlugin.makeSampler()
            _ = await sampler.sample(reset: true, full: true)
            try await Task.sleep(for: .seconds(1))
            let report = SystemMonitorReport(await sampler.sample(reset: false, full: true))
            return AgentResult(report, text: report.text)
        }
    }

    // MARK: LLM usage

    private static var usage: AgentCommand {
        AgentCommand(words: ["usage"], summary: "Plan limits of your AI tools, as LLM usage shows them.",
                     details: "For each provider: the plan, how much of each limit is used and when it renews. The same as `frog run llm-usage.status`.",
                     feature: .usage) { call in
            let result = try await call.model.pluginHost.run("llm-usage.status", ActionInput(source: .agent))
            return AgentResult(text: result.text, json: result.json)
        }
    }
}
