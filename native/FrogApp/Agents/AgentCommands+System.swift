import Darwin
import Foundation
import FrogCore
import FrogUsage

/// The Mac itself: Stay awake, a System monitor reading and the LLM usage plan limits.
extension AgentCommands {
    static var systemTools: [AgentCommand] { awake + [monitor, usage] }

    // MARK: Stay awake

    private static var awake: [AgentCommand] {
        [
            AgentCommand(words: ["awake", "status"], summary: "Whether Stay awake is on, and until when.", feature: .stayAwake) { call in
                let power = call.model.power
                await power.waitForOperation()
                await power.refresh()
                await power.refreshAccessUnlessReady()
                return awakeStatus(power)
            },
            AgentCommand(words: ["awake", "on"], arguments: "[--for 30m|1h|4h|quit]", summary: "Keep the Mac awake, also with the lid closed.",
                         details: """
                         Stays on for the time the Stay awake page has chosen, four hours unless changed, or for --for: \
                         30m, 1h, 4h, or quit for until Frog quits. --for leaves the page's choice as it is. To change \
                         the time while Stay awake is on, switch it off first. Needs the one-time access setup on the \
                         Stay awake page.

                         Example: frog awake on --for 1h
                         """, options: ["for"], feature: .stayAwake) { call in
                let power = call.model.power
                let durations: [String: StayAwakeController.DurationChoice] = ["30m": .halfHour, "1h": .hour, "4h": .fourHours, "quit": .untilQuit]
                let duration = try call.option("for").map { value in
                    guard let duration = durations[value.lowercased()] else { throw AgentCommandError.usage("--for takes 30m, 1h, 4h or quit.") }
                    return duration
                }
                try await readPower(power)
                if power.isEnabled {
                    var result = awakeStatus(power, prefix: "Stay awake is already on")
                    if duration != nil { result.notice = "--for was not applied. To change the time, run `frog awake off`, then `frog awake on` again." }
                    return result
                }
                guard !power.isConfiguringAccess else { throw AgentCommandError.failed("Finish the access guide in Terminal first.") }
                await power.refreshAccessUnlessReady()
                switch power.accessState {
                case .ready: break
                case .unavailable(let message): throw AgentCommandError.failed("Frog could not check its access to the sleep setting: \(message)")
                case .needsSetup, .checking: throw AgentCommandError.failed(setupHint)
                }
                power.setEnabled(true, for: duration)
                await power.waitForOperation()
                guard power.isEnabled else { throw AgentCommandError.failed(power.needsSetup ? setupHint : power.error ?? "macOS did not apply the sleep setting.") }
                return awakeStatus(power, prefix: "Stay awake is on")
            },
            AgentCommand(words: ["awake", "off"], summary: "Let the Mac sleep again.", feature: .stayAwake) { call in
                let power = call.model.power
                try await readPower(power)
                guard power.isEnabled else { return awakeStatus(power, prefix: "Stay awake is already off") }
                power.setEnabled(false)
                await power.waitForOperation()
                guard !power.isEnabled else { throw AgentCommandError.failed(power.error ?? "macOS did not restore sleep.") }
                return awakeStatus(power, prefix: "Stay awake is off")
            }
        ]
    }

    private static let setupHint = "Stay awake needs a one-time setup first. Run `frog open stay-awake` and choose Set up access."

    /// Reads the sleep setting once a change under way has finished, or says why it cannot.
    private static func readPower(_ power: StayAwakeController) async throws {
        await power.waitForOperation()
        await power.refresh()
        guard power.hasReadState else { throw AgentCommandError.failed(power.error ?? "Could not read the Mac's power settings.") }
    }

    private static func awakeStatus(_ power: StayAwakeController, prefix: String? = nil) -> AgentResult {
        let access = switch power.accessState {
        case .ready: "ready"
        case .needsSetup: "setup-needed"
        case .checking: "checking"
        case .unavailable: "unavailable"
        }
        let state = power.hasReadState ? power.isEnabled : nil
        // Without a session of Frog's own, something else switched sleep off and Frog knows no end.
        let untilQuit = state == true && power.ownsSession && power.deadline == nil
        let status = AwakeStatus(on: state, until: state == true ? power.deadline : nil, untilQuit: untilQuit, access: access,
                                 message: power.error ?? power.notice ?? power.accessNotice)
        var when = ""
        if state == true {
            if let deadline = power.deadline { when = " until \(shortTime(deadline))" }
            else { when = untilQuit ? " until Frog quits" : ", switched on outside Frog" }
        }
        if let prefix { return AgentResult(status, text: prefix + when + ".") }
        var rows = [["Stay awake", state.map { $0 ? "on" + when : "off" } ?? "unknown"],
                    ["Access", power.accessState == .needsSetup ? "setup needed: run `frog open stay-awake` and choose Set up access" : power.accessState.title.lowercased()]]
        if let message = status.message { rows.append(["Note", message]) }
        return AgentResult(status, text: AgentTable.render(rows))
    }

    private struct AwakeStatus: Encodable {
        /// Nil when the setting could not be read.
        let on: Bool?
        let until: Date?
        let untilQuit: Bool
        let access: String
        let message: String?
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
