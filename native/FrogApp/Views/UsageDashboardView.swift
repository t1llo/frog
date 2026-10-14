import SwiftUI
import Charts
import FrogUsage

struct UsageDashboardView: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Mr. Usage", subtitle: "Your plan limits and AI activity.") {
                IconAction(title: "Refresh usage", symbol: "arrow.clockwise", bordered: true) { usage.refresh() }
            }
            UsageProviderControls(usage: usage)
            if usage.preferences.provider == "Claude" {
                HStack(spacing: 8) {
                    Text("Claude Code profile: \(usage.claudeConfigDirectory.lastPathComponent)")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        .help(usage.claudeConfigDirectory.path)
                    Button("Choose folder…") { chooseClaudeProfile() }.buttonStyle(FrogButtonStyle())
                }
            }
            UsageLimitsView(usage: usage)
            Divider().overlay(FrogStyle.border.opacity(0.4))
            UsageActivityView(usage: usage)
            UsageAccountDetails(usage: usage)
            Text("API value is an estimate, not your subscription bill.")
                 .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                 .help("Token activity comes from local tool logs; all-device data includes account estimates. Plan limits come from the labeled account or log source. Collection continues while Mr. Usage is enabled.")
        }
        // The main window keeps this page after it is closed or minimised, so appearing and
        // disappearing do not say whether anyone can see it.
        .background(FeatureVisibility { usage.setPresented($0, for: .dashboard) })
    }
    private func chooseClaudeProfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = usage.claudeConfigDirectory
        panel.message = "Choose the Claude Code configuration folder for the plan login and lifetime stats."
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            usage.selectClaudeConfigDirectory(directory)
        }
    }
}

/// The menu-bar popup, laid out like Frog's own: a 42-point header, content, one command row
/// and a quiet footer, as tall as its content.
struct UsageStatusPopover: View {
    static let popupName = "Mr. Usage"
    static let width: CGFloat = 292
    @ObservedObject var usage: UsageDashboardModel
    let openDashboard: () -> Void
    var signIn: () -> Void = {}
    var installUpdate: () -> Void = {}
    var body: some View {
        let provider = usage.preferences.provider
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Mr. Usage").font(.system(size: 13, weight: .semibold)).fixedSize()
                Spacer(minLength: 6)
                CompactSegments(values: usage.providers, selected: provider, width: 128, compact: true, title: { $0 }) {
                    var next = usage.preferences; next.provider = $0; usage.updatePreferences(next)
                }.accessibilityElement(children: .contain).accessibilityLabel("Usage provider")
                IconAction(title: "Refresh usage", symbol: "arrow.clockwise", bordered: true) { usage.refresh() }
            }.padding(.horizontal, 8).frame(height: 42)
            VStack(alignment: .leading, spacing: 14) {
                UsageLimitsView(usage: usage, compact: true)
                Divider().overlay(FrogStyle.border.opacity(0.4))
                UsageActivityView(usage: usage, compact: true,
                    showsCompactTokens: usage.windows(provider: provider).count <= 1)
            }.padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 12)
            if provider == "Claude", usage.needsClaudeSignIn {
                MenuActionRow(title: usage.checkingClaudeSignIn ? "Checking Claude Code’s login…" : "Sign in to Claude Code…",
                              symbol: "person.crop.circle.badge.checkmark", action: signIn)
                    .disabled(usage.checkingClaudeSignIn).help(usage.status(provider: provider))
            }
            UpdateReadyRow(install: installUpdate)
            MenuActionRow(title: "Open dashboard", symbol: "arrow.up.forward.app", action: openDashboard)
            Divider().padding(.horizontal, 8)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 4) {
                    Text(usage.planUpdatedAt(provider: provider).map { "Updated \(Self.age(of: $0, at: context.date))" } ?? "No plan reading yet")
                        .help(usage.status(provider: provider))
                    if let warning = usage.planWarning(provider: provider) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.warning)
                            .help(warning).accessibilityLabel(warning)
                    }
                    Spacer()
                    if let source = usage.planSource(provider: provider) { Text(source) }
                }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }.padding(.horizontal, 9).padding(.vertical, 8)
        }
        .padding(5).frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
        .frogPanel()
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
}

private struct UsageProviderControls: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        HStack(spacing: 12) {
            CompactSegments(values: usage.providers, selected: usage.preferences.provider, width: 220, title: { $0 }) {
                var next = usage.preferences; next.provider = $0; usage.updatePreferences(next)
            }.accessibilityLabel("Usage provider")
            Spacer(minLength: 0)
            if usage.preferences.provider == "Claude" {
                CompactMenu(value: usage.loginSource, width: 180) {
                    ForEach(usage.loginSources, id: \.self) { source in
                        Button(source) { usage.selectLoginSource(source) }
                    }
                }.accessibilityLabel("Claude login source").help("Where Claude plan limits are read from")
            }
        }
    }
}

private struct UsageLimitsView: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let provider = usage.preferences.provider
            let windows = usage.windows(provider: provider, now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                if compact {
                    HStack {
                        Text("Plan limits").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        Spacer()
                        if let plan = usage.planName(provider: provider) {
                            Text(plan).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(FrogStyle.inset, in: Capsule()).foregroundStyle(FrogStyle.muted)
                        }
                    }
                } else if let plan = usage.planName(provider: provider) {
                    Label("\(plan) plan", systemImage: "person.crop.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                if windows.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: compact ? 15 : 20)).foregroundStyle(FrogStyle.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No current reading").font(.system(size: 12, weight: .medium))
                            if !compact { Text("The source status below explains the latest check.")
                                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            }
                        }
                    }.padding(.vertical, compact ? 2 : 8).help(usage.status(provider: provider))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact || windows.count == 1 ? 1 : 2), alignment: .leading, spacing: compact ? 14 : 18) {
                        ForEach(compact ? Array(windows.prefix(4)) : windows) { window in UsageLimitView(window: window, now: context.date, compact: compact) }
                    }
                }
                if !compact, usage.status(provider: provider) != "Newest available plan limits" {
                  Text(usage.status(provider: provider))
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(2)
                     .help(usage.status(provider: provider)).textSelection(.enabled)
                }
                if !compact, provider == "Claude", usage.needsClaudeSignIn {
                    Button(usage.checkingClaudeSignIn ? "Checking Claude Code’s login…" : "Sign in to Claude Code…") { ClaudeSignIn.start(usage) }
                        .buttonStyle(FrogButtonStyle()).disabled(usage.checkingClaudeSignIn)
                }
                if !compact, let credits = usage.credits(provider: provider) {
                    Label(credits, systemImage: "creditcard").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                if !compact, provider == "Claude", let label = usage.accountLabel {
                    Text(label).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                if !compact, let source = usage.planSource(provider: provider), !windows.isEmpty {
                    HStack(spacing: 4) {
                        Text(source)
                        if let updated = usage.planUpdatedAt(provider: provider) {
                            Text("·"); Text(updated, style: .relative); Text("ago")
                        }
                    }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
            }
        }
    }
}

private struct UsageLimitView: View {
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
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(window.percentage.isFinite ? String(format: "%.0f%%", window.percentage) : "—")
                    .font(.system(size: compact ? 14 : 17, weight: .semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(FrogStyle.inset)
                Capsule().fill(meterColor)
                    .frame(width: geometry.size.width * fraction)
                if let elapsed {
                    Rectangle().fill(FrogStyle.ink.opacity(0.55)).frame(width: 1, height: 9)
                        .offset(x: max(0, min(geometry.size.width - 1, geometry.size.width * elapsed)), y: -2)
                }
            }.frame(height: 5).accessibilityHidden(true).help("The tick marks elapsed time in this plan window.")
            HStack {
                Text(window.percentage.isFinite ? String(format: "%.0f%% left", (1 - fraction) * 100) : "No reading since it renewed")
                if compact, (window.duration ?? 0) >= 604800, let pace = window.pace(at: now) {
                    Text("· \(pace)").foregroundStyle(paceColor(pace))
                }
                Spacer(minLength: 4)
                if let reset = window.resetsAt {
                    Text("Resets in \(Duration.seconds(max(0, reset.timeIntervalSince(now))).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1)))")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                }
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
            if !compact, let elapsed, let pace = window.pace(at: now) {
                Text(pace)
                    .font(.system(size: 10)).foregroundStyle(paceColor(pace))
                    .help("\(Int(fraction * 100))% used with \(Int(elapsed * 100))% of the window elapsed")
            }
        }.padding(.trailing, compact ? 0 : 8).accessibilityElement(children: .combine)
    }
}

private struct UsageActivityView: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var showsCompactTokens = false
    var body: some View {
        let settings = usage.preferences
        let chart = usage.chart(provider: settings.provider, range: settings.range, metric: settings.metric)
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(alignment: .top) {
                GraphLegend(color: FrogStyle.series, title: settings.metric == "API cost" ? (compact ? "API estimate" : "Estimated API cost") : "\(settings.metric) tokens", spacing: 5) {
                    Text(chart.total).font(.system(size: compact ? 20 : 32, weight: .semibold)).tracking(-0.6).monospacedDigit()
                }
                Spacer()
                if !compact {
                    CompactMenu(value: settings.metric, width: 130) {
                        ForEach(usage.metrics, id: \.self) { metric in
                            Button(metric == "Input" ? "Uncached input" : metric) {
                                var next = usage.preferences; next.metric = metric; usage.updatePreferences(next)
                            }
                        }
                    }.accessibilityLabel("Activity metric")
                }
                CompactMenu(value: compact ? settings.range : rangeTitle(settings.range), width: compact ? 70 : 150) {
                    ForEach(usage.ranges, id: \.self) { range in
                        Button(rangeTitle(range)) { var next = usage.preferences; next.range = range; usage.updatePreferences(next) }
                            .help(rangeSpan(range))
                    }
                }.accessibilityLabel("Activity period")
            }
            if !usage.loaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading token activity…").font(.system(size: 11)).foregroundStyle(FrogStyle.muted) }
                    .frame(maxWidth: .infinity, minHeight: compact ? 80 : 140)
            } else if !chart.hasActivity {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 22)).foregroundStyle(FrogStyle.muted)
                    Text("No token activity in this period").font(.system(size: 12, weight: .medium))
                    if !compact { Text(settings.provider == "Claude" ? "Reads Claude Code, OpenCode and Pi logs. Desktop-only chats are not included." : "Reads Codex, OpenCode and Pi logs on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity, minHeight: compact ? 80 : 140)
            } else {
                UsageTrendChart(steps: UsageTrend(chart.points.map { ($0.date, $0.value) }).steps, compact: compact,
                    hourly: chart.range == "24h", timeZone: chart.account ? TimeZone(secondsFromGMT: 0)! : .current) {
                    usage.format($0, metric: settings.metric)
                }.id("\(settings.provider) \(settings.range)")
                if compact {
                    HStack {
                        Text("Total tokens").foregroundStyle(FrogStyle.muted)
                        Spacer()
                        Text(usage.format(chart.totalTokens, metric: "Input")).monospacedDigit()
                    }.font(.system(size: 11))
                    if showsCompactTokens {
                        HStack(spacing: 12) {
                            ForEach(["Input", "Cache read", "Output"], id: \.self) { name in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name == "Cache read" ? "Cached" : name).lineLimit(1).foregroundStyle(FrogStyle.muted)
                                    Text(usage.format(chart.totals.first { $0.name == name }?.value ?? 0, metric: name)).monospacedDigit()
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.system(size: 10))
                            .help("Input excludes cache reads. Account token splits are estimates; full details are in the dashboard.")
                    }
                } else { UsageTokenTotals(usage: usage, chart: chart) }
                if !compact {
                    VStack(spacing: 0) {
                        ForEach(chart.models) { row in
                            VStack(spacing: 6) {
                              HStack(spacing: 12) {
                                Circle().fill(FrogStyle.accent.opacity(0.65)).frame(width: 5, height: 5)
                                Text(row.name).lineLimit(1).help(row.name)
                                Spacer()
                                Text(usage.format(row.value, metric: settings.metric)).monospacedDigit()
                              }.font(.system(size: 12))
                              GeometryReader { geometry in
                                  Capsule().fill(FrogStyle.accent.opacity(0.2))
                                      .frame(width: geometry.size.width * row.value / max(row.value, chart.models.map(\.value).reduce(0, +)))
                              }.frame(height: 2)
                            }.padding(.vertical, 9)
                            if row.id != chart.models.last?.id { Divider().overlay(FrogStyle.border.opacity(0.25)) }
                        }
                    }
                }
            }
            if !compact, !chart.unpricedModels.isEmpty {
                Text("Price unavailable: " + chart.unpricedModels.joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(compact ? 2 : nil)
            }
            if let warning = usage.activityWarning {
                Label(compact ? "Activity may be incomplete" : warning, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    .help(warning)
            }
            if !compact, !chart.sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity sources").font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.muted)
                    ForEach(chart.sources) { source in
                        HStack {
                            Text(source.name)
                            Spacer()
                            Text(usage.format(source.value, metric: settings.metric)).monospacedDigit()
                        }.font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    }
                }
            }
            if !compact, settings.provider == "OpenAI" {
                Text(usage.hasAccountActivity
                     ? "Account totals by UTC day; local activity fills unreported days. Token splits and API cost are estimated from \(usage.accountEstimateBasis)."
                     : "Account activity is unavailable. Showing this Mac’s logs while account checks retry.")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            } else if !compact {
                Text("Local logs can span multiple accounts; they are not filtered by the selected plan login.")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            }
        }
    }
    private func rangeTitle(_ range: String) -> String {
        switch range { case "24h": "Last 24 hours"; case "30d": "Last 30 days"; default: "Last 7 days" }
    }
    /// The bars are whole hours or days and the newest is still under way, so a period starts
    /// at the beginning of its first bar rather than exactly 24 hours or 7 days ago.
    private func rangeSpan(_ range: String) -> String {
        switch range {
        case "24h": "The current hour and the previous 23"
        case "30d": "Today and the previous 29 days"
        default: "Today and the previous 6 days"
        }
    }
}

private struct UsageTokenTotals: View {
    @ObservedObject var usage: UsageDashboardModel
    let chart: UsageChart
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Total tokens · \(chart.range)").foregroundStyle(FrogStyle.muted)
                Spacer()
                Text(usage.format(chart.totalTokens, metric: "Input")).monospacedDigit()
            }.font(.system(size: 12, weight: .medium))
                .help("Uncached input + cache reads + cache writes + output. Lifetime statistics are separate.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(chart.totals) { total in
                    Button {
                        var next = usage.preferences; next.metric = total.name; usage.updatePreferences(next)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(total.label == "API cost" ? "API equivalent" : total.label)
                                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                Text(usage.format(total.value, metric: total.name))
                                    .font(.system(size: 14, weight: .medium)).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                            if total.name == usage.preferences.metric {
                                Circle().fill(FrogStyle.accent).frame(width: 4, height: 4)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(total.name == usage.preferences.metric ? AnyShapeStyle(FrogStyle.accent.opacity(0.08)) : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(total.name == usage.preferences.metric ? .isSelected : [])
                }
            }
        }
    }
}

private struct UsageAccountDetails: View {
    @ObservedObject var usage: UsageDashboardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let lifetime = usage.lifetime(provider: usage.preferences.provider) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(lifetime.detail).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            ForEach(lifetime.statistics) { statistic in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(statistic.name).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                    Text(statistic.value).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text(lifetime.note).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }.padding(.top, 8)
                } label: { Text(lifetime.title).font(.system(size: 12, weight: .medium)) }
            }
            if usage.preferences.provider == "OpenAI", !usage.planHistory.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("All devices · daily report; can lag live limits.")
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        if let updated = usage.planHistoryUpdatedAt {
                            Text("Reported \(updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        }
                        ForEach(usage.planHistory.prefix(5)) { period in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(period.start.formatted(date: .abbreviated, time: .omitted)) – \(period.end.formatted(date: .abbreviated, time: .omitted))")
                                    Spacer()
                                    Text(String(format: "%.1f%%", period.percentage)).monospacedDigit()
                                }.font(.system(size: 11))
                                ProgressView(value: min(100, max(0, period.percentage)), total: 100).tint(FrogStyle.accent)
                                ForEach(period.models.prefix(4)) { row in
                                    HStack {
                                        Text(row.name); Spacer()
                                        Text(String(format: "%.1f%%", row.value)).monospacedDigit()
                                    }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                }
                            }
                        }
                    }.padding(.top, 8)
                } label: { Text("Recent plan usage").font(.system(size: 12, weight: .medium)) }
            }
        }
    }
}

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
                        .foregroundStyle(FrogStyle.series).cornerRadius(1)
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
            .background(alignment: .bottom) { Rectangle().fill(FrogStyle.muted.opacity(0.15)).frame(height: 1) }
            .overlay(alignment: .topLeading) {
                if let selected {
                    Text("\(label(selected.date, long: true)) · \(format(selected.amount)) · \(format(selected.total)) total")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
                        .padding(6).background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: 4))
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
