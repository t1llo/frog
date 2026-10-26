import Darwin
import Foundation
import FrogCore
import FrogUsage

/// The Mac itself: Stay awake, a System monitor reading and Mr. Usage's plan limits.
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
        AgentCommand(words: ["monitor"], summary: "CPU, GPU, memory, disk and power right now.",
                     details: "Takes two readings a second apart, as the System monitor page does, then stops. Works whether or not System monitor is on.") { _ in
            let sampler = NativeSystemMonitorSampler()
            _ = await sampler.sample(reset: true, full: true)
            try await Task.sleep(for: .seconds(1))
            let reading = MonitorReading(await sampler.sample(reset: false, full: true), memory: memoryInUse())
            return AgentResult(reading, text: reading.text)
        }
    }

    /// Memory in use as Activity Monitor counts it: app memory, wired and compressed.
    private static func memoryInUse() -> Int64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Int64(info.internal_page_count) - Int64(info.purgeable_count) + Int64(info.wire_count) + Int64(info.compressor_page_count)
        return max(0, pages) * Int64(getpagesize())
    }

    private struct MonitorReading: Encodable {
        struct Memory: Encodable { let used: Int64?; let total: Int64 }
        struct Disk: Encodable { let total: Int64?; let available: Int64?; let readPerSecond: Double?; let writePerSecond: Double? }
        struct Power: Encodable {
            let source: String
            let batteryPercent: Int?
            let charging: Bool
            /// Watts into the battery while it charges, out of it while it powers the Mac.
            let batteryWatts: Double?
            let batteryCharging: Bool?
            let thermalState: String
            let lowPowerMode: Bool?
        }
        let cpuPercent: Double?
        let gpuPercent: Double?
        let memory: Memory
        let disk: Disk
        let power: Power

        init(_ snapshot: SystemMonitorSnapshot, memory used: Int64?) {
            func percent(_ metric: SystemMonitorMetric) -> Double? { metric.value.map { ($0 * 1000).rounded() / 10 } }
            cpuPercent = percent(snapshot.cpu); gpuPercent = percent(snapshot.gpu)
            memory = Memory(used: used, total: Int64(ProcessInfo.processInfo.physicalMemory))
            disk = Disk(total: snapshot.diskCapacity?.total, available: snapshot.diskCapacity?.available,
                        readPerSecond: snapshot.diskRead.value, writePerSecond: snapshot.diskWrite.value)
            let flow = snapshot.power.batteryFlow
            power = Power(source: snapshot.power.source, batteryPercent: snapshot.power.batteryPercent, charging: snapshot.power.charging,
                          batteryWatts: flow.map { ($0.watts * 10).rounded() / 10 }, batteryCharging: flow.map(\.isCharging),
                          thermalState: snapshot.power.thermal, lowPowerMode: snapshot.power.lowPower)
        }

        var text: String {
            func bytes(_ count: Int64, style: ByteCountFormatter.CountStyle = .decimal) -> String {
                ByteCountFormatter.string(fromByteCount: count, countStyle: style)
            }
            func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "unavailable" }
            func rate(_ value: Double?) -> String { value.map { bytes(Int64(max(0, min($0, 1e15)))) + "/s" } ?? "unavailable" }
            var rows = [["CPU", percent(cpuPercent)], ["GPU", percent(gpuPercent)],
                        // Memory as macOS counts it, so 32 GB shows as 32 GB.
                        ["Memory", memory.used.map { "\(bytes($0, style: .memory)) of \(bytes(memory.total, style: .memory)) in use" } ?? "unavailable"]]
            let space = disk.available.flatMap { free in disk.total.map { "\(bytes(free)) free of \(bytes($0))" } } ?? "capacity unavailable"
            rows.append(["Disk", "\(space), reading \(rate(disk.readPerSecond)), writing \(rate(disk.writePerSecond))"])
            var supply = [power.source]
            if let percent = power.batteryPercent { supply.append("battery \(percent)%" + (power.charging ? ", charging" : "")) }
            if let watts = power.batteryWatts, let charging = power.batteryCharging { supply.append("\(watts) W \(charging ? "into" : "out of") the battery") }
            rows.append(["Power", supply.joined(separator: ", ")])
            rows.append(["Thermal state", power.thermalState])
            if let low = power.lowPowerMode { rows.append(["Low Power Mode", low ? "on" : "off"]) }
            return AgentTable.render(rows)
        }
    }

    // MARK: Mr. Usage

    private static var usage: AgentCommand {
        AgentCommand(words: ["usage"], summary: "Plan limits of your AI tools, as Mr. Usage shows them.",
                     details: "For each provider: the plan, how much of each limit is used and when it renews. These are the readings Mr. Usage has; it keeps them fresh on its own.",
                     feature: .usage) { call in
            guard let usage = call.model.toolkit.usage() else { throw AgentCommandError.failed("Mr. Usage is off.") }
            let now = Date()
            let providers = usage.providers.map { provider in
                ProviderLimits(provider: provider, plan: usage.planName(provider: provider),
                               limits: usage.windows(provider: provider, now: now).map { Limit($0, now: now) },
                               status: usage.status(provider: provider), warning: usage.planWarning(provider: provider),
                               credits: usage.credits(provider: provider), source: usage.planSource(provider: provider),
                               updated: usage.planUpdatedAt(provider: provider),
                               accounts: provider == "Claude" && usage.claudeAccountsEnabled ? usage.accounts(now: now).map { Account($0, now: now) } : nil)
            }
            return AgentResult(providers, text: providers.map(\.text).joined(separator: "\n\n"))
        }
    }

    private struct Limit: Encodable {
        let name: String
        /// Nil while the window has no reading, such as a session that renewed since the last one.
        let usedPercent: Double?
        let resetsAt: Date?
        let pace: String?
        private let line: String
        init(_ window: UsageWindow, now: Date) {
            name = window.title
            usedPercent = window.percentage.isFinite ? window.percentage : nil
            resetsAt = window.resetsAt
            pace = window.pace(at: now)
            line = [window.usedText + " used", window.resetText(now: now).map { "renews \($0)" }, pace?.lowercased()]
                .compactMap { $0 }.joined(separator: ", ")
        }
        var row: [String] { ["  " + name, line] }
        private enum CodingKeys: String, CodingKey { case name, usedPercent, resetsAt, pace }
    }

    private struct Account: Encodable {
        let name: String
        let plan: String?
        let included: Bool
        let limits: [Limit]
        let status: String?
        let warning: String?
        init(_ account: UsageAccountSummary, now: Date) {
            name = account.label; plan = account.plan; included = account.included
            limits = account.windows.map { Limit($0, now: now) }
            status = account.status; warning = account.warning
        }
    }

    private struct ProviderLimits: Encodable {
        let provider: String
        let plan: String?
        let limits: [Limit]
        let status: String
        let warning: String?
        let credits: String?
        let source: String?
        let updated: Date?
        /// Each Claude account, while Mr. Usage shows each one.
        let accounts: [Account]?

        var text: String {
            var lines = [provider + (plan.map { " · \($0) plan" } ?? "")]
            if let accounts, !accounts.isEmpty {
                for account in accounts {
                    lines.append("  " + account.name + (account.plan.map { " · \($0)" } ?? "") + (account.included ? "" : " · not counted"))
                    lines.append(account.limits.isEmpty ? "    No current reading." : AgentTable.render(account.limits.map { ["  " + $0.row[0], $0.row[1]] }))
                    if let note = account.warning ?? account.status { lines.append("    " + note) }
                }
            } else {
                lines.append(limits.isEmpty ? "  No current reading." : AgentTable.render(limits.map(\.row)))
            }
            for note in [warning, status == "Newest available plan limits" ? nil : status, credits] {
                if let note { lines.append("  " + note) }
            }
            if let source, !limits.isEmpty { lines.append("  " + source + (updated.map { ", read \(AgentCommands.shortTime($0))" } ?? "")) }
            return lines.joined(separator: "\n")
        }
    }
}

private extension SystemMonitorBatteryFlow {
    var isCharging: Bool {
        if case .charging = self { return true }
        return false
    }
}
