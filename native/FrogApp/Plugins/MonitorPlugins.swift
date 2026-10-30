import AppKit
import SwiftUI
import FrogCore

final class SystemMonitorPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "system-monitor", name: "System monitor", symbol: "gauge.medium", tint: .teal, category: .system,
                                 summary: "CPU, GPU, memory and battery")
    func page() -> AnyView? { legacyPage(SystemMonitorPage(monitor: model.systemMonitor)) }
    var menu: [MenuContribution] {
        [MenuContribution(id: "system-monitor.tab", placement: .tab(title: "System", symbol: "gauge.medium"), order: 10) { [model] in
            AnyView(SystemMonitorView(monitor: model.systemMonitor, presenter: .frogMenu))
        }]
    }
}

final class LLMUsagePlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "llm-usage", name: "LLM usage", symbol: "chart.bar.xaxis", tint: .pink, category: .system,
                                 summary: "Claude and Codex limits at a glance")
    func page() -> AnyView? {
        guard let usage = model.toolkit.usage() else { return nil }
        return legacyPage(UsageDashboardView(usage: usage))
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "llm-usage.tab", placement: .tab(title: "Usage", symbol: "chart.bar.xaxis"), order: 20) { [model, context] in
            guard let usage = model.toolkit.usage() else { return AnyView(EmptyView()) }
            return AnyView(UsageStatusPopover(usage: usage, openDashboard: { context.openPage() },
                                              signIn: { ClaudeSignIn.start(usage) }))
        }]
    }
}
