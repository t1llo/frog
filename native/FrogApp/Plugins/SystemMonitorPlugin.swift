import SwiftUI
import FrogCore

/// `[system-monitor]` in config.toml.
struct SystemMonitorSettings: ConfigSection {
    enum Readings: String, Codable, CaseIterable, Sendable {
        case cpu
        case cpuGpu = "cpu-gpu"
        case cpuMemory = "cpu-memory"
        case cpuGpuMemory = "cpu-gpu-memory"

        var gpu: Bool { self == .cpuGpu || self == .cpuGpuMemory }
        var memory: Bool { self == .cpuMemory || self == .cpuGpuMemory }
        var title: String {
            switch self {
            case .cpu: "CPU"
            case .cpuGpu: "CPU and GPU"
            case .cpuMemory: "CPU and memory"
            case .cpuGpuMemory: "CPU, GPU and memory"
            }
        }
    }

    var menuBarItem = false
    var menuBarReadings = Readings.cpuGpu
    var menuBarStyle = MenuBarMeterStyle.segments
    var menuBarPalette = MenuBarMeterPalette.spectrum

    static let comments = [
        "": "System monitor: CPU, GPU, memory and battery.",
        "menu-bar-item": "An item of its own in the menu bar",
        "menu-bar-readings": "cpu, cpu-gpu, cpu-memory or cpu-gpu-memory",
        "menu-bar-style": "numbers, segments, bars or columns",
        "menu-bar-palette": "clean, level or spectrum",
    ]

    /// The table for someone who set the item up before config.toml.
    init(legacy: SystemMonitorPreferences) {
        menuBarItem = legacy.menuBarItem
        menuBarStyle = MenuBarMeterStyle(choice: legacy.menuBarStyle)
        menuBarPalette = MenuBarMeterPalette(choice: legacy.menuBarPalette)
    }

    init() {}
}

/// CPU, GPU, memory and battery. It samples only while an overview or its menu-bar item is on screen.
final class SystemMonitorPlugin: FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "system-monitor", name: "System monitor", symbol: "gauge.medium", tint: .teal,
                                 category: .system, summary: "CPU, GPU, memory and battery")
    /// Replaced by tests, so no test depends on this Mac's load.
    static var makeSampler: @MainActor () -> any SystemMonitorSampling = { NativeSystemMonitorSampler() }

    private let context: PluginContext
    @Published private(set) var settings = SystemMonitorSettings()
    private(set) var monitor: SystemMonitor?
    private(set) var item: SystemMonitorStatusItemController?

    init(context: PluginContext) { self.context = context }

    func start() async {
        seedSettings()
        settings = context.settings(SystemMonitorSettings.self)
        monitor = SystemMonitor(sampler: Self.makeSampler())
        configureItem()
    }

    func stop() async {
        item?.stop(); item = nil
        monitor?.stop(); monitor = nil
    }

    func settingsChanged() {
        settings = context.settings(SystemMonitorSettings.self)
        configureItem()
    }

    func update(_ next: SystemMonitorSettings) {
        guard next != settings else { return }
        settings = next
        do { try context.save(next) } catch { context.report(error) }
        configureItem()
    }

    func page() -> AnyView? {
        guard let monitor else { return nil }
        return AnyView(SystemMonitorPage(plugin: self, monitor: monitor))
    }

    var menu: [MenuContribution] {
        guard let monitor else { return [] }
        return [MenuContribution(id: "system-monitor.tab", placement: .tab(title: "System", symbol: "gauge.medium"), order: 10) {
            AnyView(SystemMonitorView(monitor: monitor, presenter: .frogMenu))
        }]
    }

    var actions: [PluginAction] {
        [
            PluginAction(id: "system-monitor.status", title: "System status", symbol: "gauge.medium",
                         keywords: "cpu gpu memory ram battery load", surfaces: .agent) { [weak self] _ in
                guard let monitor = self?.monitor else { throw ActionError.pluginOff(Self.info.name) }
                let report = SystemMonitorReport(await monitor.current())
                return ActionResult(report, text: report.text)
            },
            PluginAction(id: "system-monitor.menu-bar-item", title: "Show System monitor in the menu bar", symbol: "menubar.rectangle",
                         keywords: "status item cpu", parameters: [ActionParameter(name: "on", kind: .boolean, help: "true or false; toggles without it")],
                         surfaces: .all) { [weak self] input in
                guard let self else { throw ActionError.pluginOff(Self.info.name) }
                var next = self.settings
                next.menuBarItem = try input.boolean("on") ?? !next.menuBarItem
                self.update(next)
                return ActionResult(["menuBarItem": next.menuBarItem],
                                    text: next.menuBarItem ? "System monitor is in the menu bar." : "System monitor left the menu bar.")
            },
        ]
    }

    /// The table is written once, from the settings made before config.toml, with every key and its comment.
    private func seedSettings() {
        let id = Self.info.id
        guard context.legacy.settingsFile.document.value(at: [id]) == nil else { return }
        let legacy = context.legacy.configuration.preferences.toolkitSettings.systemMonitor ?? SystemMonitorPreferences()
        do { try context.legacy.settingsFile.edit { try $0.update(id, SystemMonitorSettings(legacy: legacy), all: true) } }
        catch { context.report(error) }
    }

    private func configureItem() {
        guard let monitor, settings.menuBarItem, context.legacy.toolkit.showsStatusItems else {
            item?.stop(); item = nil
            return
        }
        if let item { item.apply(settings); return }
        item = SystemMonitorStatusItemController(monitor: monitor, settings: settings) { [weak self] in
            self?.context.openPage()
        }
    }
}

/// What `system-monitor.status` answers.
struct SystemMonitorReport: Encodable {
    struct Memory: Encodable { let usedBytes: Int64; let totalBytes: Int64; let percent: Double }
    struct Battery: Encodable {
        let percent: Int
        let charging: Bool
        /// Watts into the battery while it charges, out of it while it powers the Mac.
        let watts: Double?
    }
    let cpuPercent: Double?
    let gpuPercent: Double?
    let memory: Memory?
    let battery: Battery?
    let powerSource: String
    let thermalState: String
    let lowPowerMode: Bool?

    init(_ snapshot: SystemMonitorSnapshot) {
        func percent(_ fraction: Double?) -> Double? { fraction.map { ($0 * 1000).rounded() / 10 } }
        cpuPercent = percent(snapshot.cpu.value)
        gpuPercent = percent(snapshot.gpu.value)
        memory = snapshot.memory.map { Memory(usedBytes: $0.used, totalBytes: $0.total, percent: percent($0.fraction) ?? 0) }
        let power = snapshot.power
        battery = power.batteryPercent.map { Battery(percent: $0, charging: power.charging, watts: power.batteryFlow.map { ($0.watts * 10).rounded() / 10 }) }
        powerSource = power.source
        thermalState = power.thermal
        lowPowerMode = power.lowPower
    }

    var text: String {
        func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "unavailable" }
        func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .memory) }
        var rows = [["CPU", percent(cpuPercent)], ["GPU", percent(gpuPercent)],
                    ["Memory", memory.map { "\(Int($0.percent.rounded()))%, \(bytes($0.usedBytes)) of \(bytes($0.totalBytes))" } ?? "unavailable"]]
        if let battery {
            var line = "\(battery.percent)%" + (battery.charging ? ", charging" : "")
            if let watts = battery.watts { line += ", \(watts) W" }
            rows.append(["Battery", line])
        }
        rows.append(["Power", powerSource])
        rows.append(["Thermal state", thermalState])
        if lowPowerMode == true { rows.append(["Low Power Mode", "on"]) }
        return AgentTable.render(rows)
    }
}
