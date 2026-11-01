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
            FrogPageHeader(title: "System monitor")
            SystemMonitorView(monitor: monitor, presenter: .page, wide: true)
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FrogSection("Menu bar") {
            FrogRow("Show in the menu bar") {
                Toggle("Show in the menu bar", isOn: binding(\.menuBarItem)).labelsHidden().toggleStyle(.switch)
            }
            if settings.menuBarItem {
                MenuBarPreviewStrip(image: MenuBarMeter.image(SystemMonitorStatusItemController.face(Self.sample, settings: settings, dark: scheme == .dark)))
                    .padding(.vertical, 6)
                FrogRow("Readings") {
                    FrogDropdown(selection: binding(\.menuBarReadings), options: SystemMonitorSettings.Readings.allCases, width: 180) { $0.title }
                }
                FrogRow("Style") {
                    FrogDropdown(selection: binding(\.menuBarStyle), options: MenuBarMeterStyle.allCases, width: 180) { $0.title }
                }
                FrogRow("Colors") {
                    FrogDropdown(selection: binding(\.menuBarPalette), options: MenuBarMeterPalette.allCases, width: 180) { $0.title }
                }
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
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    legend("CPU", color: FrogStyle.series, text: sample.map { percent($0.cpu) } ?? percent(snapshot.cpu))
                        .help("Busy time across all CPU cores.")
                    legend("GPU", color: FrogStyle.seriesSecondary, text: sample.map { percent($0.gpu) } ?? percent(snapshot.gpu))
                        .help("The busiest GPU, when its driver reports it.")
                    memory(sample)
                }
                SystemMonitorGraph(history: history, inspected: $inspected, sample: sample).frame(height: wide ? 150 : 54)
                GraphAxis(leading: GraphStyle.ago(SystemMonitor.historyWindow), trailing: "Now",
                          center: sample.flatMap { sample in history.last.map { GraphStyle.ago($0.time.timeIntervalSince(sample.time)) } })
            }.modifier(OverviewCard(wide: wide))
            if let storage = snapshot.storage {
                storageLine(storage).modifier(OverviewCard(wide: wide))
            }
            if let power = powerLine {
                power.modifier(OverviewCard(wide: wide))
            }
        }.padding(.horizontal, wide ? 0 : 2).padding(.bottom, wide ? 0 : 4)
            .accessibilityElement(children: .contain).accessibilityLabel("System overview")
    }

    /// Memory now, or as recorded at the moment under the pointer.
    private func memory(_ sample: SystemMonitorSample?) -> some View {
        let fraction = sample != nil ? sample?.memory : snapshot.memory?.fraction
        return VStack(alignment: .leading, spacing: 3) {
            Text("Memory").font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
            if let fraction {
                Text(percent(.value(fraction))).font(GraphStyle.legendValue(page: wide)).monospacedDigit()
                    .frame(height: wide ? 34 : 24, alignment: .leading)
                meter(fraction, color: FrogStyle.level(fraction, warning: 0.8, critical: 0.92))
            } else if sample != nil {
                Text("—").font(FrogType.small).frame(height: wide ? 34 : 24, alignment: .leading)
            } else {
                Text(percent(.measuring)).font(FrogType.small).frame(height: wide ? 34 : 24, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .help(snapshot.memory.map { "\(bytes($0.used)) of \(bytes($0.total)) in use" } ?? "")
    }

    /// Free space on the startup volume, with a meter of what is used.
    private func storageLine(_ storage: SystemMonitorStorage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("Storage", systemImage: "internaldrive").font(FrogType.label)
                Text(diskBytes(storage.available)).font(GraphStyle.figure).monospacedDigit()
                Text("free").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                Spacer(minLength: 4)
                Text("of \(diskBytes(storage.total))").font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }
            meter(storage.usedFraction, color: FrogStyle.level(storage.usedFraction, warning: 0.85, critical: 0.95))
        }.accessibilityElement(children: .combine)
            .help("Space free on the startup disk, counting what macOS can clear, as Finder shows it.")
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
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label("Battery", systemImage: power.charging ? "battery.100.bolt" : "battery.75").font(FrogType.label)
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

    private func legend(_ title: String, color: Color, text: String) -> some View {
        GraphLegend(color: color, title: title) {
            Text(text).font(text.hasSuffix("%") ? GraphStyle.legendValue(page: wide) : FrogType.small)
                .monospacedDigit().frame(height: wide ? 34 : 24, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meter(_ value: Double, color: Color) -> some View {
        GeometryReader { geometry in
            Capsule().fill(FrogStyle.muted.opacity(0.15))
            Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, value)))
        }.frame(height: 4).accessibilityHidden(true)
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

/// A block of the overview: inset in the menu, a table surface on the page.
private struct OverviewCard: ViewModifier {
    let wide: Bool
    func body(content: Content) -> some View {
        if wide {
            content.padding(FrogStyle.cardPadding).frame(maxWidth: .infinity, alignment: .topLeading).frogTableSurface()
        } else {
            content.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
        }
    }
}

/// CPU and GPU over the recorded stretch: CPU as the filled line, GPU as a second line.
private struct SystemMonitorGraph: View {
    let history: [SystemMonitorSample]
    @Binding var inspected: Double?
    let sample: SystemMonitorSample?

    var body: some View {
        let cpu = SystemMonitorRun.runs(history, pause: SystemMonitor.recordingPause, value: \.cpu)
        let gpu = SystemMonitorRun.runs(history, pause: SystemMonitor.recordingPause, value: \.gpu)
        Chart {
            ForEach(cpu) { run in
                ForEach(run.points) { point in
                    AreaMark(x: .value("Seconds", point.offset), y: .value("CPU", point.value), series: .value("Run", run.id), stacking: .unstacked)
                        .interpolationMethod(.monotone).foregroundStyle(GraphStyle.fill(FrogStyle.series))
                    LineMark(x: .value("Seconds", point.offset), y: .value("CPU", point.value), series: .value("Run", "CPU \(run.id)"))
                        .interpolationMethod(.monotone).lineStyle(GraphStyle.line).foregroundStyle(FrogStyle.series)
                }
            }
            ForEach(gpu) { run in
                ForEach(run.points) { point in
                    LineMark(x: .value("Seconds", point.offset), y: .value("GPU", point.value), series: .value("Run", "GPU \(run.id)"))
                        .interpolationMethod(.monotone).lineStyle(GraphStyle.line).foregroundStyle(FrogStyle.seriesSecondary)
                }
            }
            if let sample, let end = history.last?.time {
                let offset = sample.time.timeIntervalSince(end)
                RuleMark(x: .value("Seconds", offset)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(FrogStyle.muted.opacity(0.45))
                if let value = sample.cpu {
                    PointMark(x: .value("Seconds", offset), y: .value("CPU", value)).symbolSize(22).foregroundStyle(FrogStyle.series)
                }
                if let value = sample.gpu {
                    PointMark(x: .value("Seconds", offset), y: .value("GPU", value)).symbolSize(22).foregroundStyle(FrogStyle.seriesSecondary)
                }
            }
        }
        .chartXScale(domain: -SystemMonitor.historyWindow...0)
        .chartYScale(domain: 0...1, range: .plotDimension(startPadding: 1, endPadding: 1))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartXSelection(value: $inspected)
        .accessibilityHidden(true)
    }
}
