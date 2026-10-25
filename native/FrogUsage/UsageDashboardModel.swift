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

    public init(id: String, title: String, percentage: Double, resetsAt: Date?, duration: TimeInterval?) {
        self.id = id; self.title = title; self.percentage = percentage; self.resetsAt = resetsAt; self.duration = duration
    }

    public func pace(at now: Date) -> String? {
        guard percentage.isFinite, let resetsAt, resetsAt > now,
              let duration, duration.isFinite, duration > 0,
              resetsAt.timeIntervalSince(now) <= duration else { return nil }
        let elapsed = 1 - resetsAt.timeIntervalSince(now) / duration
        let used = max(0, percentage / 100)
        return used >= 1 ? "Limit reached" : used > elapsed + 0.1 ? "Ahead of pace" : used < elapsed - 0.1 ? "Under pace" : "On pace"
    }

    /// "37%", rounded down so that 100% shows only once the limit is reached. The menu bar and
    /// the dashboard both show this; "—" for a window without a reading.
    public var usedText: String { usedPercent.map { String(format: "%.0f%%", $0) } ?? "—" }
    /// "63% left", what the shown share leaves, so the two always add up to 100.
    public var leftText: String? { usedPercent.map { String(format: "%.0f%% left", max(0, 100 - $0)) } }
    private var usedPercent: Double? { percentage.isFinite ? max(0, percentage).rounded(.down) : nil }
    /// "15:40" today, "Thu 09:00" within the week, else "12 Oct"; nil without a renewal time.
    public func resetText(now: Date = Date()) -> String? { resetsAt.map { resetClock($0, now: now) } }
}

/// Portable display choices only. Credentials, readings and request gates stay local.
public struct UsageDashboardPreferences: Codable, Equatable {
    public var provider: String
    public var range: String
    public var metric: String
    /// Legacy configuration field, retained for round trips; activity is always combined.
    public var allDevices: Bool
    public var loginSource: String
    /// Shows each Claude account found on this Mac instead of one.
    public var claudeAccounts: Bool
    /// "each" or "combined".
    public var claudeAccountsView: String
    /// The window the menu bar shows per account: "session" or "week".
    public var claudeAccountsMenuBar: String
    /// How the menu-bar item draws its limits: "numbers", "segments", "bars" or "columns".
    public var menuBarStyle: String
    /// Its colours: "clean", "level" or "spectrum".
    public var menuBarPalette: String

    public static let claudeAccountsViews = ["each", "combined"]
    public static let claudeAccountsMenuBarWindows = ["session", "week"]

    public init(provider: String = "Claude", range: String = "7d", metric: String = "API cost",
                allDevices: Bool = false, loginSource: String = "Automatic", claudeAccounts: Bool = false,
                claudeAccountsView: String = "each", claudeAccountsMenuBar: String = "session",
                menuBarStyle: String = "numbers", menuBarPalette: String = "clean") {
        self.provider = provider; self.range = range; self.metric = metric
        self.allDevices = allDevices; self.loginSource = loginSource
        self.claudeAccounts = claudeAccounts; self.claudeAccountsView = claudeAccountsView
        self.claudeAccountsMenuBar = claudeAccountsMenuBar
        self.menuBarStyle = menuBarStyle; self.menuBarPalette = menuBarPalette
    }

    private enum CodingKeys: String, CodingKey {
        case provider, range, metric, allDevices, loginSource, claudeAccounts, claudeAccountsView, claudeAccountsMenuBar
        case menuBarStyle, menuBarPalette
    }

    /// Choices saved before a field existed load with that field's default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? defaults.provider
        range = try values.decodeIfPresent(String.self, forKey: .range) ?? defaults.range
        metric = try values.decodeIfPresent(String.self, forKey: .metric) ?? defaults.metric
        allDevices = try values.decodeIfPresent(Bool.self, forKey: .allDevices) ?? defaults.allDevices
        loginSource = try values.decodeIfPresent(String.self, forKey: .loginSource) ?? defaults.loginSource
        claudeAccounts = try values.decodeIfPresent(Bool.self, forKey: .claudeAccounts) ?? defaults.claudeAccounts
        claudeAccountsView = try values.decodeIfPresent(String.self, forKey: .claudeAccountsView) ?? defaults.claudeAccountsView
        claudeAccountsMenuBar = try values.decodeIfPresent(String.self, forKey: .claudeAccountsMenuBar) ?? defaults.claudeAccountsMenuBar
        menuBarStyle = try values.decodeIfPresent(String.self, forKey: .menuBarStyle) ?? defaults.menuBarStyle
        menuBarPalette = try values.decodeIfPresent(String.self, forKey: .menuBarPalette) ?? defaults.menuBarPalette
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

/// The places that show usage on screen.
public enum UsagePresenter: Hashable, Sendable { case dashboard, popup }

/// One Claude account while Frog shows each: its limits as its own store reads them.
public struct UsageAccountSummary: Identifiable {
    /// The account's slot path; stable while its folders stay where they are.
    public let id: String
    public let label: String
    /// The first six characters, for the menu bar.
    public let shortLabel: String
    /// Session, Week, Week · Sonnet and Week · Opus, as far as the reading has them.
    public let windows: [UsageWindow]
    public let plan: String?
    /// "Claude app · Claude-Account-B", "Claude Code · ~/.claude".
    public let sources: [String]
    /// When the reading on display was made.
    public let age: Date?
    /// Where that reading came from: "Claude app" or "Anthropic account".
    public let readingSource: String?
    /// No reading, or one older than 30 minutes.
    public let stale: Bool
    public let status: String?
    /// Counts in the menu bar and in combined values.
    public let included: Bool
    /// Known only from the Claude app, which saved nothing recent, while Claude Code could sign in.
    public let needsLiveSetup: Bool
    /// "Claude and Claude-2 are signed in to the same account".
    public let mergedNote: String?
    /// What is wrong with the reading on display, nil while it is current: "Saved by the Claude
    /// app at 07:53. …" for an old app reading, or why the account could not be checked.
    public var warning: String? = nil
    /// Has a Claude Code folder whose login is gone, and no current Claude app reading.
    public var needsSignIn = false
    /// Its sign-in was asked for and Claude Code's login is being checked first.
    public var checkingSignIn = false
}

/// One kind of limit, such as the session, over every included Claude account.
public typealias UsageCombinedWindow = ClaudeAccountsCombination.Combined

extension ClaudeAccountsCombination.Combined: Identifiable {
    public var id: String { window.id }
}

/// Optional usage module: construction never scans files or reads credentials.
/// Disabling cancels owned polling and rejects results from previous generations.
@MainActor public final class UsageDashboardModel: ObservableObject {
    /// The one Claude account Frog reads while it does not show each account.
    private let claude: Store
    /// Every Claude account on this Mac; it only looks for them while the switch is off.
    let claudeAccountsModel: ClaudeAccountsModel
    private let tokens: TokenStore
    private let fixtureRoot: URL?
    private let defaults: UserDefaults
    private var observations = Set<AnyCancellable>()
    @Published public private(set) var active = false
    @Published public private(set) var preferences: UsageDashboardPreferences
    public var onPreferencesChange: ((UsageDashboardPreferences) -> Void)?
    private var available = true
    public var providers: [String] { Provider.allCases.map(\.rawValue) }
    public var ranges: [String] { preferences.provider == "OpenAI" ? ["7d", "30d"] : TokenRange.allCases.map(\.rawValue) }
    public var metrics: [String] { TokenMetric.allCases.map(\.rawValue) }
    public var loginSources: [String] { ClaudeLoginSource.allCases.map(\.rawValue) }
    public var loginSource: String { claude.loginSource.rawValue }
    public var accountLabel: String? { primary.authLabel }
    public var claudeConfigDirectory: URL { primary.configDirectory }
    public var loaded: Bool { tokens.loaded }
    public var activityWarning: String? { tokens.activityWarning }
    public var hasAccountActivity: Bool { tokens.activity != nil }
    public var accountEstimateBasis: String { tokens.mixFromLogs ? "this Mac’s token mix" : "a typical Codex token mix" }
    public func lifetime(provider: String) -> UsageLifetime? {
        provider == "Claude" ? tokens.claudeActivity.map(UsageLifetime.init) : tokens.activity.map(UsageLifetime.init)
    }
    public var planHistory: [UsagePlanPeriod] { (tokens.planHistory?.periods ?? []).map(UsagePlanPeriod.init) }
    public var planHistoryUpdatedAt: Date? { tokens.planHistory?.asOf }
    private var presenters: Set<UsagePresenter> = []
    private(set) var visibleTimer: Timer?
    /// Whether something on screen currently keeps the ten-second refresh going.
    public var isVisiblePolling: Bool { visibleTimer != nil }

    public convenience init(defaults: UserDefaults? = nil, fixtureRoot: URL? = nil) {
        self.init(defaults: defaults, fixtureRoot: fixtureRoot, claudeAccounts: nil)
    }
    /// `claudeAccounts` replaces the accounts' discovery and stores, for tests.
    init(defaults: UserDefaults?, fixtureRoot: URL?, claudeAccounts: ClaudeAccountsModel?) {
        let defaults = defaults ?? UsagePreferences.defaults
        self.defaults = defaults
        self.fixtureRoot = fixtureRoot
        // Fixture models never read this Mac's real Claude app history.
        let live = fixtureRoot == nil, desktopFiles = ClaudeDesktopFiles()
        claude = Store(defaults: defaults, startPolling: false,
                       readDesktop: { live ? readClaudeDesktop(directory: $0, files: desktopFiles) : nil },
                       renewLogin: { live ? ClaudeCodeCLI.renewLogin(directory: $0, deadline: $1) : .unavailable })
        // A fixture model looks for accounts in the fixture's folders and never reads a login.
        claudeAccountsModel = claudeAccounts ?? ClaudeAccountsModel(
            defaults: defaults, home: fixtureRoot ?? FileManager.default.homeDirectoryForCurrentUser,
            environment: live ? ProcessInfo.processInfo.environment : [:],
            makeStore: { account, delay in
                let files = ClaudeDesktopFiles(), profiles = [account.profileFile].compactMap { $0 }
                let store = Store(account: account, defaults: defaults,
                                  readAuth: { live ? readClaudeAuth(source: $0, directory: $1) : nil },
                                  fetchLimits: { token in
                                      guard live else { throw FetchError.noToken }
                                      return try await fetchUsage(token: token)
                                  },
                                  readDesktop: { readClaudeDesktop(folder: $0, profiles: profiles, files: files) },
                                  renewLogin: { live ? ClaudeCodeCLI.renewLogin(directory: $0, deadline: $1) : .unavailable })
                store.startDelay = delay
                return store
            })
        tokens = TokenStore(fixtureRoot: fixtureRoot, claudeDirectory: ClaudePaths.directory(defaults: defaults))
        var saved = defaults.data(forKey: "dashboardPreferences").flatMap { try? JSONDecoder().decode(UsageDashboardPreferences.self, from: $0) } ?? UsageDashboardPreferences()
        saved.loginSource = claude.loginSource.rawValue
        preferences = Self.validated(saved)
        claude.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        claudeAccountsModel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        // While each account is shown, the activity also counts the calls in their Claude Code
        // folders, such as `~/.claude-work`, which the usual folders leave out.
        claudeAccountsModel.$accounts.sink { [weak self] accounts in
            self?.tokens.setClaudeAccountFolders(accounts.flatMap(\.codeFolders))
        }.store(in: &observations)
        tokens.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    public func setActive(_ active: Bool) {
        guard !active || available else { return }
        guard active != self.active else { return }; self.active = active
        if active {
            if fixtureRoot == nil, !claudeAccountsModel.enabled { claude.start() }
            claudeAccountsModel.start(); tokens.start()
        }
        else { claude.stop(); claudeAccountsModel.stop(); tokens.stop() }
        updateVisiblePolling()
    }
    public func setAvailable(_ available: Bool) {
        self.available = available
        updateClaudeAccounts()
        setActive(available)
    }
    /// The Refresh button: also looks for Claude accounts again.
    public func refresh() {
        guard active else { return }
        claudeAccountsModel.detect()
        refreshShown()
    }
    private func refreshShown() {
        guard active else { return }
        if fixtureRoot == nil { claude.tick() }
        claudeAccountsModel.tick()
        tokens.refresh(forceLocal: true)
    }
    /// Each account's store takes over from the one store, which shares the default account's
    /// saved request gate, so only one of them runs at a time.
    private func updateClaudeAccounts() {
        let on = preferences.claudeAccounts && available
        guard on != claudeAccountsModel.enabled else { return }
        if on { claude.stop() }
        claudeAccountsModel.setEnabled(on)
        if !on {
            claude.reloadPolling()
            if active, fixtureRoot == nil { claude.start() }
        }
    }
    /// The store the single-account surfaces read: while each account is shown, the default account's.
    private var primary: Store {
        guard claudeAccountsModel.enabled else { return claude }
        let accounts = claudeAccountsModel.accounts
        guard let account = accounts.first(where: { $0.pollingKey == ClaudePollingState.defaultsKey }) ?? accounts.first,
              let store = claudeAccountsModel.stores[account.id] else { return claude }
        return store
    }
    /// Visible graphs update promptly; cloud polling retains its independent cooldowns.
    /// A presenter may repeat itself: a window that keeps its page after closing reports
    /// "hidden" on every change of its state, also in the middle of a view update.
    public func setPresented(_ presented: Bool, for presenter: UsagePresenter) {
        guard presented != presenters.contains(presenter) else { return }
        if presented { presenters.insert(presenter) } else { presenters.remove(presenter) }
        // One leaving while another still shows changes nothing for the one that stays.
        if presented || presenters.isEmpty { updateVisiblePolling() }
    }
    private func updateVisiblePolling() {
        visibleTimer?.invalidate(); visibleTimer = nil
        guard active, !presenters.isEmpty else { return }
        refreshShown()
        visibleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshShown() }
        }
        visibleTimer?.tolerance = 1
    }
    public func selectLoginSource(_ value: String) {
        var next = preferences; next.loginSource = value; updatePreferences(next)
    }
    /// Claude limits cannot be read until the user signs in to Claude Code.
    /// An account known only from the Claude app is set up with `liveSetupCommand(for:)` instead.
    public var needsClaudeSignIn: Bool {
        let store = primary
        if let account = store.account, account.codeFolder == nil { return false }
        return fixtureRoot == nil && active && store.needsClaudeCodeLogin
    }
    /// A sign-in was asked for and Claude Code's login is being checked first; asking again does nothing.
    public var checkingClaudeSignIn: Bool { primary.checkingLogin }
    /// The shell command for Claude Code's own sign-in; nil when Claude Code is not installed.
    public var claudeSignInCommand: String? {
        ClaudeCodeCLI.executable().map { ClaudeCodeCLI.signInCommand(executable: $0, directory: primary.configDirectory) }
    }
    /// The user asked to sign in. From now on the account is checked through Claude Code's login,
    /// and the result says whether the user still has to sign in for that.
    public func beginClaudeSignIn() async -> Bool {
        if !claudeAccountsModel.enabled, claude.loginSource == .claudeDesktop { selectLoginSource(ClaudeLoginSource.automatic.rawValue) }
        return await primary.beginSignIn()
    }
    /// Machine-local profile selection, matching standalone; never part of portable exports.
    public func selectClaudeConfigDirectory(_ directory: URL) {
        claude.setConfigDirectory(directory)
        tokens.setClaudeDirectory(directory.standardizedFileURL)
        var next = preferences; next.loginSource = "Claude Code"; updatePreferences(next)
    }
    public func updatePreferences(_ value: UsageDashboardPreferences) {
        guard Self.validated(value) != preferences else { return }
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
        updateClaudeAccounts()
    }
    private static func validated(_ value: UsageDashboardPreferences) -> UsageDashboardPreferences {
        UsageDashboardPreferences(provider: Provider(rawValue: value.provider)?.rawValue ?? "Claude",
            range: value.provider == "OpenAI" && value.range == "24h" ? "7d" : TokenRange(rawValue: value.range)?.rawValue ?? "7d",
            metric: TokenMetric(rawValue: value.metric)?.rawValue ?? "API cost",
            allDevices: value.allDevices,
            loginSource: ClaudeLoginSource(rawValue: value.loginSource)?.rawValue ?? "Automatic",
            claudeAccounts: value.claudeAccounts,
            claudeAccountsView: UsageDashboardPreferences.claudeAccountsViews.contains(value.claudeAccountsView) ? value.claudeAccountsView : "each",
            claudeAccountsMenuBar: UsageDashboardPreferences.claudeAccountsMenuBarWindows.contains(value.claudeAccountsMenuBar)
                ? value.claudeAccountsMenuBar : "session")
    }
    public func windows(provider: String, now: Date = Date()) -> [UsageWindow] {
        let claude = provider == Provider.claude.rawValue
        let source = claude ? primary.displayUsage(now: now) : tokens.codexLimits?.current(now: now)
        return Self.windows(source, claude: claude, now: now)
    }
    private static func windows(_ source: Usage?, claude: Bool, now: Date) -> [UsageWindow] {
        var windows = (source?.limits ?? []).filter { $0.resetsAt.map { $0 > now } ?? true }.map {
            UsageWindow(id: $0.id, title: $0.label, percentage: $0.pct, resetsAt: $0.resetsAt, duration: $0.window)
        }
        // A Claude plan always has a session and a week. A session that renewed after the last
        // reading keeps its row, marked unknown, instead of leaving the week on its own.
        if claude, !windows.isEmpty, !windows.contains(where: { $0.id == "five_hour" }) {
            windows.insert(UsageWindow(id: "five_hour", title: "Session", percentage: .nan, resetsAt: nil, duration: 5 * 3600), at: 0)
        }
        return windows
    }
    public func status(provider: String) -> String {
        if !active { return "Mr. Usage is disabled. Collection is paused." }
        if provider == Provider.claude.rawValue { return primary.status }
        if let error = tokens.liveError { return error }
        if tokens.checkingLive { return "Refreshing plan limits…" }
        if let limits = tokens.codexLimits, limits.current(now: Date()).limits.isEmpty, limits.credits == nil {
            return "Current limits are unknown. Last reading: \(resetClock(limits.asOf))."
        }
        return tokens.codexLimits == nil ? "Sign in to Codex or OpenCode to read plan limits." : "Newest available plan limits"
    }
    public func planWarning(provider: String) -> String? {
        if provider == Provider.claude.rawValue { return primary.warning }
        return tokens.liveError
    }
    public func credits(provider: String) -> String? {
        if provider == Provider.claude.rawValue {
            guard let credits = primary.displayUsage()?.credits else { return nil }
            return "Extra usage: \(money(credits.usedCents))" + (credits.limitCents.map { " of \(money($0))" } ?? "")
        }
        return tokens.codexCredits.map { "Additional usage: \($0.displayBalance) credits" }
    }
    public func planName(provider: String) -> String? {
        if provider == "Claude" { return primary.plan }
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
        if provider == "Claude" { return primary.reading().map { $0.source == .desktop ? "Claude app" : "Anthropic account" } }
        guard let limits = tokens.codexLimits else { return nil }
        return limits.live ? "OpenAI account" : "Local Codex log"
    }
    public func planUpdatedAt(provider: String) -> Date? {
        provider == "Claude" ? primary.reading()?.at ?? primary.lastGoodAt : tokens.codexLimits?.asOf
    }
    public func chart(provider: String, range: String, metric: String) -> UsageChart {
        let metric = TokenMetric(rawValue: metric) ?? .cost
        // The account counts by UTC day. Until it answers, only this Mac's logs are shown, by its own days.
        let account = provider == "OpenAI" && tokens.activity != nil
        let range = provider == "OpenAI" && range == "24h" ? TokenRange.week : TokenRange(rawValue: range) ?? .week
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
    /// Chart scale labels: whole dollars lose their cents, "$100" instead of "$100.00".
    public func axisLabel(_ value: Double, metric: String) -> String {
        let metric = TokenMetric(rawValue: metric) ?? .cost
        guard metric == .cost, value < 1000, value == value.rounded() else { return metric.format(value) }
        return String(format: "$%.0f", value)
    }
    isolated deinit { visibleTimer?.invalidate(); claude.stop(); claudeAccountsModel.stop(); tokens.stop() }
}

// MARK: - Several Claude accounts

extension UsageDashboardModel {
    /// The limit windows an account's row shows, in this order.
    static let accountWindowIDs = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]

    /// Each Claude account on this Mac is shown on its own or combined.
    public var claudeAccountsEnabled: Bool { claudeAccountsModel.enabled }

    /// Each account and its reading, in slot order; empty while the switch is off.
    public func accounts(now: Date = Date()) -> [UsageAccountSummary] {
        guard claudeAccountsModel.enabled else { return [] }
        let model = claudeAccountsModel
        return model.accounts.map { account in
            let store = model.stores[account.id], label = model.label(account)
            let reading = store?.reading(now: now)
            let windows = Self.windows(reading?.usage, claude: true, now: now).filter { Self.accountWindowIDs.contains($0.id) }
            return UsageAccountSummary(
                id: account.id, label: label, shortLabel: ClaudeAccountLabels.shortLabel(label), windows: windows,
                plan: store?.plan, sources: sources(of: account), age: reading?.at,
                readingSource: reading.map { $0.source == .desktop ? "Claude app" : "Anthropic account" },
                stale: reading.map { now.timeIntervalSince($0.at) > ClaudeDesktopUsage.freshness } ?? true,
                status: store?.status, included: model.isIncluded(account),
                needsLiveSetup: model.needsLiveSetup(account, now: now), mergedNote: account.mergedDescription,
                // A login that is gone is worth saying also before the first reading.
                warning: store.flatMap { $0.warning ?? ($0.needsClaudeCodeLogin ? $0.status : nil) }, needsSignIn: active && account.codeFolder != nil && store?.needsClaudeCodeLogin == true,
                checkingSignIn: store?.checkingLogin ?? false)
        }
    }

    /// Session, Week and the model weeks over the included accounts, for each kind any of them has.
    public func combinedWindows(now: Date = Date()) -> [UsageCombinedWindow] {
        let accounts = accounts(now: now)
        let inputs = accounts.map { ClaudeAccountsCombination.Account(label: $0.label, included: $0.included, plan: $0.plan, windows: $0.windows) }
        let kinds = Self.accountWindowIDs.filter { id in accounts.contains { $0.included && $0.windows.contains { $0.id == id } } }
        return kinds.map { ClaudeAccountsCombination.combine(inputs, window: $0, now: now) }
    }

    /// Frog is looking for Claude accounts, after the switch was turned on or on Refresh.
    public var searchingClaudeAccounts: Bool { claudeAccountsModel.searching }

    /// Accounts the last search found, also while the switch is off.
    public var detectedAccountCount: Int { claudeAccountsModel.detectedCount }

    /// Offers once to show each account, until it is accepted or declined.
    public var accountsNoticeVisible: Bool {
        !preferences.claudeAccounts && !claudeAccountsModel.noticeDismissed && claudeAccountsModel.detectedCount >= 2
    }

    /// "Frog found 2 Claude accounts on this Mac: the Claude app’s “Claude” and “Claude-Account-B”
    /// folders. Show usage for each? Frog reads their saved limits locally."
    public var accountsNoticeText: String {
        let found = claudeAccountsModel.detectedFolders
        let names = found.names.map { "“\($0)”" }
        let list = names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Frog found \(claudeAccountsModel.detectedCount) Claude accounts on this Mac: \(found.app ? "the Claude app’s" : "Claude Code’s") \(list) folders. Show usage for each? Frog reads their saved limits locally."
    }

    /// "Show both", or "Show all 3" for more.
    public var accountsNoticeAction: String {
        claudeAccountsModel.detectedCount > 2 ? "Show all \(claudeAccountsModel.detectedCount)" : "Show both"
    }

    /// Show both: turns the switch on and saves it through `onPreferencesChange`.
    public func showAllAccounts() {
        var next = preferences; next.claudeAccounts = true; updatePreferences(next)
    }

    /// Not now: the notice never comes back; the switch stays on the page.
    public func dismissAccountsNotice() { claudeAccountsModel.dismissNotice() }

    public func renameAccount(_ id: String, to label: String) { claudeAccountsModel.rename(id, to: label) }

    public func setAccountIncluded(_ id: String, _ on: Bool) { claudeAccountsModel.setIncluded(id, on) }

    /// "Add folder…": a Claude app data folder or a Claude Code folder the search does not find.
    public func addClaudeAccountFolder(_ url: URL) { claudeAccountsModel.addFolder(url) }

    /// The Terminal command that signs Claude Code in to a new profile for an account known only
    /// from the Claude app; nil when Claude Code is not installed or the account has a login.
    public func liveSetupCommand(for id: String) -> String? { claudeAccountsModel.liveSetupCommand(for: id) }

    /// Claude Code's own sign-in for an account's Claude Code folder, while each account is
    /// shown; nil when Claude Code is not installed or the account has no such folder.
    public func claudeSignInCommand(for id: String) -> String? { claudeAccountsModel.signInCommand(for: id) }

    /// As `beginClaudeSignIn()`, for one account: false when its login turned out to be current
    /// or could be renewed, so nobody has to sign in.
    public func beginClaudeSignIn(for id: String) async -> Bool {
        guard let store = claudeAccountsModel.stores[id] else { return false }
        return await store.beginSignIn()
    }

    /// The Claude Code login an account's readings use, with its e-mail address: only for hover help.
    public func accountLogin(for id: String) -> String? { claudeAccountsModel.stores[id]?.authLabel }

    /// "Claude app · Claude-Account-B", "Claude Code · ~/.claude"; the home folder written as `~`.
    private func sources(of account: ClaudeAccount) -> [String] {
        let home = claudeAccountsModel.home.standardizedFileURL.path
        let support = home + "/Library/Application Support/"
        func shown(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(support) { return String(path.dropFirst(support.count)) }
            return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        var sources = account.appFolder.map { ["Claude app · \(shown($0))"] } ?? []
        sources += account.mergedFolders.filter { ClaudeAccountDiscovery.isAppFolderName($0.lastPathComponent) }
            .map { "Claude app · \(shown($0))" }
        sources += account.codeFolders.map { "Claude Code · \(shown($0))" }
        return sources
    }
}
