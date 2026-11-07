import FrogCore
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
            FrogPageHeader(title: "LLM usage", subtitle: "Plan limits and token use of your coding tools") {
                Button("Refresh", systemImage: "arrow.clockwise") { usage.refresh() }
                    .help("Read the plan limits and logs again")
            }
            // Which service the page shows, as tabs leading the first row under the toolbar: both names in sight,
            // so the choice explains itself.
            CompactSegments(values: usage.providers, selected: provider, title: { $0 }) { usage.selectProvider($0) }
                .accessibilityLabel("Provider")
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
                Button(usage.accountsNoticeAction) { usage.showAllAccounts() }.buttonStyle(.frog(.primary))
                Button("Not now") { usage.dismissAccountsNotice() }.buttonStyle(.frog())
            }
        }.padding(compact ? 8 : 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.card, in: RoundedRectangle(cornerRadius: compact ? FrogStyle.controlRadius : FrogStyle.cardRadius))
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
            let windows = usage.windows(provider: provider, now: FrogClock.now(or: context.date))
            let status = usage.status(provider: provider)
            FrogSection("Limits") {
                HStack(spacing: 6) {
                    if let source = usage.planSource(provider: provider), let updated = usage.planUpdatedAt(provider: provider) {
                        Text("\(source) · \(UsageStatusPopover.age(of: updated, at: FrogClock.now(or: context.date)))")
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FrogStyle.space16 * 2, alignment: .leading), count: windows.count == 1 ? 1 : 2),
                              alignment: .leading, spacing: 18) {
                        ForEach(windows) { UsageLimitView(window: $0, now: FrogClock.now(or: context.date)) }
                    }.padding(.vertical, 10)
                }
                if !normal, !windows.isEmpty, status != UsageDashboardModel.notReading {
                    FrogRowNote(text: status).textSelection(.enabled)
                }
                if provider == "Claude", usage.needsClaudeSignIn {
                    FrogRow("Claude Code login") {
                        Button(usage.checkingClaudeSignIn ? "Checking…" : "Sign in…") { ClaudeSignIn.start(usage) }
                            .buttonStyle(.frog()).disabled(usage.checkingClaudeSignIn)
                    }
                }
                if let extra = usage.extraUsage(provider: provider) {
                    FrogRow("Extra usage") {
                        Text(extra.used + (extra.limit.map { " of \($0)" } ?? "")).font(FrogType.small).monospacedDigit()
                            .foregroundStyle(extra.fraction.map { $0 >= 0.8 ? FrogStyle.level($0, warning: 0.8, critical: 0.95) : FrogStyle.muted } ?? FrogStyle.muted)
                    }
                } else if let credits = usage.credits(provider: provider) {
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
            let accounts = usage.accounts(now: FrogClock.now(or: context.date)).filter(\.included)
            VStack(alignment: .leading, spacing: compact ? 10 : 18) {
                if accounts.isEmpty {
                    Text("No account is included.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                } else if usage.preferences.claudeAccountsView == "combined" {
                    combined(accounts, now: FrogClock.now(or: context.date))
                } else if compact {
                    SectionCaption(text: "Plan limits")
                    ForEach(accounts.prefix(4)) { UsageAccountRow(account: $0, now: FrogClock.now(or: context.date)) }
                } else {
                    ForEach(accounts) { UsageAccountLimits(account: $0, now: FrogClock.now(or: context.date)) }
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FrogStyle.space16 * 2, alignment: .leading), count: compact || windows.count == 1 ? 1 : 2),
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FrogStyle.space16 * 2, alignment: .leading), count: account.windows.count == 1 ? 1 : 2),
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
    /// The meters' one family (`FrogStyle.level`): the accent while all is well, on pace or under it, orange ahead
    /// of pace, red nearly used whatever the pace. A window without a pace stays the accent until it runs low.
    private var meterColor: Color {
        if fraction >= 0.95 { return FrogStyle.critical }
        switch window.pace(at: now) {
        case "Ahead of pace": return FrogStyle.warning
        case nil: return FrogStyle.level(fraction, warning: 0.8, critical: 0.95)
        default: return FrogStyle.accent
        }
    }
    /// Only a pace that needs attention is coloured, in its bar's colour; on or under pace is plain muted text.
    private func paceColor(_ pace: String) -> Color {
        switch pace {
        case "Ahead of pace": FrogStyle.warning
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
            FrogMeter(fraction: fraction, tint: meterColor, size: compact ? .compact : .regular, tick: elapsed)
                .help("The tick marks the time gone in this window.")
            // No spacing: the pace brings its own " · ", so the dot sits evenly between the two.
            HStack(spacing: 0) {
                Text(window.leftText ?? "No reading since it renewed")
                // Every bar names its pace, in the bar's colour, so the colours explain themselves.
                if let pace = window.pace(at: now) {
                    Text(" · \(pace)").foregroundStyle(paceColor(pace))
                        .help(elapsed.map { "\(Int(fraction * 100))% used with \(Int($0 * 100))% of the window gone" } ?? "")
                }
                Spacer(minLength: 4)
                if let reset = window.resetsAt {
                    Text("Resets in \(Duration.seconds(max(0, reset.timeIntervalSince(now))).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1)))")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                }
            }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }.accessibilityElement(children: .combine)
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
            VStack(alignment: .leading, spacing: 12) {
                // The figure leads; the period is a segmented choice level with it, each value named. The metric is
                // chosen from the totals under the chart, so the card has no unlabelled dropdowns.
                HStack(alignment: .top) {
                    UsageActivityTotal(usage: usage, chart: chart, page: true)
                    Spacer(minLength: FrogStyle.space12)
                    CompactSegments(values: usage.ranges, selected: settings.range, title: { Self.rangeTitle($0) }) { range in
                        var next = usage.preferences; next.range = range; usage.updatePreferences(next)
                    }.accessibilityLabel("Activity period")
                }
                UsageActivityChart(usage: usage, chart: chart, compact: false)
            }.padding(.vertical, 10)
            if usage.loaded, chart.hasActivity { UsageTokenTotals(usage: usage, chart: chart).padding(.bottom, 10) }
            UsageActivityNotes(usage: usage, chart: chart, compact: false)
            if settings.provider == "OpenAI", !usage.hasAccountActivity {
                FrogRowNote(text: "Showing this Mac’s logs. Account activity is unavailable.")
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

extension UsageActivitySection {
    /// "24 hours", "7 days", "30 days": short enough for segments, plain enough to need no key.
    static func rangeTitle(_ range: String) -> String {
        switch range { case "24h": "24 hours"; case "30d": "30 days"; default: "7 days" }
    }
}

struct UsageMetricDropdown: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        FrogDropdown(selected: usage.preferences.metric, options: usage.metrics, width: 104, compact: true,
                     title: { $0 == "Input" ? "Uncached input" : $0 }) { metric in
            var next = usage.preferences; next.metric = metric; usage.updatePreferences(next)
        }.buttonTitle { $0 }.accessibilityLabel("Activity metric")
    }
}

struct UsageRangeDropdown: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        FrogDropdown(selected: usage.preferences.range, options: usage.ranges, width: compact ? 60 : 150, compact: true,
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
            FrogLoadingNote(text: "Reading token activity…").frame(maxWidth: .infinity, minHeight: compact ? 64 : 150)
        } else if !chart.hasActivity {
            FrogChartPlaceholder(height: compact ? 64 : 150) {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: compact ? 16 : 22))
                    Text("No activity in this period").font(compact ? FrogType.small : FrogType.bodyMedium).foregroundStyle(FrogStyle.ink)
                }.padding(.bottom, compact ? 4 : 10)
            }
        } else {
            UsageTrendChart(steps: UsageTrend(chart.points.map { ($0.date, $0.value) }).steps, compact: compact,
                            hourly: chart.range == "24h", timeZone: chart.account ? TimeZone(secondsFromGMT: 0)! : .current) {
                usage.format($0, metric: settings.metric)
            } axisFormat: {
                usage.axisLabel($0, metric: settings.metric)
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
                FrogSpinner()
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
            // Every total is the same stat: its name over its figure. Total tokens leads; the chart's own metric is the
            // figure above the chart, and choosing any other makes it the chart's. A plain grid on the card, the names
            // on the card's text edge; the hover fill reaches past it.
            // One row, a column each, so the totals never leave a hole the way a grid of three does with five.
            HStack(spacing: FrogStyle.space4) {
                UsageTokenTotal(title: "Total tokens", value: usage.format(chart.totalTokens, metric: "Input"), choosable: false)
                    .help("Uncached input, cache reads, cache writes and output.")
                // Every metric is here, the chart's own one marked as chosen, so this row is the chart's metric choice.
                ForEach(chart.totals) { total in
                    let chosen = total.name == usage.preferences.metric
                    Button {
                        var next = usage.preferences; next.metric = total.name; usage.updatePreferences(next)
                    } label: {
                        UsageTokenTotal(title: total.label == "API cost" ? "API estimate" : total.label,
                                        value: usage.format(total.value, metric: total.name), chosen: chosen)
                    }.buttonStyle(.plain)
                        .help(chosen ? "" : "Show \(total.label == "API cost" ? "the API estimate" : total.label.lowercased()) in the chart")
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }.padding(.horizontal, -FrogStyle.rowPadding)
        }
    }
}

/// One total in the grid under the chart: its name and figure on the card itself, a hover fill only under the pointer,
/// since choosing it makes it the chart's metric.
private struct UsageTokenTotal: View {
    let title: String
    let value: String
    var choosable = true
    /// The chart's metric: filled like a chosen row, its name in the series colour beside the legend dot.
    var chosen = false
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space2) {
            HStack(spacing: 5) {
                if chosen { Circle().fill(FrogStyle.series).frame(width: 6, height: 6) }
                Text(L10n.text(title)).font(FrogType.small).foregroundStyle(chosen ? FrogStyle.ink : FrogStyle.muted).lineLimit(1)
            }
            Text(value).font(GraphStyle.figure).monospacedDigit().lineLimit(1)
        }.padding(.horizontal, FrogStyle.rowPadding).padding(.vertical, FrogStyle.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .frogRowHighlight(hovering: hovering && choosable && !chosen, selected: chosen)
            .onHover { hovering = $0 }
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
                FrogAddButton("Add folder") { addFolder() }
                    .help("A Claude app data folder or a Claude Code folder Frog did not find")
            }
        } content: {
            // Found once two accounts are, and kept while on, so it can be turned on after Not now.
            if preferences.claudeAccounts || usage.detectedAccountCount >= 2 {
                FrogRow("Each account") {
                    Toggle("Each account", isOn: Binding(get: { usage.preferences.claudeAccounts }, set: { on in
                        var next = usage.preferences; next.claudeAccounts = on; usage.updatePreferences(next)
                    })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
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
                    Text(reading(at: FrogClock.now(or: context.date))).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        .help(account.age?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }
                Spacer(minLength: 8)
                Toggle("Include", isOn: Binding(get: { account.included }, set: { usage.setAccountIncluded(account.id, $0) }))
                    .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                    .help("Counts in the menu bar and in combined limits")
            }
            // A line of their own, so a long folder name is not cut short beside the label.
            HStack(spacing: 6) {
                ForEach(account.sources, id: \.self) { source in
                    Text(source).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius))
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
                Button("Set up live readings…", action: setUpLiveReadings).buttonStyle(.frog())
                    .help("Signs Claude Code in as \(account.label), so Frog can check its limits with Anthropic")
            } else if account.needsSignIn {
                Button(account.checkingSignIn ? "Checking the login…" : "Sign in to Claude Code…") { ClaudeSignIn.start(usage, account: account.id) }
                    .buttonStyle(.frog()).disabled(account.checkingSignIn)
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
        FrogTextField(placeholder: "Label", text: $text)
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
struct UsageMenuBarSection: View {
    @ObservedObject var plugin: LLMUsagePlugin
    @ObservedObject var usage: UsageDashboardModel
    /// Shown while there is no plan reading, so that the looks can still be compared.
    static let sample = UsageStatusReadout.Face(provider: "Claude", windows: [
        UsageWindow(id: "five_hour", title: "Session", percentage: 37, resetsAt: nil, duration: 5 * 3600),
        UsageWindow(id: "seven_day", title: "Week", percentage: 81, resetsAt: nil, duration: 7 * 86_400)
    ])

    var body: some View {
        let settings = plugin.settings
        FrogSection("Menu bar") {
            FrogRow("Show in the menu bar") {
                Toggle("Show in the menu bar", isOn: binding(\.menuBarItem)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            if settings.menuBarItem {
                MenuBarStyleGallery(sample: "usage", style: settings.menuBarStyle, palette: settings.menuBarPalette,
                                    render: { Self.preview($0, $1, dark: $2) },
                                    chooseStyle: { binding(\.menuBarStyle).wrappedValue = $0 },
                                    choosePalette: { binding(\.menuBarPalette).wrappedValue = $0 })
            }
        }
    }

    private static func preview(_ style: MenuBarMeterStyle, _ palette: MenuBarMeterPalette, dark: Bool) -> NSImage {
        var face = sample
        face.style = style
        face.palette = palette
        face.dark = palette != .clean && dark
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

/// A period's activity. On the page each bucket is a bar on a labelled scale, so days read as a series against one
/// baseline; the running total, which the figure above already states, is in the chip under the pointer. A popup's
/// small chart keeps to the running total's line.
struct UsageTrendChart: View {
    let steps: [UsageTrend.Step]
    let compact: Bool
    let hourly: Bool
    /// Account buckets are UTC days; local ones follow this Mac's time zone.
    let timeZone: TimeZone
    let format: (Double) -> String
    /// The scale's labels, which drop a whole figure's cents ("$100"); `format` when nil.
    var axisFormat: ((Double) -> String)? = nil
    @State private var selectedDate: Date?

    var body: some View {
        if compact { line } else {
            UsageBucketChart(steps: steps, hourly: hourly, timeZone: timeZone, format: format, axisFormat: axisFormat ?? format)
        }
    }

    private var line: some View {
        let selected = selectedDate.flatMap { date in
            steps.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return VStack(spacing: 4) {
            Chart {
                FrogChartGrid(values: [0.5])
                ForEach(steps) { step in
                    AreaMark(x: .value("Date", step.date), y: .value("Total", step.line))
                        .interpolationMethod(.monotone).foregroundStyle(FrogChart.areaFill(FrogStyle.series))
                        .accessibilityHidden(true)
                }
                ForEach(steps) { step in
                    LineMark(x: .value("Date", step.date), y: .value("Total", step.line))
                        .interpolationMethod(.monotone).lineStyle(FrogChart.line).foregroundStyle(FrogStyle.series)
                        .accessibilityLabel("Total by \(UsageBucketChart.label(step.date, hourly: hourly, long: true, timeZone: timeZone))")
                        .accessibilityValue(format(step.total))
                }
                if let last = steps.last {
                    FrogChartPoint(x: .value("Date", last.date), y: .value("Total", last.line), color: FrogStyle.series)
                }
                if let selected {
                    FrogChartRule(x: .value("Date", selected.date))
                    FrogChartPoint(x: .value("Date", selected.date), y: .value("Total", selected.line), color: FrogStyle.series)
                }
            }
            .chartXScale(domain: domain(steps), range: .plotDimension(startPadding: FrogChart.endInset, endPadding: FrogChart.endInset))
            .chartYScale(domain: 0...1, range: .plotDimension(startPadding: 6, endPadding: FrogChart.endInset))
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .chartXSelection(value: $selectedDate)
            .frogChartPlot(compact: true)
            .frame(height: 64)
            .overlay(alignment: FrogChart.chipAlignment(pointerAt: pointer(selected))) {
                if let selected {
                    FrogChartChip {
                        Text("\(UsageBucketChart.label(selected.date, hourly: hourly, long: true, timeZone: timeZone)) · \(format(selected.amount)) · \(format(selected.total)) total")
                    }
                }
            }
            .help("The line is the running total for the period.")
            if let first = steps.first, let last = steps.last {
                GraphAxis(leading: UsageBucketChart.label(first.date, hourly: hourly, long: false, timeZone: timeZone),
                          trailing: UsageBucketChart.label(last.date, hourly: hourly, long: false, timeZone: timeZone))
            }
        }
    }

    /// Where the selected bucket lies across the chart, 0 at its left edge and 1 at its right.
    private func pointer(_ selected: UsageTrend.Step?) -> Double {
        guard let selected, let first = steps.first?.date, let last = steps.last?.date, last > first else { return 0 }
        return selected.date.timeIntervalSince(first) / last.timeIntervalSince(first)
    }

    private func domain(_ steps: [UsageTrend.Step]) -> ClosedRange<Date> {
        let first = steps.first?.date ?? .now, last = steps.last?.date ?? first
        return last > first ? first...last : first.addingTimeInterval(-3600)...first.addingTimeInterval(3600)
    }
}

/// The page's activity chart: one rounded bar per day (or hour) in the accent, on a scale whose top is a round
/// figure, labelled in a column left of the plot at 0, half and the top, as Stocks and Screen Time label theirs. A
/// day with a little activity keeps a short visible stub, so no bar shrinks to a stray dot; a day with none has no bar.
struct UsageBucketChart: View {
    let steps: [UsageTrend.Step]
    let hourly: Bool
    let timeZone: TimeZone
    let format: (Double) -> String
    let axisFormat: (Double) -> String
    @State private var selectedKey: String?

    static let plotHeight: CGFloat = 150
    /// The share of the scale a bucket with any activity is drawn at least, so it shows as a bar.
    static let minimumShare = 0.025

    var body: some View {
        let top = Self.niceCeiling(steps.map(\.amount).max() ?? 0, floor: Self.smallestTop(axisFormat))
        let zeroLabel = axisFormat(0), topLabel = axisFormat(top)
        let selected = selectedKey.flatMap(Int.init).flatMap { steps.indices.contains($0) ? steps[$0] : nil }
        let stride = max(1, Int((Double(steps.count) / 7).rounded(.up)))
        Chart {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if step.amount > 0 {
                    BarMark(x: .value("Bucket", String(index)), y: .value("Amount", max(step.amount, top * Self.minimumShare)),
                            width: .ratio(steps.count > 14 ? 0.7 : 0.56))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: FrogStyle.smallRadius, topTrailingRadius: FrogStyle.smallRadius, style: .continuous))
                        .foregroundStyle(FrogStyle.series.opacity(selected == nil || selected?.id == step.id ? 0.9 : 0.35))
                        .accessibilityLabel(Self.label(step.date, hourly: hourly, long: true, timeZone: timeZone))
                        .accessibilityValue(format(step.amount))
                } else {
                    // An empty bucket keeps its place on the axis without a mark.
                    BarMark(x: .value("Bucket", String(index)), y: .value("Amount", 0)).foregroundStyle(.clear)
                        .accessibilityLabel(Self.label(step.date, hourly: hourly, long: true, timeZone: timeZone))
                        .accessibilityValue(format(0))
                }
            }
        }
        .chartYScale(domain: 0...max(top, .leastNonzeroMagnitude))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                AxisGridLine(stroke: FrogChart.gridLine).foregroundStyle(FrogStyle.hairline)
                AxisValueLabel {
                    // A middle that rounds to the same words as 0 or the top is left out rather than said twice.
                    if let amount = value.as(Double.self),
                       amount == 0 || amount == top || ![zeroLabel, topLabel].contains(axisFormat(amount)) {
                        Text(amount == 0 ? "0" : axisFormat(amount)).font(FrogType.small).monospacedDigit().foregroundStyle(FrogStyle.muted)
                    }
                }
            }
        }
        .chartXAxis {
            // A label under every bar for a week, and every few for a month or a day, counted back from the newest.
            AxisMarks(values: steps.indices.filter { (steps.count - 1 - $0) % stride == 0 }.map(String.init)) { value in
                AxisValueLabel(centered: true, collisionResolution: .disabled) {
                    if let key = value.as(String.self), let index = Int(key), steps.indices.contains(index) {
                        Text(Self.label(steps[index].date, hourly: hourly, long: false, timeZone: timeZone))
                            .font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize()
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedKey)
        .frame(height: Self.plotHeight + 20)
        .overlay(alignment: FrogChart.chipAlignment(pointerAt: selected.flatMap { step in
            steps.firstIndex { $0.id == step.id }.map { Double($0) / Double(max(1, steps.count - 1)) }
        } ?? 0)) {
            if let selected {
                FrogChartChip {
                    Text("\(Self.label(selected.date, hourly: hourly, long: true, timeZone: timeZone)) · \(format(selected.amount)) · \(format(selected.total)) so far")
                }.padding(.leading, 48)
            }
        }
        .help(L10n.text(hourly ? "Each bar is one hour’s amount." : "Each bar is one day’s amount."))
    }

    /// The smallest round figure (1, 2, 2.5 or 5 times a power of ten) at or above the busiest bucket, so the scale's
    /// top and middle read as plain numbers.
    static func niceCeiling(_ value: Double, floor minimum: Double = 0) -> Double {
        guard value.isFinite, value > 0 else { return max(1, minimum) }
        guard value > minimum else { return minimum }
        let power = pow(10, floor(log10(value)))
        return ([1, 2, 2.5, 5, 10].map { $0 * power }.first { $0 >= value * 0.9999 }) ?? 10 * power
    }

    /// The smallest top whose half the labels can still write: two cents for an amount in cents ($0.02 over $0.01),
    /// none for a count.
    static func smallestTop(_ format: (Double) -> String) -> Double {
        format(0.01) == format(0) ? 0 : 0.02
    }

    static func label(_ date: Date, hourly: Bool, long: Bool, timeZone: TimeZone) -> String {
        var style = hourly ? (long ? Date.FormatStyle(date: .abbreviated, time: .shortened) : .dateTime.hour())
            : .dateTime.month(.abbreviated).day()
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
