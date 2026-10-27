import Charts
import SwiftUI

enum SystemMonitorMenuTab: String, CaseIterable, Identifiable {
    case frog = "Frog"
    case system = "System"
    var id: Self { self }
}

struct SystemMonitorMenuSelector: View {
    @Binding var selection: SystemMonitorMenuTab

    var body: some View {
        CompactSegments(values: SystemMonitorMenuTab.allCases, selected: selection, width: 132, compact: true, title: { $0.rawValue }) { selection = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel("Menu view")
    }
}

struct SystemMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    let presenter: SystemMonitorPresenter

    var body: some View {
        SystemMonitorOverview(snapshot: monitor.snapshot, history: monitor.history)
            .background(FeatureVisibility { monitor.setPresented($0, for: presenter) })
    }
}

/// System monitor's own page: the overview at full width, then the menu-bar item's settings.
struct SystemMonitorPage: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        PageScroll {
            PageHeader(title: "System monitor")
            SystemMonitorOverview(snapshot: monitor.snapshot, history: monitor.history, wide: true)
            SystemMonitorMenuBarSettings()
        }.background(FeatureVisibility { monitor.setPresented($0, for: .page) })
    }
}

/// Value-only content also makes synthetic native previews independent of the
/// user's machine, settings, power source and current workload.
struct SystemMonitorOverview: View {
    let snapshot: SystemMonitorSnapshot
    var history: [SystemMonitorSample] = []
    /// The page's layout: a taller graph, Disk and Power side by side.
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
                    usage("CPU", color: FrogStyle.series, text: sample.map { percent($0.cpu) } ?? percent(snapshot.cpu))
                        .help("Busy time across all CPU cores.")
                    usage("GPU", color: FrogStyle.seriesSecondary, text: sample.map { percent($0.gpu) } ?? percent(snapshot.gpu))
                        .help("The busiest GPU, when its driver reports it.")
                }.overlay(alignment: .topTrailing) {
                    if let sample, let end = history.last?.time {
                        Text(GraphStyle.ago(end.timeIntervalSince(sample.time)))
                            .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    }
                }
                SystemMonitorGraph(history: history, inspected: $inspected, sample: sample).frame(height: wide ? 150 : 54)
                GraphAxis(leading: GraphStyle.ago(SystemMonitor.historyWindow), trailing: "Now")
            }.modifier(card)
            let cards = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
            cards {
            VStack(alignment: .leading, spacing: 6) {
                heading("Disk", symbol: "internaldrive")
                if let capacity = snapshot.diskCapacity {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(capacity.available)).font(GraphStyle.figure).monospacedDigit()
                        Text("free").foregroundStyle(FrogStyle.muted)
                        Spacer(minLength: 0)
                        Text("of \(bytes(capacity.total))").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    }
                    meter(capacity.usedFraction, color: FrogStyle.level(capacity.usedFraction, warning: 0.85, critical: 0.95))
                } else {
                    Text("Capacity unavailable").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }
                HStack {
                    Label(rate(snapshot.diskRead), systemImage: "arrow.down")
                    Spacer(minLength: 4)
                    Label(rate(snapshot.diskWrite), systemImage: "arrow.up")
                }.font(FrogType.caption).monospacedDigit().foregroundStyle(FrogStyle.muted)
            }.modifier(card)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    heading("Power", symbol: "bolt")
                    Spacer(minLength: 4)
                    Text(snapshot.power.source).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                }
                if let percent = snapshot.power.batteryPercent {
                    HStack {
                        Text("\(percent)%").font(GraphStyle.figure).monospacedDigit()
                        Text(snapshot.power.charging ? "Charging" : "Battery charge")
                            .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        Spacer()
                    }
                    meter(Double(percent) / 100, color: snapshot.power.charging ? FrogStyle.good
                        : percent <= 10 ? FrogStyle.critical : percent <= 20 ? FrogStyle.warning : FrogStyle.accent)
                }
                if let flow = snapshot.power.batteryFlow {
                    detail(flow.title, value: flow.watts < 0.1 ? "<0.1 W" : flow.watts.formatted(.number.precision(.fractionLength(1))) + " W")
                        .help("Power into or out of the battery, not the whole Mac.")
                } else {
                    detail("Battery power", value: "Unavailable")
                }
                detail("Thermal state", value: snapshot.power.thermal)
                detail("Low Power Mode", value: snapshot.power.lowPower.map { $0 ? "On" : "Off" } ?? "Measuring…")
            }.modifier(card)
            }.fixedSize(horizontal: false, vertical: wide)
        }.padding(.horizontal, wide ? 0 : 2).padding(.bottom, wide ? 0 : 4)
            .accessibilityElement(children: .contain).accessibilityLabel("System overview")
    }

    private var card: OverviewCard { OverviewCard(wide: wide) }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(FrogType.label)
    }

    private func usage(_ title: String, color: Color, text: String) -> some View {
        GraphLegend(color: color, title: title) {
            Text(text).font(text.hasSuffix("%") ? GraphStyle.legendValue(page: wide) : FrogType.small)
                .monospacedDigit().frame(height: wide ? 34 : 24, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meter(_ value: Double, color: Color = FrogStyle.accent) -> some View {
        GeometryReader { geometry in
            Capsule().fill(FrogStyle.muted.opacity(0.15))
            Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, value)))
        }.frame(height: 4).accessibilityHidden(true)
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(FrogStyle.muted)
            Spacer(minLength: 6)
            Text(value)
        }.font(FrogType.caption)
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
        ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
    }

    private func rate(_ metric: SystemMonitorMetric) -> String {
        switch metric {
        case .measuring: return "Measuring…"
        case .unavailable: return "Unavailable"
        case .value(let value): return bytes(Int64(min(Double(Int64.max / 2), max(0, value)))) + "/s"
        }
    }
}

/// A block of the overview: inset in the menu, a table surface filling its share of the row on the page.
private struct OverviewCard: ViewModifier {
    let wide: Bool
    func body(content: Content) -> some View {
        if wide {
            content.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).frogTableSurface()
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
        .background(alignment: .bottom) { Rectangle().fill(FrogStyle.muted.opacity(0.15)).frame(height: 1) }
        .accessibilityHidden(true)
    }
}
