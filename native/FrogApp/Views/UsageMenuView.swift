import FrogCore
import SwiftUI
import FrogUsage

/// LLM usage's tab in Frog's menu-bar popup, laid out as the LLM usage popup: the provider, refresh and the way to the
/// page, then the limits card and the activity card. When the limits were read is the tab's status on the leading
/// side of Frog's footer (`UsageMenuFooterStatus`), where the Frog and System tabs say theirs.
struct UsageMenuTab: View {
    @ObservedObject var usage: UsageDashboardModel
    let openPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.panelCardGap) {
            // The provider leads the row, on the cards' text edge, so it reads as what the cards below are about;
            // refresh and the way to the page end it, boxed as in the LLM usage popup's header.
            HStack(spacing: FrogStyle.space6) {
                // Its name on the cards' text edge; only the hover fill reaches past it.
                UsageProviderDropdown(usage: usage).padding(.leading, -7)
                Spacer(minLength: FrogStyle.space6)
                UsageRefreshAction(usage: usage, bordered: true)
                IconAction(title: "Open LLM usage", symbol: "arrow.up.forward.app", bordered: true, action: openPage)
            }.padding(.leading, FrogStyle.cardPadding).padding(.trailing, FrogStyle.space6).padding(.bottom, FrogStyle.space4)
            UsageMenuCards(usage: usage)
        }
        .background(FeatureVisibility { usage.setPresented($0, for: .menu) })
    }
}

/// The two cards the tab and the popup share: the plan limits, then the period's activity. `accounts` stands in
/// for the model's accounts, for pictures of the popup with several Claude accounts.
private struct UsageMenuCards: View {
    @ObservedObject var usage: UsageDashboardModel
    var accounts: [UsageAccountSummary]? = nil
    var body: some View {
        UsageMenuLimitsBlock(usage: usage, accounts: accounts).padding(FrogStyle.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
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
    static let width: CGFloat = StatusItemPopup.width
    @ObservedObject var usage: UsageDashboardModel
    let openDashboard: () -> Void
    var signIn: () -> Void = {}
    var installUpdate: () -> Void = {}
    /// "Set up live readings for B…": the caller explains it before Terminal opens.
    var liveSetup: (UsageAccountSummary) -> Void = { _ in }
    /// "Sign in to Claude Code for B…", for an account whose own Claude Code login is gone.
    var accountSignIn: (UsageAccountSummary) -> Void = { _ in }
    /// Stands in for the model's Claude accounts, for pictures of the popup with two of them.
    var sampleAccounts: [UsageAccountSummary]? = nil

    @ObservedObject private var readiness = UpdateReadiness.shared

    var body: some View {
        let provider = usage.preferences.provider
        let accounts = sampleAccounts ?? Self.shownAccounts(usage)
        let setup = accounts.first(where: \.needsLiveSetup)
        let signInAccount = setup == nil ? accounts.first(where: \.needsSignIn) : nil
        let claudeSignIn = setup == nil && signInAccount == nil && provider == "Claude" && accounts.isEmpty && usage.needsClaudeSignIn
        VStack(alignment: .leading, spacing: 0) {
            // The header and content keep the panel's inset; the footer band below runs to the panel's edges.
            VStack(alignment: .leading, spacing: 0) {
                FrogPopupHeader(symbol: LLMUsagePlugin.info.symbol, tint: LLMUsagePlugin.info.tint, title: "LLM usage") {
                    // The header's own 8-point gaps, so with the two actions it fits the popup's width: a wider
                    // header pushed the cards under it off-centre.
                    UsageProviderDropdown(usage: usage)
                    UsageRefreshAction(usage: usage, bordered: true)
                    IconAction(title: "Open LLM usage", symbol: "arrow.up.forward.app", bordered: true, action: openDashboard)
                }
                VStack(alignment: .leading, spacing: FrogStyle.panelCardGap) {
                    UsageMenuCards(usage: usage, accounts: sampleAccounts)
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
            }.padding([.horizontal, .top], FrogStyle.panelCardInset)
            FrogPopupFooter { UsageMenuStatus(usage: usage, sampleAccounts: sampleAccounts) }
        }
        .frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
        .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
        .frogPanel()
        .environment(\.locale, L10n.locale)
        // The last reading is on screen at once; the model decides whether it needs a refresh.
        .onAppear { usage.setPresented(true, for: .popup) }
        .onDisappear { usage.setPresented(false, for: .popup) }
    }

    /// When a reading was made, in the one form every list and footer uses (`RecentTimestamp`): "Just now",
    /// "12 min ago", "13:14", "Yesterday".
    static func age(of date: Date, at now: Date) -> String {
        RecentTimestamp.text(min(date, now), now: now)
    }
    /// The Claude accounts shown one by one or combined: only while Frog reads each of them and
    /// finds at least two; otherwise every surface shows the one account as always.
    @MainActor static func shownAccounts(_ usage: UsageDashboardModel, now: Date = FrogClock.now) -> [UsageAccountSummary] {
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
        // Only as wide as the provider's name, so the gap to the actions beside it is the same for every provider.
        FrogDropdown(selected: usage.preferences.provider, options: usage.providers, width: 92, compact: true, title: { $0 }) {
            usage.selectProvider($0)
        }.fitToContent().accessibilityLabel("Provider")
    }
}

/// The popup's limits card: the accounts notice, the plan windows and, when enabled, extra usage.
private struct UsageMenuLimitsBlock: View {
    @ObservedObject var usage: UsageDashboardModel
    var accounts: [UsageAccountSummary]? = nil
    var body: some View {
        let provider = usage.preferences.provider
        let shown = accounts ?? UsageStatusPopover.shownAccounts(usage)
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            if provider == "Claude", usage.accountsNoticeVisible { UsageAccountsNotice(usage: usage, compact: true) }
            if let accounts {
                UsageCompactAccounts(accounts: accounts.filter(\.included), now: FrogClock.now)
            } else if shown.isEmpty {
                UsageCompactLimits(usage: usage)
            } else {
                UsageAccountsLimits(usage: usage, compact: true)
            }
            UsageExtraUsageBlock(usage: usage)
        }
    }
}

/// Each Claude account's limits in a popup: the "Plan limits" caption, then one block per account.
struct UsageCompactAccounts: View {
    let accounts: [UsageAccountSummary]
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space12) {
            SectionCaption(text: "Plan limits")
            ForEach(accounts.prefix(4)) { UsageAccountRow(account: $0, now: now) }
        }
    }
}

/// "Extra usage": what was spent this month beyond the plan, against the monthly limit when there is one.
/// Nothing while it is off. The same text is on the page's row.
struct UsageExtraUsageBlock: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        if let extra = usage.extraUsage(provider: usage.preferences.provider) {
            let tint = extra.fraction.map { FrogStyle.level($0, warning: 0.8, critical: 0.95) } ?? FrogStyle.accent
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Extra usage").font(FrogType.bodyMedium)
                    Spacer()
                    Text(extra.used).font(GraphStyle.figure).monospacedDigit()
                }
                if let fraction = extra.fraction {
                    FrogMeter(fraction: fraction, tint: tint)
                }
                HStack(spacing: 4) {
                    Text("This month")
                    Spacer(minLength: 4)
                    if let limit = extra.limit { Text("of \(limit) limit").monospacedDigit() }
                }.lineLimit(1)
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
            let windows = usage.windows(provider: provider, now: FrogClock.now(or: context.date))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionCaption(text: "Plan limits")
                    Spacer()
                    if let plan = usage.planName(provider: provider) { UsagePlanBadge(plan: plan) }
                }
                if windows.isEmpty {
                    Text("No current reading").font(FrogType.bodyMedium).help(usage.status(provider: provider))
                } else {
                    ForEach(Array(windows.prefix(4))) { UsageLimitView(window: $0, now: FrogClock.now(or: context.date), compact: true) }
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
        VStack(alignment: .leading, spacing: FrogStyle.space12) {
            // The period is a choice of two or three, so it is segments, level with the legend's line, as on the
            // page: every period in view, nothing that reads as a slider.
            HStack(alignment: .top) {
                UsageActivityTotal(usage: usage, chart: chart)
                Spacer(minLength: FrogStyle.space8)
                CompactSegments(values: usage.ranges, selected: settings.range, compact: true, title: { $0 }) { range in
                    var next = usage.preferences; next.range = range; usage.updatePreferences(next)
                }.fixedSize().offset(y: -FrogStyle.space4).accessibilityLabel("Activity period")
            }
            UsageActivityChart(usage: usage, chart: chart, compact: true)
            if usage.loaded, chart.hasActivity {
                HStack {
                    Text("Total tokens").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    Spacer()
                    Text(usage.format(chart.totalTokens, metric: "Input")).font(FrogType.body).monospacedDigit()
                }.font(FrogType.small)
            }
            UsageActivityNotes(usage: usage, chart: chart, compact: true)
        }
    }
}

/// The Usage tab's status in Frog's footer: the age of the oldest reading shown ("16m ago"), no longer than Frog's
/// "Ready", so Settings and Quit keep their words; every account's age and source on hover, and a warning glyph
/// when one has no current reading.
struct UsageMenuFooterStatus: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        let provider = usage.preferences.provider
        let accounts = UsageStatusPopover.shownAccounts(usage).filter(\.included)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let oldest = accounts.isEmpty ? usage.planUpdatedAt(provider: provider) : accounts.compactMap(\.age).min()
            let age = oldest.map { UsageStatusPopover.age(of: $0, at: FrogClock.now(or: context.date)) }
            let details = accounts.isEmpty
                ? [age.map { "Updated \($0)" }, usage.planSource(provider: provider), usage.status(provider: provider)].compactMap { $0 }
                : accounts.map { "\($0.label): \($0.age.map { UsageStatusPopover.age(of: $0, at: FrogClock.now(or: context.date)) } ?? "no reading")" }
            let warning = accounts.isEmpty ? usage.planWarning(provider: provider)
                : accounts.filter(\.stale).map { "\($0.label): \($0.status ?? "no current reading")" }.joined(separator: "\n").nilIfBlank
            FrogFooterStatus(text: age ?? L10n.text("No reading yet"), tone: Self.tone(age: oldest, warning: warning))
                .accessibilityLabel(age.map { "Updated \($0)" } ?? L10n.text("No reading yet"))
                .help(([warning].compactMap { $0 } + details).joined(separator: "\n"))
        }
    }
}

extension UsageMenuFooterStatus {
    /// Green while the readings are current, the warning colour when one is old or missing, a hollow ring before
    /// the first.
    static func tone(age: Date?, warning: String?) -> FrogFooterStatus.Tone {
        age == nil ? .off : warning == nil ? .good : .warning
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}

/// When the limits were read, the source on hover; one entry per account while each is shown.
struct UsageMenuStatus: View {
    @ObservedObject var usage: UsageDashboardModel
    var sampleAccounts: [UsageAccountSummary]? = nil
    var body: some View {
        let provider = usage.preferences.provider
        let accounts = sampleAccounts ?? UsageStatusPopover.shownAccounts(usage)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if !accounts.isEmpty {
                UsageAccountsFooter(accounts: accounts.filter(\.included), now: FrogClock.now(or: context.date))
            } else {
                // The footer's one status form, a dot and a short word, as Frog's "Ready" and System's "Live":
                // when the limits were read; "Updated", the source and any warning are in the tooltip.
                let updated = usage.planUpdatedAt(provider: provider)
                let age = updated.map { UsageStatusPopover.age(of: $0, at: FrogClock.now(or: context.date)) }
                let warning = usage.planWarning(provider: provider)
                FrogFooterStatus(text: age ?? L10n.text("No plan reading yet"), tone: UsageMenuFooterStatus.tone(age: updated, warning: warning))
                    .help(([warning, age.map { "Updated \($0)" }, usage.planSource(provider: provider), usage.status(provider: provider)]).compactMap { $0 }.joined(separator: "\n"))
                    .accessibilityLabel(age.map { "Updated \($0)" } ?? "No plan reading yet")
            }
        }
    }
}

/// One account in the popup: its label, plan and age, then Session and Week each on a line of its own, its name, a
/// full-width meter with the tick for the time gone, the share used and when it renews, in columns that line up
/// from account to account.
struct UsageAccountRow: View {
    let account: UsageAccountSummary
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space8) {
            HStack(spacing: FrogStyle.space6) {
                Text(Self.title(account.label)).font(FrogType.bodyMedium).lineLimit(1)
                if let plan = account.plan { UsagePlanBadge(plan: plan) }
                Spacer(minLength: FrogStyle.space4)
                Text(account.age.map { UsageStatusPopover.age(of: $0, at: now) } ?? L10n.text("No reading yet"))
                    .font(FrogType.caption).monospacedDigit().foregroundStyle(FrogStyle.muted).lineLimit(1)
                if account.stale {
                    Image(systemName: "exclamationmark.circle").font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                        .accessibilityLabel("No current reading")
                }
            }
            VStack(alignment: .leading, spacing: FrogStyle.space6) {
                UsageAccountWindowLine(title: "Session", window: account.windows.first { $0.id == "five_hour" }, now: now)
                UsageAccountWindowLine(title: "Week", window: account.windows.first { $0.id == "seven_day" }, now: now)
            }.opacity(account.stale ? 0.55 : 1)
        }.contentShape(Rectangle()).help(account.status ?? "").accessibilityElement(children: .combine)
    }

    /// A default label is one letter, which the menu bar fits; written out here, "A" reads as "Account A".
    static func title(_ label: String) -> String {
        label.count == 1 && label.first?.isLetter == true ? L10n.text("Account \(label)") : label
    }
}

/// "Session  ━━━━━━━──────  37%  15:40": a window of one account, one line high.
private struct UsageAccountWindowLine: View {
    let title: String
    let window: UsageWindow?
    let now: Date
    /// The columns, so the meters and figures of every account line up.
    static let titleWidth: CGFloat = 52
    static let valueWidth: CGFloat = 34
    static let resetWidth: CGFloat = 48

    var body: some View {
        let known = window.map { $0.percentage.isFinite } ?? false
        let fraction = known ? min(1, max(0, (window?.percentage ?? 0) / 100)) : 0
        HStack(spacing: FrogStyle.space8) {
            Text(L10n.text(title)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                .frame(width: Self.titleWidth, alignment: .leading)
            FrogMeter(fraction: fraction, tint: FrogStyle.level(fraction, warning: 0.8, critical: 0.95), tick: elapsed)
            // A window that renewed after the last reading starts again from nothing: 0% until the next reading,
            // in the same columns as every other line.
            Text(known ? window?.usedText ?? "" : "0%").font(FrogType.label).monospacedDigit().lineLimit(1)
                .frame(width: Self.valueWidth, alignment: .trailing)
            Text(known ? window?.resetsAt.map { UsageStatusPopover.shortReset($0, now: now) } ?? "" : L10n.text("Renewed"))
                .font(FrogType.caption).monospacedDigit().foregroundStyle(FrogStyle.muted).lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: Self.resetWidth, alignment: .trailing)
                .help(known ? window?.resetsAt.map { "Renews \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                            : "Renewed since the last reading")
        }
    }

    private var elapsed: Double? {
        guard let window, window.percentage.isFinite, let reset = window.resetsAt, let duration = window.duration, duration > 0 else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / duration))
    }
}

/// "A 3m ago · B 2h ago", the sources on hover.
private struct UsageAccountsFooter: View {
    let accounts: [UsageAccountSummary]
    let now: Date
    var body: some View {
        let stale = accounts.filter(\.stale)
        let oldest = accounts.compactMap(\.age).min()
        let warning = stale.map { "\($0.label): \($0.status ?? "no current reading")" }.joined(separator: "\n")
        // Each account's age is on its own row above; the footer says the oldest, in the footer's one form.
        FrogFooterStatus(text: oldest.map { UsageStatusPopover.age(of: $0, at: now) } ?? L10n.text("No reading yet"),
                         tone: UsageMenuFooterStatus.tone(age: oldest, warning: stale.isEmpty ? nil : warning))
            .help(([stale.isEmpty ? nil : warning] + accounts.map { "\($0.label): \($0.sources.joined(separator: ", "))" }).compactMap { $0 }.joined(separator: "\n"))
    }
}
