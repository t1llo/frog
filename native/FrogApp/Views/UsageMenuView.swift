import SwiftUI
import FrogUsage

/// LLM usage's tab in Frog's menu-bar popup, laid out as the LLM usage popup: the provider, refresh and the way to the
/// page on the trailing side, then the limits card and the activity card. Frog's own footer closes the popup, so when
/// the limits were read leads the header row, where the popup's footer would show it.
struct UsageMenuTab: View {
    @ObservedObject var usage: UsageDashboardModel
    let openPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.listInset) {
            HStack(spacing: FrogStyle.space6) {
                UsageMenuStatus(usage: usage)
                Spacer(minLength: FrogStyle.space6)
                UsageProviderDropdown(usage: usage)
                UsageRefreshAction(usage: usage)
                IconAction(title: "Open LLM usage", symbol: "arrow.up.forward.app", action: openPage)
            }.padding(.leading, FrogStyle.cardPadding).padding(.trailing, FrogStyle.space6).padding(.bottom, FrogStyle.space4)
            UsageMenuCards(usage: usage)
        }
        .background(FeatureVisibility { usage.setPresented($0, for: .menu) })
    }
}

/// The two cards the tab and the popup share: the plan limits, then the period's activity.
private struct UsageMenuCards: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        UsageMenuLimitsBlock(usage: usage).padding(FrogStyle.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
            .frogTableSurface()
        UsageCompactActivity(usage: usage).padding(FrogStyle.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
            .frogTableSurface()
    }
}

/// Reads the limits and the activity again: one action, beside the provider, on the tab, the popup and the page.
struct UsageRefreshAction: View {
    @ObservedObject var usage: UsageDashboardModel
    var bordered = false
    var body: some View {
        IconAction(title: "Refresh", symbol: "arrow.clockwise", bordered: bordered) { usage.refresh() }
    }
}

/// The menu-bar item's popup, laid out like Frog's own: a 40-point header, content, the command rows
/// and a quiet footer, as tall as its content.
struct UsageStatusPopover: View {
    static let popupName = "LLM usage"
    static let width: CGFloat = 292
    @ObservedObject var usage: UsageDashboardModel
    let openDashboard: () -> Void
    var signIn: () -> Void = {}
    var installUpdate: () -> Void = {}
    /// "Set up live readings for B…": the caller explains it before Terminal opens.
    var liveSetup: (UsageAccountSummary) -> Void = { _ in }
    /// "Sign in to Claude Code for B…", for an account whose own Claude Code login is gone.
    var accountSignIn: (UsageAccountSummary) -> Void = { _ in }

    @ObservedObject private var readiness = UpdateReadiness.shared

    var body: some View {
        let provider = usage.preferences.provider
        let accounts = Self.shownAccounts(usage)
        let setup = accounts.first(where: \.needsLiveSetup)
        let signInAccount = setup == nil ? accounts.first(where: \.needsSignIn) : nil
        let claudeSignIn = setup == nil && signInAccount == nil && provider == "Claude" && accounts.isEmpty && usage.needsClaudeSignIn
        VStack(alignment: .leading, spacing: 0) {
            FrogPopupHeader(symbol: LLMUsagePlugin.info.symbol, tint: LLMUsagePlugin.info.tint, title: "LLM usage") {
                UsageProviderDropdown(usage: usage)
                UsageRefreshAction(usage: usage, bordered: true)
                IconAction(title: "Open LLM usage", symbol: "arrow.up.forward.app", bordered: true, action: openDashboard)
            }
            VStack(alignment: .leading, spacing: FrogStyle.listInset) {
                UsageMenuCards(usage: usage)
                // Only what needs doing: at most one account is offered live readings or a sign-in, the first that needs one.
                if setup != nil || signInAccount != nil || claudeSignIn || readiness.version != nil {
                    VStack(alignment: .leading, spacing: FrogStyle.space2) {
                        if let account = setup {
                            MenuActionRow(title: "Set up live readings for \(account.label)…", symbol: "person.crop.circle.badge.plus", tint: FrogStyle.warning) {
                                liveSetup(account)
                            }.help(account.status ?? "")
                        } else if let account = signInAccount {
                            MenuActionRow(title: ClaudeSignIn.accountSignInTitle(account), symbol: "person.crop.circle.badge.checkmark", tint: FrogStyle.warning) {
                                accountSignIn(account)
                            }.disabled(account.checkingSignIn).help(account.warning ?? account.status ?? "")
                        } else if claudeSignIn {
                            MenuActionRow(title: usage.checkingClaudeSignIn ? "Checking Claude Code’s login…" : "Sign in to Claude Code…",
                                          symbol: "person.crop.circle.badge.checkmark", tint: FrogStyle.warning, action: signIn)
                                .disabled(usage.checkingClaudeSignIn).help(usage.status(provider: provider))
                        }
                        UpdateReadyRow(install: installUpdate)
                    }.padding(FrogStyle.listInset).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
                }
            }.padding(.bottom, FrogStyle.space8)
            FrogPopupFooter { UsageMenuStatus(usage: usage) }
        }
        .padding(FrogStyle.panelCardInset)
        .frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
        .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
        .frogPanel()
        .environment(\.locale, L10n.locale)
        // The last reading is on screen at once; the model decides whether it needs a refresh.
        .onAppear { usage.setPresented(true, for: .popup) }
        .onDisappear { usage.setPresented(false, for: .popup) }
    }

    /// "just now", "12m ago", "10h ago", "3d ago".
    static func age(of date: Date, at now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return minutes < 1440 ? "\(minutes / 60)h ago" : "\(minutes / 1440)d ago"
    }
    /// The Claude accounts shown one by one or combined: only while Frog reads each of them and
    /// finds at least two; otherwise every surface shows the one account as always.
    @MainActor static func shownAccounts(_ usage: UsageDashboardModel, now: Date = Date()) -> [UsageAccountSummary] {
        guard usage.preferences.provider == "Claude", usage.claudeAccountsEnabled else { return [] }
        let accounts = usage.accounts(now: now)
        return accounts.count >= 2 ? accounts : []
    }
    /// "15:40" today, else the weekday: "Thu".
    static func shortReset(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated))
    }
}

struct UsageProviderDropdown: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        FrogDropdown(selected: usage.preferences.provider, options: usage.providers, width: 92, compact: true, title: { $0 }) {
            usage.selectProvider($0)
        }.accessibilityLabel("Provider")
    }
}

/// The popup's limits card: the accounts notice, the plan windows and, when enabled, extra usage.
private struct UsageMenuLimitsBlock: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        let provider = usage.preferences.provider
        let accounts = UsageStatusPopover.shownAccounts(usage)
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            if provider == "Claude", usage.accountsNoticeVisible { UsageAccountsNotice(usage: usage, compact: true) }
            if accounts.isEmpty { UsageCompactLimits(usage: usage) } else { UsageAccountsLimits(usage: usage, compact: true) }
            UsageExtraUsageBlock(usage: usage)
        }
    }
}

/// "Extra usage": what was spent this month beyond the plan, against the monthly limit when there is one.
/// Nothing while it is off. The same text is on the page's row.
struct UsageExtraUsageBlock: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        if let extra = usage.extraUsage(provider: usage.preferences.provider) {
            let tint = extra.fraction.map { $0 >= 0.8 ? FrogStyle.level($0, warning: 0.8, critical: 0.95) : FrogStyle.seriesSecondary } ?? FrogStyle.seriesSecondary
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Extra usage").font(FrogType.bodyMedium)
                    Spacer()
                    Text(extra.used).font(GraphStyle.figure).monospacedDigit()
                }
                if let fraction = extra.fraction {
                    FrogMeter(fraction: fraction, tint: tint, size: .compact)
                }
                HStack(spacing: 4) {
                    Text("This month")
                    Spacer(minLength: 4)
                    if let limit = extra.limit { Text("of \(limit) limit").monospacedDigit() }
                }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }.accessibilityElement(children: .combine)
        }
    }
}

/// The plan windows, at most four, one per line.
private struct UsageCompactLimits: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let provider = usage.preferences.provider
            let windows = usage.windows(provider: provider, now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionCaption(text: "Plan limits")
                    Spacer()
                    if let plan = usage.planName(provider: provider) { UsagePlanBadge(plan: plan) }
                }
                if windows.isEmpty {
                    Text("No current reading").font(FrogType.bodyMedium).help(usage.status(provider: provider))
                } else {
                    ForEach(Array(windows.prefix(4))) { UsageLimitView(window: $0, now: context.date, compact: true) }
                }
            }
        }
    }
}

/// The period's total, its range and the chart.
private struct UsageCompactActivity: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        let settings = usage.preferences
        let chart = usage.chart(provider: settings.provider, range: settings.range, metric: settings.metric)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                UsageActivityTotal(usage: usage, chart: chart)
                Spacer()
                UsageRangeDropdown(usage: usage, compact: true)
            }
            UsageActivityChart(usage: usage, chart: chart, compact: true)
            if usage.loaded, chart.hasActivity {
                HStack {
                    Text("Total tokens").foregroundStyle(FrogStyle.muted)
                    Spacer()
                    Text(usage.format(chart.totalTokens, metric: "Input")).monospacedDigit()
                }.font(FrogType.small)
            }
            UsageActivityNotes(usage: usage, chart: chart, compact: true)
        }
    }
}

/// When the limits were read, the source on hover; one entry per account while each is shown.
private struct UsageMenuStatus: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        let provider = usage.preferences.provider
        let accounts = UsageStatusPopover.shownAccounts(usage)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if !accounts.isEmpty {
                UsageAccountsFooter(accounts: accounts.filter(\.included), now: context.date)
            } else {
                HStack(spacing: 4) {
                    Text(usage.planUpdatedAt(provider: provider).map { "Updated \(UsageStatusPopover.age(of: $0, at: context.date))" } ?? "No plan reading yet")
                        .help([usage.planSource(provider: provider), usage.status(provider: provider)].compactMap { $0 }.joined(separator: "\n"))
                    if let warning = usage.planWarning(provider: provider) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.warning)
                            .help(warning).accessibilityLabel(warning)
                    }
                }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }
        }
    }
}

/// One account in the popup: its label, plan, age and two small meters, Session and Week.
struct UsageAccountRow: View {
    let account: UsageAccountSummary
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(account.label).font(FrogType.bodyMedium).lineLimit(1)
                if let plan = account.plan { UsagePlanBadge(plan: plan) }
                Spacer(minLength: 4)
                Text(account.age.map { UsageStatusPopover.age(of: $0, at: now) } ?? "No reading yet")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                if account.stale {
                    Image(systemName: "exclamationmark.circle").font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                        .accessibilityLabel("No current reading")
                }
            }
            HStack(spacing: 12) {
                UsageMiniMeter(title: "Session", window: account.windows.first { $0.id == "five_hour" }, now: now)
                UsageMiniMeter(title: "Week", window: account.windows.first { $0.id == "seven_day" }, now: now)
            }.opacity(account.stale ? 0.55 : 1)
        }.contentShape(Rectangle()).help(account.status ?? "").accessibilityElement(children: .combine)
    }
}

private struct UsageMiniMeter: View {
    let title: String
    let window: UsageWindow?
    let now: Date
    var body: some View {
        let fraction = window.map { $0.percentage.isFinite ? min(1, max(0, $0.percentage / 100)) : 0 } ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(FrogStyle.muted)
                Spacer(minLength: 2)
                Text(window?.usedText ?? "—").font(FrogType.label).monospacedDigit()
                if let reset = window?.resetsAt {
                    Text(UsageStatusPopover.shortReset(reset, now: now)).foregroundStyle(FrogStyle.muted)
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                }
            }.font(FrogType.caption).lineLimit(1)
            FrogMeter(fraction: fraction, tint: fraction >= 0.8 ? FrogStyle.level(fraction, warning: 0.8, critical: 0.95) : FrogStyle.seriesSecondary, size: .compact)
        }.frame(maxWidth: .infinity)
    }
}

/// "A 3m ago · B 2h ago", the sources on hover.
private struct UsageAccountsFooter: View {
    let accounts: [UsageAccountSummary]
    let now: Date
    var body: some View {
        let stale = accounts.filter(\.stale)
        HStack(spacing: 4) {
            Text(accounts.map { "\($0.label) \($0.age.map { UsageStatusPopover.age(of: $0, at: now) } ?? "no reading")" }.joined(separator: " · "))
                .help(accounts.map { "\($0.label): \($0.sources.joined(separator: ", "))" }.joined(separator: "\n"))
            if !stale.isEmpty {
                let warning = stale.map { "\($0.label): \($0.status ?? "no current reading")" }.joined(separator: "\n")
                Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.warning)
                    .help(warning).accessibilityLabel(warning)
            }
        }.font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
    }
}
