import SwiftUI
import Charts
import FrogUsage

/// LLM usage's page: the plan limits, the token activity, the Claude accounts and the menu-bar item.
struct UsageDashboardView: View {
    @ObservedObject var plugin: LLMUsagePlugin
    @ObservedObject var usage: UsageDashboardModel

    var body: some View {
        let provider = usage.preferences.provider
        FrogPage {
            FrogPageHeader(title: "LLM usage") {
                FrogDropdown(selected: provider, options: usage.providers, width: 120, title: { $0 }) { usage.selectProvider($0) }
                    .accessibilityLabel("Provider")
                IconAction(title: "Refresh", symbol: "arrow.clockwise", bordered: true) { usage.refresh() }
            }
            if provider == "Claude", usage.accountsNoticeVisible { UsageAccountsNotice(usage: usage) }
            if UsageStatusPopover.shownAccounts(usage).isEmpty { UsageLimitsSection(usage: usage) }
            else { FrogSection("Limits") { UsageAccountsLimits(usage: usage).padding(.vertical, 10) } }
            UsageActivitySection(usage: usage)
            UsageHistorySections(usage: usage)
            if provider == "Claude" { UsageClaudeSection(usage: usage) }
            UsageMenuBarSection(plugin: plugin, usage: usage)
        }
        // The main window keeps this page after it is closed or minimised, so appearing and
        // disappearing do not say whether anyone can see it.
        .background(FeatureVisibility { usage.setPresented($0, for: .dashboard) })
    }
}

extension UsageDashboardModel {
    func selectProvider(_ provider: String) {
        var next = preferences; next.provider = provider; updatePreferences(next)
    }
}

/// Offers once to show each Claude account Frog found; Not now never asks again.
struct UsageAccountsNotice: View {
    @ObservedObject var usage: UsageDashboardModel
    /// In the popup: compact buttons, and the radius of a block inside a popup.
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(usage.accountsNoticeText).font(FrogType.body).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(usage.accountsNoticeAction) { usage.showAllAccounts() }.buttonStyle(.frog(.primary, compact: compact))
                Button("Not now") { usage.dismissAccountsNotice() }.buttonStyle(.frog(compact: compact))
            }
        }.padding(compact ? 8 : 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: compact ? FrogStyle.controlRadius : FrogStyle.cardRadius))
            .accessibilityElement(children: .contain)
    }
}

// MARK: Limits

/// The one account's or provider's plan windows, with where they came from beside the title.
private struct UsageLimitsSection: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let provider = usage.preferences.provider
            let windows = usage.windows(provider: provider, now: context.date)
            let status = usage.status(provider: provider)
            FrogSection("Limits") {
                HStack(spacing: 6) {
                    if let source = usage.planSource(provider: provider), let updated = usage.planUpdatedAt(provider: provider) {
                        Text("\(source) · \(UsageStatusPopover.age(of: updated, at: context.date))")
                            .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                            .help(updated.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let plan = usage.planName(provider: provider) { UsagePlanBadge(plan: plan) }
                }.help(provider == "Claude" ? usage.accountLabel ?? "" : "")
            } content: {
                let normal = status == "Newest available plan limits"
                if windows.isEmpty {
                    // One line: why there is no reading, or that there is none.
                    FrogRowNote(text: normal ? "No current reading" : status).textSelection(.enabled)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: windows.count == 1 ? 1 : 2),
                              alignment: .leading, spacing: 18) {
                        ForEach(windows) { UsageLimitView(window: $0, now: context.date) }
                    }.padding(.vertical, 10)
                }
                if !normal, !windows.isEmpty { FrogRowNote(text: status).textSelection(.enabled) }
                if provider == "Claude", usage.needsClaudeSignIn {
                    FrogRow("Claude Code login") {
                        Button(usage.checkingClaudeSignIn ? "Checking…" : "Sign in…") { ClaudeSignIn.start(usage) }
                            .buttonStyle(.frog()).disabled(usage.checkingClaudeSignIn)
                    }
                }
                if let credits = usage.credits(provider: provider) {
                    FrogRow("Credits") { Text(credits).font(FrogType.small).foregroundStyle(FrogStyle.muted) }
                }
            }
        }
    }
}

/// While Frog shows several Claude accounts: each one's limits, or one set of combined limits.
struct UsageAccountsLimits: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let accounts = usage.accounts(now: context.date).filter(\.included)
            VStack(alignment: .leading, spacing: compact ? 10 : 18) {
                if accounts.isEmpty {
                    Text("No account is included.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                } else if usage.preferences.claudeAccountsView == "combined" {
                    combined(accounts, now: context.date)
                } else if compact {
                    SectionCaption(text: "Plan limits")
                    ForEach(accounts.prefix(4)) { UsageAccountRow(account: $0, now: context.date) }
                } else {
                    ForEach(accounts) { UsageAccountLimits(account: $0, now: context.date) }
                }
            }
        }
    }

    /// One bar per kind of limit, each with what every account adds to it; no renewal and no
    /// pace, because each account renews on its own clock.
    @ViewBuilder private func combined(_ accounts: [UsageAccountSummary], now: Date) -> some View {
        let windows = usage.combinedWindows(now: now)
        Text(accounts.map(\.label).joined(separator: " + "))
            .font(compact ? FrogType.label : FrogType.bodyMedium).foregroundStyle(compact ? FrogStyle.muted : FrogStyle.ink)
            .lineLimit(1).help(windows.first?.basisDescription ?? "")
        if windows.isEmpty {
            Text("No current reading").font(FrogType.bodyMedium)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact || windows.count == 1 ? 1 : 2),
                      alignment: .leading, spacing: compact ? 14 : 18) {
                ForEach(compact ? Array(windows.prefix(4)) : windows) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        UsageLimitView(window: entry.window, now: now, compact: compact)
                        Text(([entry.breakdown] + entry.missing.map { "\($0): no reading" }).filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                            .help(entry.renewals)
                    }.opacity(entry.missing.isEmpty ? 1 : 0.55)
                }
            }
        }
    }
}

/// One account's block on the page: its label, plan and age, then its limits.
private struct UsageAccountLimits: View {
    let account: UsageAccountSummary
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(account.label).font(FrogType.bodyMedium)
                if let plan = account.plan { UsagePlanBadge(plan: plan) }
                Spacer()
                if let age = account.age {
                    Text([account.readingSource, UsageStatusPopover.age(of: age, at: now)].compactMap { $0 }.joined(separator: " · "))
                        .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        .help(age.formatted(date: .abbreviated, time: .shortened))
                }
                if account.stale, !account.windows.isEmpty {
                    let reason = account.warning ?? account.status ?? "No current reading"
                    Image(systemName: "exclamationmark.circle").font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                        .help(reason).accessibilityLabel(reason)
                }
            }
            if account.windows.isEmpty {
                Text(account.status ?? "No current reading").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: account.windows.count == 1 ? 1 : 2),
                          alignment: .leading, spacing: 18) {
                    ForEach(account.windows) { UsageLimitView(window: $0, now: now) }
                }.opacity(account.stale ? 0.55 : 1).help(account.status ?? "")
            }
        }
    }
}

struct UsagePlanBadge: View {
    let plan: String
    var body: some View { FrogBadge(text: plan).lineLimit(1) }
}

/// One plan window: its share used as a bar, a tick for the time gone, what is left and when it renews.
struct UsageLimitView: View {
    let window: UsageWindow
    let now: Date
    var compact = false
    private var fraction: Double { window.percentage.isFinite ? min(1, max(0, window.percentage / 100)) : 0 }
    /// Nearly used is critical whatever the pace; otherwise the bar says how the window is going.
    private var meterColor: Color {
        if fraction >= 0.95 { return FrogStyle.critical }
        switch window.pace(at: now) {
        case "Ahead of pace": return FrogStyle.warning
        case "Under pace": return FrogStyle.good
        case nil: return FrogStyle.level(fraction, warning: 0.8, critical: 0.95)
        default: return FrogStyle.accent
        }
    }
    private func paceColor(_ pace: String) -> Color {
        switch pace {
        case "Ahead of pace": FrogStyle.warning
        case "Under pace": FrogStyle.good
        case "Limit reached": FrogStyle.critical
        default: FrogStyle.muted
        }
    }
    private var elapsed: Double? {
        guard let reset = window.resetsAt, let duration = window.duration, duration > 0 else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / duration))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(FrogType.bodyMedium)
                Spacer()
                Text(window.usedText).font(GraphStyle.figure).monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(FrogStyle.inset)
                Capsule().fill(meterColor).frame(width: geometry.size.width * fraction)
                if let elapsed {
                    Rectangle().fill(FrogStyle.ink.opacity(0.55)).frame(width: 1, height: 9)
                        .offset(x: max(0, min(geometry.size.width - 1, geometry.size.width * elapsed)), y: -2)
                }
            }.frame(height: 5).accessibilityHidden(true).help("The tick marks the time gone in this window.")
            HStack(spacing: 4) {
                Text(window.leftText ?? "No reading since it renewed")
                // A week's pace says something; a session's changes too fast to.
                if (window.duration ?? 0) >= 604800 || !compact, let pace = window.pace(at: now) {
                    Text("· \(pace)").foregroundStyle(paceColor(pace))
                        .help(elapsed.map { "\(Int(fraction * 100))% used with \(Int($0 * 100))% of the window gone" } ?? "")
                }
                Spacer(minLength: 4)
                if let reset = window.resetsAt {
                    Text("Resets in \(Duration.seconds(max(0, reset.timeIntervalSince(now))).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1)))")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                }
            }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }.padding(.trailing, compact ? 0 : 8).accessibilityElement(children: .combine)
    }
}

// MARK: Activity

/// Token activity over the chosen period: the total, the chart, the totals by kind, models and sources.
private struct UsageActivitySection: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        let settings = usage.preferences
        let chart = usage.chart(provider: settings.provider, range: settings.range, metric: settings.metric)
        FrogSection("Activity") {
            UsageMetricDropdown(usage: usage)
            UsageRangeDropdown(usage: usage, compact: true)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                UsageActivityTotal(usage: usage, chart: chart, page: true)
                UsageActivityChart(usage: usage, chart: chart, compact: false)
            }.padding(.vertical, 10)
            if usage.loaded, chart.hasActivity { UsageTokenTotals(usage: usage, chart: chart).padding(.bottom, 10) }
            UsageActivityNotes(usage: usage, chart: chart, compact: false)
            if settings.provider == "OpenAI", !usage.hasAccountActivity {
                FrogRowNote(text: "Account activity is unavailable; showing this Mac’s logs.")
            }
        }
        if usage.loaded, chart.hasActivity, !chart.models.isEmpty {
            FrogSection("Models") {
                ForEach(chart.models) { row in
                    FrogRow(row.name) { Text(usage.format(row.value, metric: settings.metric)).monospacedDigit() }.help(row.name)
                }
            }
        }
        if usage.loaded, !chart.sources.isEmpty {
            FrogSection("Sources") {
                ForEach(chart.sources) { source in
                    FrogRow(source.name) { Text(usage.format(source.value, metric: settings.metric)).monospacedDigit() }
                }
            }
        }
    }
}

struct UsageMetricDropdown: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        FrogDropdown(selected: usage.preferences.metric, options: usage.metrics, width: 120, compact: true,
                     title: { $0 == "Input" ? "Uncached input" : $0 }) { metric in
            var next = usage.preferences; next.metric = metric; usage.updatePreferences(next)
        }.buttonTitle { $0 }.accessibilityLabel("Activity metric")
    }
}

struct UsageRangeDropdown: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        FrogDropdown(selected: usage.preferences.range, options: usage.ranges, width: compact ? 70 : 150, compact: true,
                     title: Self.title) { range in
            var next = usage.preferences; next.range = range; usage.updatePreferences(next)
        }.buttonTitle { compact ? $0 : Self.title($0) }.accessibilityLabel("Activity period")
    }
    static func title(_ range: String) -> String {
        switch range { case "24h": "Last 24 hours"; case "30d": "Last 30 days"; default: "Last 7 days" }
    }
}

/// The period's total in the chosen metric; how it is counted on hover.
struct UsageActivityTotal: View {
    @ObservedObject var usage: UsageDashboardModel
    let chart: UsageChart
    var page = false
    var body: some View {
        let settings = usage.preferences
        GraphLegend(color: FrogStyle.series, title: settings.metric == "API cost" ? "API estimate" : "\(settings.metric) tokens", spacing: 5) {
            Text(usage.loaded ? chart.total : "…").font(GraphStyle.legendValue(page: page)).monospacedDigit()
        }.help(help(settings.provider))
    }
    private func help(_ provider: String) -> String {
        let value = "API value is an estimate, not your subscription bill."
        if provider == "OpenAI", usage.hasAccountActivity {
            return value + " Account totals by UTC day; local activity fills unreported days. Splits are estimated from \(usage.accountEstimateBasis)."
        }
        return value + (provider == "Claude" ? " Reads Claude Code, OpenCode and Pi logs, which can span several accounts."
                        : " Reads Codex, OpenCode and Pi logs on this Mac.")
    }
}

/// The chart, or why there is none yet.
struct UsageActivityChart: View {
    @ObservedObject var usage: UsageDashboardModel
    let chart: UsageChart
    let compact: Bool
    var body: some View {
        let settings = usage.preferences
        if !usage.loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading token activity…").font(FrogType.small).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: compact ? 64 : 150)
        } else if !chart.hasActivity {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: compact ? 16 : 22)).foregroundStyle(FrogStyle.muted)
                Text("No activity in this period").font(compact ? FrogType.small : FrogType.bodyMedium)
            }.frame(maxWidth: .infinity, minHeight: compact ? 64 : 150)
        } else {
            UsageTrendChart(steps: UsageTrend(chart.points.map { ($0.date, $0.value) }).steps, compact: compact,
                            hourly: chart.range == "24h", timeZone: chart.account ? TimeZone(secondsFromGMT: 0)! : .current) {
                usage.format($0, metric: settings.metric)
            }.id("\(settings.provider) \(settings.range)")
        }
    }
}

/// Unpriced models, older logs still being read, and a warning that activity may be incomplete.
struct UsageActivityNotes: View {
    @ObservedObject var usage: UsageDashboardModel
    let chart: UsageChart
    let compact: Bool
    var body: some View {
        if !compact, !chart.unpricedModels.isEmpty {
            FrogRowNote(text: "No price for " + chart.unpricedModels.joined(separator: ", "))
        }
        if usage.loaded, usage.readingOlderActivity {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading older logs…")
            }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).padding(.vertical, compact ? 0 : 6)
                .help("The newest calls are counted first; the rest of the month follows.")
        }
        if let warning = usage.activityWarning {
            Label(compact ? "Activity may be incomplete" : warning, systemImage: "clock.arrow.circlepath")
                .font(FrogType.caption).foregroundStyle(FrogStyle.muted).padding(.vertical, compact ? 0 : 6)
                .help(warning)
        }
    }
}

/// The period's tokens by kind; choosing one makes it the chart's metric.
private struct UsageTokenTotals: View {
    @ObservedObject var usage: UsageDashboardModel
    let chart: UsageChart
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Total tokens").foregroundStyle(FrogStyle.muted)
                Spacer()
                Text(usage.format(chart.totalTokens, metric: "Input")).monospacedDigit()
            }.font(FrogType.body)
                .help("Uncached input, cache reads, cache writes and output.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(chart.totals) { total in
                    let selected = total.name == usage.preferences.metric
                    Button {
                        var next = usage.preferences; next.metric = total.name; usage.updatePreferences(next)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(total.label == "API cost" ? "API estimate" : total.label)
                                .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                            Text(usage.format(total.value, metric: total.name)).font(GraphStyle.figure).monospacedDigit()
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? AnyShapeStyle(FrogStyle.selection) : AnyShapeStyle(FrogStyle.inset),
                                        in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: Lifetime and plan history

private struct UsageHistorySections: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        if let lifetime = usage.lifetime(provider: usage.preferences.provider) {
            FrogSection(lifetime.title) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(lifetime.statistics) { statistic in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statistic.name).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                            Text(statistic.value).font(GraphStyle.figure).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 10)
            }.help([lifetime.detail, lifetime.note].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if usage.preferences.provider == "OpenAI", !usage.planHistory.isEmpty {
            FrogSection("Recent plan usage") {
                if let updated = usage.planHistoryUpdatedAt {
                    Text(updated.formatted(date: .abbreviated, time: .shortened)).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        .help("A daily report over all devices; it can lag the live limits.")
                }
            } content: {
                ForEach(usage.planHistory.prefix(5)) { period in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(period.start.formatted(date: .abbreviated, time: .omitted)) – \(period.end.formatted(date: .abbreviated, time: .omitted))")
                            Spacer()
                            Text(String(format: "%.1f%%", period.percentage)).monospacedDigit()
                        }.font(FrogType.small)
                        ProgressView(value: min(100, max(0, period.percentage)), total: 100).tint(FrogStyle.accent)
                        ForEach(period.models.prefix(4)) { row in
                            HStack {
                                Text(row.name); Spacer()
                                Text(String(format: "%.1f%%", row.value)).monospacedDigit()
                            }.font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }
}

// MARK: Claude accounts

/// Where Claude limits are read: one login, or each account Frog found on this Mac.
private struct UsageClaudeSection: View {
    @ObservedObject var usage: UsageDashboardModel
    @State private var liveSetup: UsageAccountSummary?

    var body: some View {
        let preferences = usage.preferences
        let accounts = usage.claudeAccountsEnabled ? usage.accounts() : []
        FrogSection("Claude") {
            if usage.claudeAccountsEnabled {
                Button("Add folder…") { addFolder() }.buttonStyle(.frog(compact: true))
                    .help("A Claude app data folder or a Claude Code folder Frog did not find")
            }
        } content: {
            // Found once two accounts are, and kept while on, so it can be turned on after Not now.
            if preferences.claudeAccounts || usage.detectedAccountCount >= 2 {
                FrogRow("Each account") {
                    Toggle("Each account", isOn: Binding(get: { usage.preferences.claudeAccounts }, set: { on in
                        var next = usage.preferences; next.claudeAccounts = on; usage.updatePreferences(next)
                    })).labelsHidden().toggleStyle(.switch)
                }.help("Live readings need a Claude Code sign-in per account.")
            }
            if usage.claudeAccountsEnabled {
                if accounts.isEmpty {
                    FrogRowNote(text: usage.searchingClaudeAccounts ? "Looking for Claude accounts…" : "No Claude account found.")
                }
                ForEach(accounts) { account in
                    UsageAccountSettingsRow(usage: usage, account: account) { liveSetup = account }.padding(.vertical, 8)
                }
                // One account is shown as always, so the choices only matter from two on.
                if accounts.count >= 2 {
                    FrogRow("Show limits") {
                        FrogDropdown(selected: preferences.claudeAccountsView, options: UsageDashboardPreferences.claudeAccountsViews,
                                     width: 150, title: { $0 == "combined" ? "Combined" : "Each account" }) { view in
                            var next = usage.preferences; next.claudeAccountsView = view; usage.updatePreferences(next)
                        }
                    }.help(preferences.claudeAccountsView == "combined"
                           ? "One value per limit over the included accounts, weighted by plan size when every plan is known." : "")
                    if preferences.claudeAccountsView == "each", accounts.filter(\.included).count >= 2 {
                        FrogRow("Menu bar shows") {
                            FrogDropdown(selected: preferences.claudeAccountsMenuBar, options: UsageDashboardPreferences.claudeAccountsMenuBarWindows,
                                         width: 150, title: { $0 == "week" ? "Week" : "Session" }) { window in
                                var next = usage.preferences; next.claudeAccountsMenuBar = window; usage.updatePreferences(next)
                            }
                        }
                    }
                }
            } else {
                FrogRow("Login") {
                    FrogDropdown(selected: usage.loginSource, options: usage.loginSources, width: 150, title: { $0 }) {
                        usage.selectLoginSource($0)
                    }.accessibilityLabel("Claude login source")
                }.help("Where Claude plan limits are read from")
                FrogRow("Claude Code folder") {
                    Button(usage.claudeConfigDirectory.lastPathComponent + "…") { chooseClaudeProfile() }
                        .buttonStyle(.frog()).help(usage.claudeConfigDirectory.path)
                }
            }
        }
        .alert(liveSetup.map { ClaudeSignIn.liveSetupTitle($0.label) } ?? "",
               isPresented: Binding(get: { liveSetup != nil }, set: { if !$0 { liveSetup = nil } }), presenting: liveSetup) { account in
            Button("Open Terminal") { ClaudeSignIn.startLiveSetup(usage, account: account.id) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text(ClaudeSignIn.liveSetupMessage(account.label))
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.prompt = "Add"
        panel.message = "Choose a Claude app data folder or a Claude Code folder."
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            usage.addClaudeAccountFolder(folder)
        }
    }

    private func chooseClaudeProfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = usage.claudeConfigDirectory
        panel.message = "Choose the Claude Code folder for the plan login and lifetime stats."
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            usage.selectClaudeConfigDirectory(directory)
        }
    }
}

/// One account on the page. Its login's e-mail address is shown only on hover, so a screenshot
/// of the page shows labels.
private struct UsageAccountSettingsRow: View {
    @ObservedObject var usage: UsageDashboardModel
    let account: UsageAccountSummary
    let setUpLiveReadings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                UsageAccountLabelField(label: account.label) { usage.renameAccount(account.id, to: $0) }
                if let plan = account.plan { UsagePlanBadge(plan: plan) }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(reading(at: context.date)).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        .help(account.age?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }
                Spacer(minLength: 8)
                Toggle("Include", isOn: Binding(get: { account.included }, set: { usage.setAccountIncluded(account.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help("Counts in the menu bar and in combined limits")
            }
            // A line of their own, so a long folder name is not cut short beside the label.
            HStack(spacing: 6) {
                ForEach(account.sources, id: \.self) { source in
                    Text(source).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius))
                        .help(source)
                }
                if let note = account.mergedNote {
                    Image(systemName: "link").font(FrogType.caption).foregroundStyle(FrogStyle.muted).help(note).accessibilityLabel(note)
                }
            }
            if let warning = account.warning {
                Label { Text(warning) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.warning) }
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            if account.needsLiveSetup {
                Button("Set up live readings…", action: setUpLiveReadings).buttonStyle(.frog(compact: true))
                    .help("Signs Claude Code in as \(account.label), so Frog can check its limits with Anthropic")
            } else if account.needsSignIn {
                Button(account.checkingSignIn ? "Checking the login…" : "Sign in to Claude Code…") { ClaudeSignIn.start(usage, account: account.id) }
                    .buttonStyle(.frog(compact: true)).disabled(account.checkingSignIn)
                    .help("Opens Terminal to sign in to Claude Code as \(account.label), in this account’s own Claude Code folder")
            }
        }.help(usage.accountLogin(for: account.id) ?? "")
    }

    /// "3m ago · Claude app", "No reading yet".
    private func reading(at now: Date) -> String {
        guard let age = account.age else { return "No reading yet" }
        return [UsageStatusPopover.age(of: age, at: now), account.readingSource].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Renames on Return or when the field loses focus; the model trims, shortens and keeps labels unique.
private struct UsageAccountLabelField: View {
    let label: String
    let rename: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Label", text: $text)
            .textFieldStyle(.plain).font(FrogType.label)
            .padding(.horizontal, 8).frame(width: 120)
            .frogControlSurface(height: FrogStyle.compactHeight)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, focused in if !focused { commit() } }
            .onChange(of: label) { _, label in text = label }
            .onAppear { text = label }
            .accessibilityLabel("Account label").help("Rename this account; an empty label returns to the default")
    }
    private func commit() {
        guard text != label else { return }
        rename(text)
        // A label the model keeps as it was, such as one made only of spaces, shows as it is.
        text = label
    }
}

// MARK: Menu bar

/// The menu-bar item's switch, a preview with the current readings, and its looks.
private struct UsageMenuBarSection: View {
    @ObservedObject var plugin: LLMUsagePlugin
    @ObservedObject var usage: UsageDashboardModel
    @Environment(\.colorScheme) private var scheme
    /// Shown while there is no plan reading, so that the looks can still be compared.
    static let sample = UsageStatusReadout.Face(provider: "Claude", windows: [
        UsageWindow(id: "five_hour", title: "Session", percentage: 37, resetsAt: nil, duration: 5 * 3600),
        UsageWindow(id: "seven_day", title: "Week", percentage: 81, resetsAt: nil, duration: 7 * 86_400)
    ])

    var body: some View {
        let settings = plugin.settings
        FrogSection("Menu bar") {
            FrogRow("Show in the menu bar") {
                Toggle("Show in the menu bar", isOn: binding(\.menuBarItem)).labelsHidden().toggleStyle(.switch)
            }
            if settings.menuBarItem {
                MenuBarPreviewStrip(image: preview).padding(.vertical, 6)
                FrogRow("Style") {
                    FrogDropdown(selection: binding(\.menuBarStyle), options: MenuBarMeterStyle.allCases, width: 180) { $0.title }
                }
                FrogRow("Colors") {
                    FrogDropdown(selection: binding(\.menuBarPalette), options: MenuBarMeterPalette.allCases, width: 180) { $0.title }
                }
            }
        }
    }

    private var preview: NSImage {
        let dark = scheme == .dark
        var (face, _) = UsageStatusReadout.readout(usage, dark: dark)
        if face.fractions.isEmpty { face = Self.sample }
        face.style = plugin.settings.menuBarStyle
        face.palette = plugin.settings.menuBarPalette
        face.dark = face.palette != .clean && dark
        return UsageStatusReadout.image(face)
    }

    private func binding<Value>(_ key: WritableKeyPath<LLMUsageSettings, Value>) -> Binding<Value> {
        Binding(get: { plugin.settings[keyPath: key] }, set: { value in
            var next = plugin.settings; next[keyPath: key] = value; plugin.update(next)
        })
    }
}

// MARK: Trend chart

/// A period drawn as progress: the running total as the line, each bucket's amount as a bar.
/// The bars have their own scale, so a single day stays visible beside a month's total.
struct UsageTrend {
    struct Step: Identifiable {
        let date: Date
        let amount: Double
        let total: Double
        /// Heights as shares of the plot.
        let line: Double
        let bar: Double
        var id: Date { date }
    }
    static let barShare = 0.36
    let steps: [Step]

    init(_ buckets: [(date: Date, amount: Double)]) {
        let amounts = buckets.map { $0.amount.isFinite ? max(0, $0.amount) : 0 }
        let sum = amounts.reduce(0, +), peak = amounts.max() ?? 0
        var total = 0.0
        steps = zip(buckets, amounts).map { bucket, amount in
            total += amount
            return Step(date: bucket.date, amount: amount, total: total,
                        line: sum > 0 ? total / sum : 0, bar: peak > 0 ? amount / peak * Self.barShare : 0)
        }
    }
}

/// The running total as a line over each bucket's amount as a thin bar.
struct UsageTrendChart: View {
    let steps: [UsageTrend.Step]
    let compact: Bool
    let hourly: Bool
    /// Account buckets are UTC days; local ones follow this Mac's time zone.
    let timeZone: TimeZone
    let format: (Double) -> String
    @State private var selectedDate: Date?

    var body: some View {
        let selected = selectedDate.flatMap { date in
            steps.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        VStack(spacing: 4) {
            Chart {
                ForEach(steps) { step in
                    AreaMark(x: .value("Date", step.date), y: .value("Total", step.line))
                        .interpolationMethod(.monotone).foregroundStyle(GraphStyle.fill(FrogStyle.series))
                        .accessibilityHidden(true)
                }
                ForEach(steps) { step in
                    BarMark(x: .value("Date", step.date), y: .value("Amount", step.bar), width: .fixed(compact ? 2 : 3))
                        .foregroundStyle(FrogStyle.series)
                        .opacity(selected == nil || selected?.id == step.id ? 1 : 0.4)
                        .accessibilityLabel(label(step.date, long: true))
                        .accessibilityValue(format(step.amount))
                }
                ForEach(steps) { step in
                    LineMark(x: .value("Date", step.date), y: .value("Total", step.line))
                        .interpolationMethod(.monotone).lineStyle(GraphStyle.line).foregroundStyle(FrogStyle.series)
                        .accessibilityLabel("Total by \(label(step.date, long: true))")
                        .accessibilityValue(format(step.total))
                }
                if let selected {
                    RuleMark(x: .value("Date", selected.date)).lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(FrogStyle.muted.opacity(0.45)).accessibilityHidden(true)
                    PointMark(x: .value("Date", selected.date), y: .value("Total", selected.line))
                        .symbolSize(compact ? 22 : 30).foregroundStyle(FrogStyle.series).accessibilityHidden(true)
                }
            }
            .chartXScale(domain: domain(steps), range: .plotDimension(startPadding: 3, endPadding: 3))
            .chartYScale(domain: 0...1, range: .plotDimension(startPadding: 0, endPadding: 2))
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .chartXSelection(value: $selectedDate)
            .frame(height: compact ? 64 : 150)
            .overlay(alignment: .topLeading) {
                if let selected {
                    Text("\(label(selected.date, long: true)) · \(format(selected.amount)) · \(format(selected.total)) total")
                        .font(FrogType.caption).monospacedDigit().lineLimit(1)
                        .padding(6).background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius))
                        .allowsHitTesting(false)
                }
            }
            .help("The line is the running total for the period. The bars are each \(hourly ? "hour" : "day")’s amount.")
            if let first = steps.first, let last = steps.last {
                GraphAxis(leading: label(first.date, long: false), trailing: label(last.date, long: false))
            }
        }
    }

    private func domain(_ steps: [UsageTrend.Step]) -> ClosedRange<Date> {
        let first = steps.first?.date ?? .now, last = steps.last?.date ?? first
        return last > first ? first...last : first.addingTimeInterval(-3600)...first.addingTimeInterval(3600)
    }

    private func label(_ date: Date, long: Bool) -> String {
        var style = hourly ? (long ? Date.FormatStyle(date: .abbreviated, time: .shortened) : .dateTime.hour())
            : .dateTime.month(.abbreviated).day()
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
