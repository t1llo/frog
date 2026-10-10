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
        .onAppear { usage.setPresented(true) }
        .onDisappear { usage.setPresented(false) }
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

struct UsageStatusPopover: View {
    @ObservedObject var usage: UsageDashboardModel
    var height: CGFloat = 420
    let openDashboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mr. Usage").font(.system(size: 13, weight: .semibold))
                Spacer()
                IconAction(title: "Refresh usage", symbol: "arrow.clockwise", bordered: true) { usage.refresh() }
            }
            UsageProviderControls(usage: usage, compact: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    UsageLimitsView(usage: usage, compact: true)
                    Divider().overlay(FrogStyle.border.opacity(0.4))
                    UsageActivityView(usage: usage, compact: true)
                }.padding(.trailing, 4)
            }
            HStack {
                Label(usage.preferences.provider == "OpenAI" && usage.preferences.allDevices && usage.hasAccountActivity ? "Account estimates" : "Local token history", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                Spacer()
                Button("Dashboard", systemImage: "arrow.up.right") { openDashboard() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            }
        }
        .padding(14).frame(width: 360, height: height).frogPanel()
        .onAppear { usage.setPresented(true) }
        .onDisappear { usage.setPresented(false) }
    }
}

private struct UsageProviderControls: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
                CompactSegments(values: usage.providers, selected: usage.preferences.provider, width: compact ? 200 : 220, title: { $0 }) {
                    var next = usage.preferences; next.provider = $0; usage.updatePreferences(next)
                }.accessibilityLabel("Usage provider")
                Spacer(minLength: 0)
            if usage.preferences.provider == "Claude" {
                    CompactMenu(value: usage.loginSource, width: compact ? 118 : 180) {
                        ForEach(usage.loginSources, id: \.self) { source in
                            Button(source) { usage.selectLoginSource(source) }
                        }
                    }.accessibilityLabel("Claude login source").help("Saved login")
            } else {
                    CompactMenu(value: usage.preferences.allDevices ? "All devices" : "This Mac", width: compact ? 118 : 180) {
                        Button("This Mac") { selectAllDevices(false) }
                        Button("All devices") { selectAllDevices(true) }
                    }.accessibilityLabel("OpenAI activity source")
            }
        }
    }
    private func selectAllDevices(_ value: Bool) {
        var next = usage.preferences; next.allDevices = value; usage.updatePreferences(next)
    }
}

private struct UsageLimitsView: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let provider = usage.preferences.provider
            let windows = usage.windows(provider: provider, now: context.date)
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if let plan = usage.planName(provider: provider) {
                    Label("\(plan) plan", systemImage: "person.crop.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                if windows.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 20)).foregroundStyle(FrogStyle.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Plan limits unavailable").font(.system(size: 12, weight: .medium))
                            Text("The source status below explains the latest check.")
                                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        }
                    }.padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: compact ? 10 : 18) {
                        ForEach(windows) { window in UsageLimitView(window: window, now: context.date, compact: compact) }
                    }
                }
                if usage.status(provider: provider) != "Newest available plan limits" {
                  Text(usage.status(provider: provider))
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(2)
                    .lineLimit(compact ? 3 : nil).help(usage.status(provider: provider)).textSelection(.enabled)
                }
                if let credits = usage.credits(provider: provider) {
                    Label(credits, systemImage: "creditcard").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                if provider == "Claude", let label = usage.accountLabel {
                    Text(label).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                if let source = usage.planSource(provider: provider), !windows.isEmpty {
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
    private var meterColor: Color { fraction >= 0.95 ? .red : fraction >= 0.8 ? .orange : FrogStyle.accent }
    private var elapsed: Double? {
        guard let reset = window.resetsAt, let duration = window.duration, duration > 0 else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / duration))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
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
                Text(window.percentage.isFinite ? String(format: "%.0f%% left", (1 - fraction) * 100) : "Unknown")
                Spacer(minLength: 4)
                if let reset = window.resetsAt {
                    Text("Resets \(Duration.seconds(max(0, reset.timeIntervalSince(now))).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1)))")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                }
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            if let elapsed, !compact {
                Text(window.percentage >= 100 ? "Limit reached" : fraction > elapsed + 0.1 ? "Ahead of pace" : fraction < elapsed - 0.1 ? "Under pace" : "On pace")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    .help("\(Int(fraction * 100))% used with \(Int(elapsed * 100))% of the window elapsed")
            }
        }.padding(.trailing, compact ? 0 : 8).accessibilityElement(children: .combine)
    }
}

private struct UsageActivityView: View {
    @ObservedObject var usage: UsageDashboardModel
    var compact = false
    var body: some View {
        let settings = usage.preferences
        let chart = usage.chart(provider: settings.provider, range: settings.range, metric: settings.metric,
                                allDevices: settings.provider == "OpenAI" && settings.allDevices)
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(settings.metric == "API cost" ? "Estimated API cost" : "\(settings.metric) tokens")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
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
                CompactMenu(value: rangeTitle(settings.range), width: compact ? 124 : 150) {
                    ForEach(usage.ranges, id: \.self) { range in
                        Button(rangeTitle(range)) { var next = usage.preferences; next.range = range; usage.updatePreferences(next) }
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
                    Text(settings.provider == "Claude" ? "Reads Claude Code, OpenCode and Pi logs. Desktop-only chats are not included." : "Reads Codex, OpenCode and Pi logs on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: compact ? 80 : 140)
            } else {
                UsageActivityChart(usage: usage, chart: chart, compact: compact)
                if compact {
                    HStack {
                        Text("Total tokens").foregroundStyle(FrogStyle.muted)
                        Spacer()
                        Text(usage.format(chart.totalTokens, metric: "Input")).monospacedDigit()
                    }.font(.system(size: 11))
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
            if !chart.unpricedModels.isEmpty {
                Text("Price unavailable: " + chart.unpricedModels.joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(compact ? 2 : nil)
            }
            if let warning = usage.activityWarning {
                Label(warning, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
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
            if !compact, settings.provider == "OpenAI", settings.allDevices {
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

private struct UsageActivityChart: View {
    @ObservedObject var usage: UsageDashboardModel
    let chart: UsageChart
    let compact: Bool
    @State private var selectedDate: Date?
    private var selectedPoint: UsageChartPoint? {
        guard let selectedDate else { return nil }
        return chart.points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    var body: some View {
        Chart {
            ForEach(chart.points) { point in
                BarMark(x: .value("Date", point.date, unit: chart.range == "24h" ? .hour : .day),
                        y: .value(usage.preferences.metric, point.value))
                    .foregroundStyle(FrogStyle.accent.gradient).cornerRadius(3)
                    .opacity(selectedPoint == nil || selectedPoint?.id == point.id ? 1 : 0.4)
                    .accessibilityLabel(point.date.formatted(date: .abbreviated, time: usage.preferences.range == "24h" ? .shortened : .omitted))
                    .accessibilityValue(usage.format(point.value, metric: usage.preferences.metric))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: compact ? 4 : 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: usage.preferences.range == "24h" ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(FrogStyle.border)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(usage.format(amount, metric: usage.preferences.metric)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .environment(\.timeZone, chart.account ? TimeZone(secondsFromGMT: 0)! : .current)
        .onChange(of: chart.range) { _, _ in selectedDate = nil }
        .onChange(of: usage.preferences.provider) { _, _ in selectedDate = nil }
        .frame(height: compact ? 70 : 150)
        .overlay(alignment: .topTrailing) {
            if let point = selectedPoint {
                Text("\(point.date.formatted(date: .abbreviated, time: usage.preferences.range == "24h" ? .shortened : .omitted)) · \(usage.format(point.value, metric: usage.preferences.metric))")
                    .font(.system(size: 10, weight: .medium)).padding(6).background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
            }
        }
    }
}
