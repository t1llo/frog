import SwiftUI
import FrogCore
import FrogUsage

/// `[llm-usage]` in config.toml.
struct LLMUsageSettings: ConfigSection {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case claude, openai
        var name: String { self == .claude ? "Claude" : "OpenAI" }
        init(name: String) { self = name == "OpenAI" ? .openai : .claude }
    }
    enum Range: String, Codable, CaseIterable, Sendable {
        case day = "24h", week = "7d", month = "30d"
    }
    enum Metric: String, Codable, CaseIterable, Sendable {
        case apiCost = "api-cost", input, output, cacheWrite = "cache-write", cacheRead = "cache-read"
        static let names: [Metric: String] = [.apiCost: "API cost", .input: "Input", .output: "Output",
                                              .cacheWrite: "Cache write", .cacheRead: "Cache read"]
        var name: String { Self.names[self] ?? "API cost" }
        init(name: String) { self = Self.names.first { $0.value == name }?.key ?? .apiCost }
    }
    enum LoginSource: String, Codable, CaseIterable, Sendable {
        case automatic, claudeCode = "claude-code", claudeDesktop = "claude-desktop", opencode, pi
        static let names: [LoginSource: String] = [.automatic: "Automatic", .claudeCode: "Claude Code",
                                                   .claudeDesktop: "Claude Desktop", .opencode: "OpenCode", .pi: "Pi"]
        var name: String { Self.names[self] ?? "Automatic" }
        init(name: String) { self = Self.names.first { $0.value == name }?.key ?? .automatic }
    }
    enum AccountsView: String, Codable, CaseIterable, Sendable { case each, combined }
    enum AccountsWindow: String, Codable, CaseIterable, Sendable { case session, week }

    var provider = Provider.claude
    var range = Range.week
    var metric = Metric.apiCost
    var loginSource = LoginSource.automatic
    var claudeAccounts = false
    var claudeAccountsView = AccountsView.each
    var claudeAccountsMenuBar = AccountsWindow.session
    var menuBarItem = true
    var menuBarStyle = MenuBarMeterStyle.numbers
    var menuBarPalette = MenuBarMeterPalette.clean

    static let comments = [
        "": "LLM usage: Claude and Codex plan limits and token activity.",
        "provider": "claude or openai",
        "range": "24h, 7d or 30d",
        "metric": "api-cost, input, output, cache-write or cache-read",
        "login-source": "Where Claude limits are read: automatic, claude-code, claude-desktop, opencode or pi",
        "claude-accounts": "Show each Claude account on this Mac",
        "claude-accounts-view": "each or combined",
        "claude-accounts-menu-bar": "The window the menu bar shows per account: session or week",
        "menu-bar-item": "An item of its own in the menu bar",
        "menu-bar-style": "numbers, segments, bars or columns",
        "menu-bar-palette": "clean, level or spectrum",
    ]

    init() {}

    /// The choices as the usage model keeps them.
    init(_ value: UsageDashboardPreferences, menuBarItem: Bool) {
        provider = Provider(name: value.provider)
        range = Range(rawValue: value.range) ?? .week
        metric = Metric(name: value.metric)
        loginSource = LoginSource(name: value.loginSource)
        claudeAccounts = value.claudeAccounts
        claudeAccountsView = AccountsView(rawValue: value.claudeAccountsView) ?? .each
        claudeAccountsMenuBar = AccountsWindow(rawValue: value.claudeAccountsMenuBar) ?? .session
        self.menuBarItem = menuBarItem
        menuBarStyle = MenuBarMeterStyle(choice: value.menuBarStyle)
        menuBarPalette = MenuBarMeterPalette(choice: value.menuBarPalette)
    }

    var dashboard: UsageDashboardPreferences {
        UsageDashboardPreferences(provider: provider.name, range: range.rawValue, metric: metric.name, loginSource: loginSource.name,
                                  claudeAccounts: claudeAccounts, claudeAccountsView: claudeAccountsView.rawValue,
                                  claudeAccountsMenuBar: claudeAccountsMenuBar.rawValue,
                                  menuBarStyle: menuBarStyle.rawValue, menuBarPalette: menuBarPalette.rawValue)
    }
}

/// Claude and Codex plan limits and token activity. It reads logs and limits only while something shows them:
/// its menu-bar item, the popup tab, its page, or an agent asking.
final class LLMUsagePlugin: FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "llm-usage", name: "LLM usage", symbol: "chart.bar.xaxis", tint: .pink,
                                 category: .system, summary: "Claude and Codex limits at a glance")
    /// How long reading goes on after the last surface closed, so a scan that just began can finish.
    static var linger: Duration = .seconds(60)

    private let context: PluginContext
    @Published private(set) var settings = LLMUsageSettings()
    private(set) var usage: UsageDashboardModel?
    private(set) var item: UsageStatusItemController?
    /// Agents waiting for a reading.
    private var holds = 0
    private var lingering: Task<Void, Never>?

    init(context: PluginContext) { self.context = context }

    func start() async {
        let usage = context.legacy.toolkit.makeUsage()
        self.usage = usage
        seedSettings(from: usage)
        settings = context.settings(LLMUsageSettings.self)
        usage.applyPreferences(settings.dashboard)
        usage.onPreferencesChange = { [weak self] in self?.adopt($0) }
        usage.onPresentedChange = { [weak self] _ in self?.updateDemand() }
        configureItem()
        updateDemand()
    }

    func stop() async {
        lingering?.cancel(); lingering = nil
        item?.stop(); item = nil
        usage?.onPreferencesChange = nil
        usage?.onPresentedChange = nil
        usage?.setAvailable(false)
        usage = nil
    }

    func settingsChanged() {
        settings = context.settings(LLMUsageSettings.self)
        usage?.applyPreferences(settings.dashboard)
        configureItem()
        updateDemand()
    }

    func update(_ next: LLMUsageSettings) {
        guard next != settings else { return }
        settings = next
        do { try context.save(next) } catch { context.report(error) }
        usage?.applyPreferences(next.dashboard)
        configureItem()
        updateDemand()
    }

    /// A choice made in a view, through the model.
    private func adopt(_ value: UsageDashboardPreferences) {
        let next = LLMUsageSettings(value, menuBarItem: settings.menuBarItem)
        guard next != settings else { return }
        settings = next
        do { try context.save(next) } catch { context.report(error) }
    }

    func page() -> AnyView? {
        guard let usage else { return nil }
        return AnyView(UsageDashboardView(plugin: self, usage: usage))
    }

    var menu: [MenuContribution] {
        guard let usage else { return [] }
        return [MenuContribution(id: "llm-usage.tab", placement: .tab(title: "Usage", symbol: "chart.bar.xaxis"), order: 20) { [weak self] in
            AnyView(UsageMenuTab(usage: usage) { self?.context.openPage() })
        }]
    }

    var actions: [PluginAction] {
        [
            PluginAction(id: "llm-usage.status", title: "LLM usage limits", symbol: "chart.bar.xaxis",
                         keywords: "claude codex openai plan limits usage", parameters: [
                            ActionParameter(name: "provider", kind: .choice(LLMUsageSettings.Provider.allCases.map(\.rawValue)),
                                            help: "Only this provider; both without it")],
                         surfaces: .agent) { [weak self] input in
                guard let self, let usage = self.usage else { throw ActionError.pluginOff(Self.info.name) }
                let only = input.value("provider").flatMap(LLMUsageSettings.Provider.init(rawValue:))
                await self.whileHeld { await self.waitForReadings(usage) }
                let report = LLMUsageReport.providers(usage, only: only?.name)
                return ActionResult(report, text: report.map(\.text).joined(separator: "\n\n"))
            },
            PluginAction(id: "llm-usage.refresh", title: "Refresh LLM usage", symbol: "arrow.clockwise",
                         keywords: "claude codex limits reload", surfaces: .all) { [weak self] _ in
                guard let self, let usage = self.usage else { throw ActionError.pluginOff(Self.info.name) }
                // Reading starts now and lingers, so the refresh it asks for can finish.
                await self.whileHeld { usage.refresh() }
                return .done("Refreshing LLM usage.")
            },
            PluginAction(id: "llm-usage.menu-bar-item", title: "Show LLM usage in the menu bar", symbol: "menubar.rectangle",
                         keywords: "status item limits", parameters: [ActionParameter(name: "on", kind: .boolean, help: "true or false; toggles without it")],
                         surfaces: .all) { [weak self] input in
                guard let self else { throw ActionError.pluginOff(Self.info.name) }
                var next = self.settings
                next.menuBarItem = try input.boolean("on") ?? !next.menuBarItem
                self.update(next)
                return ActionResult(["menuBarItem": next.menuBarItem],
                                    text: next.menuBarItem ? "LLM usage is in the menu bar." : "LLM usage left the menu bar.")
            },
        ]
    }

    // MARK: Reading only while shown

    /// Keeps the collectors running while `work` runs, and for `linger` after.
    private func whileHeld(_ work: () async -> Void) async {
        holds += 1
        updateDemand()
        await work()
        holds -= 1
        updateDemand()
    }

    /// Up to five seconds for the logs and the saved limits a model reads first.
    private func waitForReadings(_ usage: UsageDashboardModel) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !usage.loaded, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private var needed: Bool { item != nil || usage?.isPresented == true || holds > 0 }

    private func updateDemand() {
        guard let usage else { return }
        if needed {
            lingering?.cancel(); lingering = nil
            usage.setActive(true)
        } else if usage.active, lingering == nil {
            let linger = Self.linger
            lingering = Task { [weak self] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled, let self else { return }
                self.lingering = nil
                if !self.needed { self.usage?.setActive(false) }
            }
        }
    }

    // MARK: Settings and the menu-bar item

    /// The table is written once, from the choices made before config.toml, with every key and its comment.
    private func seedSettings(from usage: UsageDashboardModel) {
        let id = Self.info.id
        guard context.legacy.settingsFile.document.value(at: [id]) == nil else { return }
        var seeded = LLMUsageSettings(usage.preferences, menuBarItem: true)
        if let legacy = context.legacy.configuration.preferences.toolkitSettings.usage {
            seeded = LLMUsageSettings(UsageDashboardPreferences(
                provider: legacy.provider, range: legacy.range, metric: legacy.metric, loginSource: legacy.loginSource,
                claudeAccounts: legacy.claudeAccounts, claudeAccountsView: legacy.claudeAccountsView,
                claudeAccountsMenuBar: legacy.claudeAccountsMenuBar, menuBarStyle: legacy.menuBarStyle,
                menuBarPalette: legacy.menuBarPalette), menuBarItem: true)
        }
        do { try context.legacy.settingsFile.edit { try $0.update(id, seeded, all: true) } }
        catch { context.report(error) }
    }

    private func configureItem() {
        guard let usage, settings.menuBarItem, context.legacy.toolkit.showsStatusItems else {
            item?.stop(); item = nil
            return
        }
        guard item == nil else { return }
        item = UsageStatusItemController(usage: usage) { [weak self] in self?.context.openPage() }
    }
}

/// What `llm-usage.status` answers: per provider, the plan, each limit and where it was read.
enum LLMUsageReport {
    @MainActor static func providers(_ usage: UsageDashboardModel, only: String? = nil, now: Date = Date()) -> [Provider] {
        usage.providers.filter { only == nil || $0 == only }.map { provider in
            Provider(provider: provider, plan: usage.planName(provider: provider),
                     limits: usage.windows(provider: provider, now: now).map { Limit($0, now: now) },
                     status: usage.status(provider: provider), warning: usage.planWarning(provider: provider),
                     credits: usage.credits(provider: provider), source: usage.planSource(provider: provider),
                     updated: usage.planUpdatedAt(provider: provider),
                     accounts: provider == "Claude" && usage.claudeAccountsEnabled ? usage.accounts(now: now).map { Account($0, now: now) } : nil)
        }
    }

    struct Limit: Encodable {
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

    struct Account: Encodable {
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

    struct Provider: Encodable {
        let provider: String
        let plan: String?
        let limits: [Limit]
        let status: String
        let warning: String?
        let credits: String?
        let source: String?
        let updated: Date?
        /// Each Claude account, while LLM usage shows each one.
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
