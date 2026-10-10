import Foundation
import Combine

enum UsagePreferences {
    // Machine-local polling state, separate from the standalone app.
    static let defaults = UserDefaults(suiteName: "xyz.beffa.frog.usage")!
}

public struct UsageWindow: Identifiable {
    public let id: String
    public let title: String
    public let percentage: Double
    public let resetsAt: Date?
    public let duration: TimeInterval?
}

/// Portable display choices only. Credentials, readings and request gates stay local.
public struct UsageDashboardPreferences: Codable, Equatable {
    public var provider: String
    public var range: String
    public var metric: String
    public var allDevices: Bool
    public var loginSource: String

    public init(provider: String = "Claude", range: String = "7d", metric: String = "API cost",
                allDevices: Bool = false, loginSource: String = "Automatic") {
        self.provider = provider; self.range = range; self.metric = metric
        self.allDevices = allDevices; self.loginSource = loginSource
    }
}
public struct UsageChartPoint: Identifiable {
    public let date: Date
    public let value: Double
    public var id: Date { date }
}
public struct UsageModelTotal: Identifiable {
    public let name: String
    public let value: Double
    public var id: String { name }
}
public struct UsageSourceTotal: Identifiable {
    public let name: String
    public let value: Double
    public var id: String { name }
}
public struct UsageChart {
    public let points: [UsageChartPoint]
    public let models: [UsageModelTotal]
    public let total: String
    public let unpricedModels: [String]
    /// Local tools (including OpenCode), or reconciled ChatGPT account estimates.
    public let sources: [UsageSourceTotal]
    public let totalTokens: Double
    public let totals: [UsageMetricTotal]
    public let range: String
    public let account: Bool
    public var hasActivity: Bool { totalTokens > 0 }
}

public struct UsageMetricTotal: Identifiable {
    public let name: String
    public let label: String
    public let value: Double
    public var id: String { name }
}

public struct UsageStatistic: Identifiable {
    public let name: String
    public let value: String
    public var id: String { name }
}

public struct UsageLifetime {
    public let title: String
    public let detail: String
    public let statistics: [UsageStatistic]
    public let note: String

    init(_ activity: ClaudeActivity) {
        title = "Claude Code lifetime"
        detail = "Local /stats cache · \(activity.profile)" + (activity.computedThrough.map { " · through \($0)" } ?? "")
        var rows = [UsageStatistic(name: "Total tokens", value: compact(activity.totalTokens)),
                    UsageStatistic(name: "Cache reads", value: compact(activity.cacheRead)),
                    UsageStatistic(name: "Active days", value: String(activity.activeDays))]
        if let sessions = activity.sessions { rows.append(UsageStatistic(name: "Sessions", value: String(sessions))) }
        if let first = activity.firstSession { rows.append(UsageStatistic(name: "First session", value: first.formatted(date: .abbreviated, time: .omitted))) }
        if let last = activity.lastActive { rows.append(UsageStatistic(name: "Last active", value: last)) }
        statistics = rows
        note = "Reported by Claude Code /stats; may lag or count repeated response blocks. This is local profile history, not an account-wide total, and is never added to the chart."
    }

    init(_ activity: AccountActivity) {
        title = "OpenAI all-time activity"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = usageUTCCalendar.timeZone
        detail = "All devices" + (activity.asOf.map { " · through \(formatter.string(from: $0)) UTC" } ?? "")
        var rows = [UsageStatistic(name: "Lifetime tokens", value: compact(activity.lifetime)),
                    UsageStatistic(name: "Peak day", value: compact(activity.peakDay)),
                    UsageStatistic(name: "Current streak", value: "\(activity.currentStreak)d"),
                    UsageStatistic(name: "Best streak", value: "\(activity.longestStreak)d")]
        if let chats = activity.chats { rows.append(UsageStatistic(name: "Chats", value: compact(Double(chats)))) }
        if let effort = activity.effort { rows.append(UsageStatistic(name: "Reasoning", value: "\(effort.name) · \(Int(effort.share.rounded()))%")) }
        statistics = rows
        note = "Account-reported lifetime totals are separate from the selected chart period. Daily reports can lag current activity."
    }
}

public struct UsagePlanPeriod: Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let percentage: Double
    public let models: [UsageModelTotal]
    init(_ period: PlanPeriod) {
        id = period.id; start = period.start; end = period.end; percentage = period.used
        models = period.byModel.map { UsageModelTotal(name: $0.name, value: $0.value) }
    }
}

/// Optional usage module: construction never scans files or reads credentials.
/// Disabling cancels owned polling and rejects results from previous generations.
@MainActor public final class UsageDashboardModel: ObservableObject {
    private let claude: Store
    private let tokens: TokenStore
    private let fixtureRoot: URL?
    private let defaults: UserDefaults
    private var observations = Set<AnyCancellable>()
    @Published public private(set) var active = false
    @Published public private(set) var preferences: UsageDashboardPreferences
    public var onPreferencesChange: ((UsageDashboardPreferences) -> Void)?
    private var available = true
    public var providers: [String] { Provider.allCases.map(\.rawValue) }
    public var ranges: [String] { preferences.provider == "OpenAI" && preferences.allDevices ? ["7d", "30d"] : TokenRange.allCases.map(\.rawValue) }
    public var metrics: [String] { TokenMetric.allCases.map(\.rawValue) }
    public var loginSources: [String] { ClaudeLoginSource.allCases.map(\.rawValue) }
    public var loginSource: String { claude.loginSource.rawValue }
    public var accountLabel: String? { claude.authLabel }
    public var claudeConfigDirectory: URL { claude.configDirectory }
    public var loaded: Bool { tokens.loaded }
    public var activityWarning: String? { tokens.activityWarning }
    public var hasAccountActivity: Bool { tokens.activity != nil }
    public var accountEstimateBasis: String { tokens.mixFromLogs ? "this Mac’s token mix" : "a typical Codex token mix" }
    public func lifetime(provider: String) -> UsageLifetime? {
        provider == "Claude" ? tokens.claudeActivity.map(UsageLifetime.init) : tokens.activity.map(UsageLifetime.init)
    }
    public var planHistory: [UsagePlanPeriod] { (tokens.planHistory?.periods ?? []).map(UsagePlanPeriod.init) }
    public var planHistoryUpdatedAt: Date? { tokens.planHistory?.asOf }
    private var visibleViews = 0
    private var visibleTimer: Timer?

    public init(defaults: UserDefaults? = nil, fixtureRoot: URL? = nil) {
        let defaults = defaults ?? UsagePreferences.defaults
        self.defaults = defaults
        self.fixtureRoot = fixtureRoot
        claude = Store(defaults: defaults, startPolling: false)
        tokens = TokenStore(fixtureRoot: fixtureRoot, claudeDirectory: ClaudePaths.directory(defaults: defaults))
        var saved = defaults.data(forKey: "dashboardPreferences").flatMap { try? JSONDecoder().decode(UsageDashboardPreferences.self, from: $0) } ?? UsageDashboardPreferences()
        saved.loginSource = claude.loginSource.rawValue
        preferences = Self.validated(saved)
        claude.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        tokens.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    public func setActive(_ active: Bool) {
        guard !active || available else { return }
        guard active != self.active else { return }; self.active = active
        if active { if fixtureRoot == nil { claude.start() }; tokens.start() }
        else { claude.stop(); tokens.stop() }
        updateVisiblePolling()
    }
    public func setAvailable(_ available: Bool) {
        self.available = available
        setActive(available)
    }
    public func refresh() { guard active else { return }; if fixtureRoot == nil { claude.tick() }; tokens.refresh(forceLocal: true) }
    /// Visible graphs update promptly; cloud polling retains its independent cooldowns.
    public func setPresented(_ presented: Bool) {
        visibleViews = max(0, visibleViews + (presented ? 1 : -1))
        updateVisiblePolling()
    }
    private func updateVisiblePolling() {
        visibleTimer?.invalidate(); visibleTimer = nil
        guard active, visibleViews > 0 else { return }
        refresh()
        visibleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    public func selectLoginSource(_ value: String) {
        var next = preferences; next.loginSource = value; updatePreferences(next)
    }
    /// Machine-local profile selection, matching standalone; never part of portable exports.
    public func selectClaudeConfigDirectory(_ directory: URL) {
        claude.setConfigDirectory(directory)
        tokens.setClaudeDirectory(directory.standardizedFileURL)
        var next = preferences; next.loginSource = "Claude Code"; updatePreferences(next)
    }
    public func updatePreferences(_ value: UsageDashboardPreferences) {
        applyPreferences(value)
        onPreferencesChange?(preferences)
    }
    /// Import/apply without echoing the change back to the configuration writer.
    public func applyPreferences(_ value: UsageDashboardPreferences) {
        let value = Self.validated(value)
        guard value != preferences else { return }
        preferences = value
        defaults.set(try? JSONEncoder().encode(value), forKey: "dashboardPreferences")
        if let source = ClaudeLoginSource(rawValue: value.loginSource) { claude.setLoginSource(source) }
    }
    private static func validated(_ value: UsageDashboardPreferences) -> UsageDashboardPreferences {
        UsageDashboardPreferences(provider: Provider(rawValue: value.provider)?.rawValue ?? "Claude",
            range: value.provider == "OpenAI" && value.allDevices && value.range == "24h" ? "7d" : TokenRange(rawValue: value.range)?.rawValue ?? "7d",
            metric: TokenMetric(rawValue: value.metric)?.rawValue ?? "API cost",
            allDevices: value.allDevices,
            loginSource: ClaudeLoginSource(rawValue: value.loginSource)?.rawValue ?? "Automatic")
    }
    public func windows(provider: String, now: Date = Date()) -> [UsageWindow] {
        let source = provider == Provider.claude.rawValue ? claude.displayUsage(now: now) : tokens.codexLimits?.current(now: now)
        return (source?.limits ?? []).filter { $0.resetsAt.map { $0 > now } ?? true }.map {
            UsageWindow(id: $0.id, title: $0.label, percentage: $0.pct, resetsAt: $0.resetsAt, duration: $0.window)
        }
    }
    public func status(provider: String) -> String {
        if !active { return "Mr. Usage is disabled. Collection is paused." }
        if provider == Provider.claude.rawValue { return claude.status }
        if let error = tokens.liveError { return error }
        if tokens.checkingLive { return "Refreshing plan limits…" }
        if let limits = tokens.codexLimits, limits.current(now: Date()).limits.isEmpty, limits.credits == nil {
            return "Current limits are unknown. Last reading: \(resetClock(limits.asOf))."
        }
        return tokens.codexLimits == nil ? "Sign in to Codex or OpenCode to read plan limits." : "Newest available plan limits"
    }
    public func credits(provider: String) -> String? {
        if provider == Provider.claude.rawValue {
            guard let credits = claude.displayUsage()?.credits else { return nil }
            return "Extra usage: \(money(credits.usedCents))" + (credits.limitCents.map { " of \(money($0))" } ?? "")
        }
        return tokens.codexCredits.map { "Additional usage: \($0.displayBalance) credits" }
    }
    public func planName(provider: String) -> String? {
        if provider == "Claude" { return claude.authPlan }
        guard provider == "OpenAI", let plan = tokens.codexLimits?.plan, !plan.isEmpty else { return nil }
        switch plan {
        case "prolite": return "Pro Lite"
        case "promax": return "Pro Max"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        case let value where value.contains("business"): return "Business"
        case let value where value.hasPrefix("ent"): return "Enterprise"
        default: return plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    public func planSource(provider: String) -> String? {
        if provider == "Claude" { return claude.displayUsage() == nil ? nil : "Anthropic account" }
        guard let limits = tokens.codexLimits else { return nil }
        return limits.live ? "OpenAI account" : "Local Codex log"
    }
    public func planUpdatedAt(provider: String) -> Date? {
        provider == "Claude" ? claude.lastGoodAt : tokens.codexLimits?.asOf
    }
    public func chart(provider: String, range: String, metric: String, allDevices: Bool) -> UsageChart {
        let metric = TokenMetric(rawValue: metric) ?? .cost
        let account = provider == "OpenAI" && allDevices
        let range = account && range == "24h" ? TokenRange.week : TokenRange(rawValue: range) ?? .week
        let summary = tokens.summary(Provider(rawValue: provider) ?? .claude, account: account,
            range: range, metric: metric)
        return UsageChart(points: summary.buckets.map { UsageChartPoint(date: $0.start, value: $0.value) },
            models: summary.byModel.map { UsageModelTotal(name: $0.name, value: $0.value) },
            total: metric.format(summary.totals[metric] ?? 0), unpricedModels: summary.unpriced.sorted(),
            sources: summary.bySource.map { UsageSourceTotal(name: $0.name, value: $0.value) },
            totalTokens: summary.totalTokens,
            totals: TokenMetric.allCases.map { UsageMetricTotal(name: $0.rawValue, label: $0.label, value: summary.totals[$0] ?? 0) },
            range: range.rawValue, account: account)
    }
    public func format(_ value: Double, metric: String) -> String {
        (TokenMetric(rawValue: metric) ?? .cost).format(value)
    }
    isolated deinit { visibleTimer?.invalidate(); claude.stop(); tokens.stop() }
}
