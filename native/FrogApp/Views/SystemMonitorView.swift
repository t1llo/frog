import Charts
import SwiftUI

/// The overview wherever it shows; it says when it is on screen, so sampling runs only then.
struct SystemMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    let presenter: SystemMonitorPresenter
    var wide = false

    var body: some View {
        SystemMonitorOverview(snapshot: monitor.snapshot, history: monitor.history, wide: wide)
            .background(FeatureVisibility { monitor.setPresented($0, for: presenter) })
    }
}

/// System monitor's page: the overview, then the menu-bar item.
struct SystemMonitorPage: View {
    @ObservedObject var plugin: SystemMonitorPlugin
    let monitor: SystemMonitor

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "System monitor", subtitle: "CPU and GPU over the last 10 minutes, memory and space on your Mac")
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                FrogSectionHeader("Load")
                SystemMonitorView(monitor: monitor, presenter: .page, wide: true)
            }
            SystemMonitorMenuBarSection(settings: plugin.settings) { plugin.update($0) }
        }
    }
}

/// The menu-bar item's switch, a preview and its looks.
struct SystemMonitorMenuBarSection: View {
    let settings: SystemMonitorSettings
    let save: (SystemMonitorSettings) -> Void
    /// What the preview shows, so every look can be judged on the same load.
    static let sample = SystemMonitorReading(cpu: .value(0.42), gpu: .value(0.78), memory: .value(0.61))

    var body: some View {
        FrogSection("Menu bar") {
            FrogRow("Show in the menu bar") {
                Toggle("Show in the menu bar", isOn: binding(\.menuBarItem)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            if settings.menuBarItem {
                FrogRow("Readings") {
                    FrogDropdown(selection: binding(\.menuBarReadings), options: SystemMonitorSettings.Readings.allCases, width: 180) { $0.title }
                }
                MenuBarStyleGallery(sample: "system|\(settings.menuBarReadings)", style: settings.menuBarStyle, palette: settings.menuBarPalette,
                                    render: { style, palette, dark in
                                        var shown = settings
                                        shown.menuBarStyle = style
                                        shown.menuBarPalette = palette
                                        return MenuBarMeter.image(SystemMonitorStatusItemController.face(Self.sample, settings: shown, dark: dark))
                                    },
                                    chooseStyle: { binding(\.menuBarStyle).wrappedValue = $0 },
                                    choosePalette: { binding(\.menuBarPalette).wrappedValue = $0 })
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<SystemMonitorSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            var next = settings; next[keyPath: key] = value; save(next)
        })
    }
}

/// Value-only content, so previews and tests are independent of the Mac's own load and power.
struct SystemMonitorOverview: View {
    let snapshot: SystemMonitorSnapshot
    var history: [SystemMonitorSample] = []
    /// The page's layout: a taller graph and larger figures.
    var wide = false
    /// Seconds from the newest sample to the moment under the pointer.
    @State private var inspected: Double?

    private var inspectedSample: SystemMonitorSample? {
        guard let inspected, let end = history.last?.time else { return nil }
        return history.min { abs($0.time.timeIntervalSince(end) - inspected) < abs($1.time.timeIntervalSince(end) - inspected) }
    }

    var body: some View {
        let sample = inspectedSample
        // Cards a popup's card gap apart in a popup; on the page, where cards stand alone, 16.
        VStack(spacing: wide ? FrogStyle.space16 : FrogStyle.panelCardGap) {
            // CPU and GPU: one legend entry per line in the graph, each with its dot.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: FrogStyle.space16) {
                    legend("CPU", color: FrogStyle.series, recorded: sample.map(\.cpu), now: snapshot.cpu)
                        .help("Busy time across all CPU cores.")
                    legend("GPU", color: FrogStyle.seriesSecondary, recorded: sample.map(\.gpu), now: snapshot.gpu)
                        .help("The busiest GPU, when its driver reports it.")
                }
                HStack(spacing: 0) {
                    if wide { FrogChartScaleGutter(height: 150) }
                    if history.count < 2 {
                        // Hold the graph's place, so the card does not grow when the first readings arrive. The figures'
                        // skeleton bars and the footer's "Measuring…" already say they are being measured, so the graph
                        // adds no third note.
                        FrogChartPlaceholder(height: wide ? 150 : 54) { EmptyView() }.accessibilityLabel("Measuring")
                    } else {
                        SystemMonitorGraph(history: history, inspected: $inspected, sample: sample, wide: wide).equatable().frame(height: wide ? 150 : 54)
                    }
                }
                GraphAxis(leading: GraphStyle.ago(SystemMonitorGraph.span), trailing: "Now")
                    .padding(.leading, wide ? FrogChart.scaleGutter : 0)
            }.modifier(OverviewCard(wide: wide))
            // Memory and the startup disk: what is used of each, the figure and its meter saying the same thing.
            if snapshot.storage != nil || snapshot.memory != nil || snapshot.cpu == .measuring {
                section(wide ? "Memory and storage" : nil) {
                    // Side by side on the page; one above the other in the narrow popup, where each needs the width.
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: FrogStyle.space16 * 2))
                                      : AnyLayout(VStackLayout(alignment: .leading, spacing: FrogStyle.space12))
                    layout {
                        memory(sample)
                        storage
                    }.modifier(OverviewCard(wide: wide))
                }
            }
            if let power = powerLine {
                section(wide ? "Power" : nil) { power.modifier(OverviewCard(wide: wide)) }
            } else if snapshot.cpu == .measuring && PowerSources.hasInternalBattery {
                // The battery card's place, drawn like the card, until the first reading fills it.
                section(wide ? "Power" : nil) { batterySkeleton.modifier(OverviewCard(wide: wide)) }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("System overview")
    }

    /// On the page, a card under a heading of its own, a section's gap below the one above; in a popup, the card.
    @ViewBuilder private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        if let title {
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                FrogSectionHeader(title)
                content()
            }.padding(.top, FrogStyle.sectionSpacing - FrogStyle.space16)
        } else {
            content()
        }
    }

    /// Memory in use now, or as recorded at the moment under the pointer.
    private func memory(_ sample: SystemMonitorSample?) -> some View {
        let total = snapshot.memory?.total
        let fraction = sample != nil ? sample?.memory : snapshot.memory?.fraction
        return usage(title: "Memory", symbol: "memorychip",
                     used: fraction.flatMap { fraction in total.map { Int64(Double($0) * fraction) } }, total: total, fraction: fraction,
                     level: { FrogStyle.level($0, warning: 0.8, critical: 0.92) }, format: bytes,
                     recordedWithout: sample != nil && fraction == nil)
            .help("Memory in use as Activity Monitor counts it: app memory, wired and compressed.")
    }

    /// Space used on the startup disk, as Finder counts it.
    private var storage: some View {
        let storage = snapshot.storage
        return usage(title: "Storage", symbol: "internaldrive",
                     used: storage.map { $0.total - $0.available }, total: storage?.total, fraction: storage?.usedFraction,
                     level: { FrogStyle.level($0, warning: 0.85, critical: 0.95) }, format: diskBytes, recordedWithout: false)
            .help(storage.map { "\(diskBytes($0.available)) free, counting what macOS can clear." } ?? "")
    }

    /// One block of the memory and storage card: its title, what is used ("312 GB used of 494 GB") and a meter of it.
    private func usage(title: String, symbol: String, used: Int64?, total: Int64?, fraction: Double?,
                       level: (Double) -> Color, format: (Int64) -> String, recordedWithout: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                cardTitle(title, symbol: symbol)
                if let used, let total {
                    Text(format(used)).font(GraphStyle.figure).monospacedDigit()
                    Text("used of \(format(total))").font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                } else if recordedWithout {
                    Text("—").font(FrogType.small)
                } else {
                    // Where the figure goes, beside the title, as tall as the figure's line.
                    FrogSkeleton(width: 64, height: 14)
                        // Centred on the title's line rather than standing on its baseline.
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
            }
            meter(fraction ?? 0, color: fraction.map(level) ?? FrogStyle.accent)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    /// The title of the memory, storage and battery blocks, in the legend's style (`GraphLegend`), so every block of the
    /// overview is headed alike: a small muted symbol where the legend has its dot, and a small muted name.
    private func cardTitle(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(FrogType.caption).accessibilityHidden(true)
            Text(L10n.text(title)).font(FrogType.small).lineLimit(1)
        }.foregroundStyle(FrogStyle.muted).fixedSize()
    }

    /// The battery's charge and state, what the Mac draws, the battery's temperature, and the
    /// thermal state or Low Power Mode only while they say something.
    private var powerLine: AnyView? {
        let power = snapshot.power
        var notes: [String] = []
        if power.thermal != "Normal", power.thermal != "Unavailable" { notes.append(power.thermal) }
        if power.lowPower == true { notes.append("Low Power Mode") }
        guard power.batteryPercent != nil || power.systemWatts != nil || !notes.isEmpty else { return nil }
        let stats = powerStats
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    cardTitle("Battery", symbol: power.charging ? "battery.100.bolt" : "battery.75")
                    if let percent = power.batteryPercent {
                        Text("\(percent)%").font(GraphStyle.figure).monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    Text(([batteryState].compactMap { $0 } + notes).joined(separator: " · "))
                        .font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                if let percent = power.batteryPercent {
                    meter(Double(percent) / 100, color: power.charging ? FrogStyle.good
                          : percent <= 10 ? FrogStyle.critical : percent <= 20 ? FrogStyle.warning : FrogStyle.accent)
                }
            }
            if !stats.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(stats, id: \.title) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.title).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(stat.value).font(FrogType.bodyMedium).monospacedDigit().lineLimit(1)
                                if let detail = stat.detail {
                                    Text(detail).font(FrogType.caption).foregroundStyle(stat.tint).lineLimit(1)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine).help(stat.help)
                    }
                }
            }
        })
    }

    /// The battery card before its first reading: the title, a bar where the charge goes, the empty meter and the
    /// two figures under it, each line as tall as the loaded card's.
    private var batterySkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    cardTitle("Battery", symbol: "battery.75")
                    FrogSkeleton(width: 40, height: 14).frame(height: 18)
                    Spacer(minLength: 4)
                }
                meter(0, color: FrogStyle.accent)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(["Mac draws", "Temperature"], id: \.self) { title in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text(title)).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        FrogSkeleton(width: 48, height: 12).frame(height: 16)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement().accessibilityLabel("Measuring")
    }

    private var batteryState: String? {
        let power = snapshot.power
        guard power.batteryPercent != nil else { return nil }
        if power.charging { return "Charging" }
        if power.source == "Battery" { return "On battery" }
        if power.fullyCharged { return "Fully charged" }
        return power.source == "Unavailable" ? nil : "Not charging"
    }

    private struct PowerStat {
        let title: String
        let value: String
        var detail: String?
        var tint = FrogStyle.muted
        let help: String
    }

    /// What the Mac draws, power into or out of the battery when it adds something, and its temperature.
    private var powerStats: [PowerStat] {
        let power = snapshot.power
        var stats: [PowerStat] = []
        if let watts = power.systemWatts {
            stats.append(.init(title: "Mac draws", value: Self.watts(watts),
                               help: "What the whole Mac uses right now, from the adapter or the battery."))
        }
        switch power.batteryFlow {
        case .charging(let watts):
            stats.append(.init(title: "Into battery", value: Self.watts(watts), help: "Power going into the battery."))
        case .drawing(let watts) where power.systemWatts == nil || power.source != "Battery":
            stats.append(.init(title: "From battery", value: Self.watts(watts), help: "Power coming out of the battery."))
        default: break
        }
        if let celsius = power.batteryCelsius {
            let state = SystemMonitorBatteryPower.temperatureState(celsius)
            stats.append(.init(title: "Temperature", value: "\(Int(celsius.rounded())) °C", detail: state,
                               tint: state == "Hot" ? FrogStyle.critical : state == "Warm" ? FrogStyle.warning : FrogStyle.muted,
                               help: "The battery's own temperature. Batteries age faster when they stay warm."))
        }
        return stats
    }

    private static func watts(_ value: Double) -> String {
        value < 0.1 ? "<0.1 W" : value.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    /// CPU or GPU: the dot of its line, the figure now or at the moment under the pointer, and a meter like memory's,
    /// filled in its level's colour.
    private func legend(_ title: String, color: Color, recorded: Double??, now: SystemMonitorMetric) -> some View {
        let fraction: Double? = recorded.map { $0 } ?? { if case .value(let value) = now { value } else { nil } }()
        let text = recorded.map { percent($0) } ?? percent(now)
        return GraphLegend(color: color, title: title) {
            if text == percent(.measuring) {
                MeasuringValue(wide: wide)
            } else {
                Text(text).font(text.hasSuffix("%") ? GraphStyle.legendValue(page: wide) : FrogType.small)
                    .monospacedDigit().frame(height: wide ? 34 : 24, alignment: .leading)
                // A meter is coloured by its level, like memory's and storage's: the accent until it runs high. The
                // dot beside the title names the line; a grey meter for the second line read as switched off.
                if let fraction { meter(fraction, color: FrogStyle.level(fraction, warning: 0.8, critical: 0.95)) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meter(_ value: Double, color: Color) -> some View {
        FrogMeter(fraction: value, tint: color)
    }

    private func percent(_ metric: SystemMonitorMetric) -> String {
        switch metric {
        case .measuring: return "Measuring…"
        case .unavailable: return "Unavailable"
        case .value(let fraction): return "\(Int((fraction * 100).rounded()))%"
        }
    }

    /// A recorded moment; one without a reading has nothing to show.
    private func percent(_ recorded: Double?) -> String {
        recorded.map { percent(.value($0)) } ?? "—"
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    /// Disk sizes in decimal units, as Finder shows them.
    private func diskBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A figure that has no reading yet: a quiet bar the width of a number, the one sign that it is being measured, over
/// its meter's empty track, so nothing moves when the reading arrives.
private struct MeasuringValue: View {
    let wide: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FrogSkeleton(width: wide ? 72 : 48, height: wide ? 22 : 16)
                .frame(height: wide ? 34 : 24, alignment: .leading)
            FrogMeter(fraction: 0, tint: FrogStyle.accent)
        }
        .accessibilityElement().accessibilityLabel("Measuring")
    }
}

/// A block of the overview: inset in the menu, a table surface on the page.
private struct OverviewCard: ViewModifier {
    let wide: Bool
    func body(content: Content) -> some View {
        // The same card on the page and in the popup, where it sits panelCardInset from the panel's edge.
        content.padding(FrogStyle.cardPadding).frame(maxWidth: .infinity, alignment: .topLeading).frogTableSurface()
    }
}

/// CPU and GPU over the recorded stretch: CPU as the smooth line over a fading fill with a live dot at its end,
/// GPU as a quieter second line, and a rule, dots and a chip under the pointer.
/// Equatable on what it draws, so a sample that changes only the cards beside it leaves it alone,
/// and bounded to `maxPoints` per series however long the history is.
struct SystemMonitorGraph: View, Equatable {
    static let maxPoints = 90

    /// The stretch the graph spans: always the whole history window, so the page, the popup, their axis and the
    /// page's subtitle all say the same 10 minutes. A fresh start draws from the right edge and fills in, as
    /// Activity Monitor's graphs do.
    static let span = SystemMonitor.historyWindow

    static func == (a: Self, b: Self) -> Bool {
        a.wide == b.wide && a.history.count == b.history.count && a.history.last?.time == b.history.last?.time
            && a.history.first?.time == b.history.first?.time && a.sample?.time == b.sample?.time
    }

    /// Averages neighbouring points of every run down to about `maxPoints` in all.
    /// Chunks are counted back from each run's newest point, which stays exact, so a new sample
    /// scrolls the line instead of regrouping every chunk.
    static func thinned(_ runs: [SystemMonitorRun]) -> [SystemMonitorRun] {
        let total = runs.reduce(0) { $0 + $1.points.count }
        guard total > maxPoints else { return runs }
        let step = Int((Double(total) / Double(maxPoints)).rounded(.up))
        return runs.map { run in
            var run = run
            let points = run.points
            guard let newest = points.last else { return run }
            var thinned = [newest]
            var end = points.count - 1
            while end > 0 {
                let chunk = points[max(0, end - step)..<end]
                let count = Double(chunk.count)
                thinned.append(SystemMonitorRun.Point(time: chunk[chunk.startIndex + chunk.count / 2].time,
                                                      offset: chunk.reduce(0) { $0 + $1.offset } / count,
                                                      value: chunk.reduce(0) { $0 + $1.value } / count))
                end -= step
            }
            run.points = thinned.reversed()
            return run
        }
    }

    let history: [SystemMonitorSample]
    @Binding var inspected: Double?
    let sample: SystemMonitorSample?
    let wide: Bool

    var body: some View {
        let cpu = Self.thinned(SystemMonitorRun.runs(history, pause: SystemMonitor.recordingPause, value: \.cpu))
        let gpu = Self.thinned(SystemMonitorRun.runs(history, pause: SystemMonitor.recordingPause, value: \.gpu))
        let window = Self.span
        Chart {
            FrogChartGrid(values: wide ? [0, 0.5, 1] : [0.5])
            ForEach(cpu) { run in
                ForEach(run.points) { point in
                    AreaMark(x: .value("Seconds", point.offset), y: .value("CPU", point.value), series: .value("Run", "CPU area \(run.id)"), stacking: .unstacked)
                        .interpolationMethod(.monotone).foregroundStyle(FrogChart.areaFill(FrogStyle.series))
                    LineMark(x: .value("Seconds", point.offset), y: .value("CPU", point.value), series: .value("Run", "CPU \(run.id)"))
                        .interpolationMethod(.monotone).lineStyle(FrogChart.line).foregroundStyle(FrogStyle.series)
                }
            }
            ForEach(gpu) { run in
                ForEach(run.points) { point in
                    LineMark(x: .value("Seconds", point.offset), y: .value("GPU", point.value), series: .value("Run", "GPU \(run.id)"))
                        .interpolationMethod(.monotone).lineStyle(FrogChart.secondaryLine).foregroundStyle(FrogStyle.seriesSecondary)
                }
            }
            if let point = cpu.last?.points.last, point.time == history.last?.time {
                FrogChartPoint(x: .value("Seconds", point.offset), y: .value("CPU", point.value), color: FrogStyle.series)
            }
            if let sample, let end = history.last?.time {
                let offset = sample.time.timeIntervalSince(end)
                FrogChartRule(x: .value("Seconds", offset))
                if let value = sample.cpu {
                    FrogChartPoint(x: .value("Seconds", offset), y: .value("CPU", value), color: FrogStyle.series)
                }
                if let value = sample.gpu {
                    FrogChartPoint(x: .value("Seconds", offset), y: .value("GPU", value), color: FrogStyle.seriesSecondary)
                }
            }
        }
        .chartXScale(domain: -window...0, range: .plotDimension(startPadding: 0, endPadding: FrogChart.endInset))
        .chartYScale(domain: 0...1, range: .plotDimension(startPadding: 6, endPadding: 6))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartXSelection(value: $inspected)
        .frogChartPlot(compact: !wide)
        .overlay(alignment: FrogChart.chipAlignment(pointerAt: pointer(window))) {
            if let sample, let end = history.last?.time { chip(sample, end: end) }
        }
        .accessibilityElement().accessibilityLabel("CPU and GPU history")
        .accessibilityValue(history.last.map { "CPU \(Self.percent($0.cpu)), GPU \(Self.percent($0.gpu))" } ?? "")
    }

    /// Where the inspected moment lies across the graph, 0 at its left edge and 1 at its right.
    private func pointer(_ window: TimeInterval) -> Double {
        guard let sample, let end = history.last?.time else { return 0 }
        return 1 + sample.time.timeIntervalSince(end) / window
    }

    private func chip(_ sample: SystemMonitorSample, end: Date) -> some View {
        FrogChartChip {
            HStack(spacing: 8) {
                Text("CPU \(Self.percent(sample.cpu))").foregroundStyle(FrogStyle.series)
                Text("GPU \(Self.percent(sample.gpu))")
                Text(GraphStyle.ago(end.timeIntervalSince(sample.time))).foregroundStyle(FrogStyle.muted)
            }
        }
    }

    private static func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "-" }
}
