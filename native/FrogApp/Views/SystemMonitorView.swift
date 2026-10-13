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

    var body: some View {
        SystemMonitorOverview(snapshot: monitor.snapshot, history: monitor.history)
            .background(FeatureVisibility { monitor.setPresented($0) })
    }
}

/// Value-only content also makes synthetic native previews independent of the
/// user's machine, settings, power source and current workload.
struct SystemMonitorOverview: View {
    let snapshot: SystemMonitorSnapshot
    var history: [SystemMonitorSample] = []
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
                        .help("Busy time across all logical CPU cores. Recorded while System monitor is on, also with this view closed.")
                    usage("GPU", color: FrogStyle.seriesSecondary, text: sample.map { percent($0.gpu) } ?? percent(snapshot.gpu))
                        .help("Busiest GPU with a supported driver utilization statistic. Unavailable when the driver does not expose it.")
                }.overlay(alignment: .topTrailing) {
                    if let sample, let end = history.last?.time {
                        Text(GraphStyle.ago(end.timeIntervalSince(sample.time)))
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }
                }
                SystemMonitorGraph(history: history, inspected: $inspected, sample: sample).frame(height: 54)
                GraphAxis(leading: GraphStyle.ago(SystemMonitor.historyWindow), trailing: "Now")
            }.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                heading("Disk", symbol: "internaldrive")
                if let capacity = snapshot.diskCapacity {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(capacity.available)).font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("free").foregroundStyle(FrogStyle.muted)
                        Spacer(minLength: 0)
                        Text("of \(bytes(capacity.total))").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }
                    meter(capacity.usedFraction, color: FrogStyle.level(capacity.usedFraction, warning: 0.85, critical: 0.95))
                } else {
                    Text("Capacity unavailable").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                HStack {
                    Label(rate(snapshot.diskRead), systemImage: "arrow.down")
                    Spacer(minLength: 4)
                    Label(rate(snapshot.diskWrite), systemImage: "arrow.up")
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(FrogStyle.muted)
            }.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    heading("Power", symbol: "bolt")
                    Spacer(minLength: 4)
                    Text(snapshot.power.source).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
                if let percent = snapshot.power.batteryPercent {
                    HStack {
                        Text("\(percent)%").font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(snapshot.power.charging ? "Charging" : "Battery charge")
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        Spacer()
                    }
                    meter(Double(percent) / 100, color: snapshot.power.charging ? FrogStyle.good
                        : percent <= 10 ? FrogStyle.critical : percent <= 20 ? FrogStyle.warning : FrogStyle.accent)
                }
                if let flow = snapshot.power.batteryFlow {
                    detail(flow.title, value: flow.watts < 0.1 ? "<0.1 W" : flow.watts.formatted(.number.precision(.fractionLength(1))) + " W")
                        .help("Measured battery-terminal voltage × current. Battery flow is not total-system or adapter power; draw can occur while plugged in.")
                } else {
                    detail("Battery power", value: "Unavailable")
                        .help("Battery voltage or signed current is missing, zero, inconsistent or unsupported. Desktop Macs have no battery flow reading.")
                }
                detail("Thermal state", value: snapshot.power.thermal)
                detail("Low Power Mode", value: snapshot.power.lowPower.map { $0 ? "On" : "Off" } ?? "Measuring…")
            }.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
        }.padding(.horizontal, 6).padding(.bottom, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("System overview")
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
    }

    private func usage(_ title: String, color: Color, text: String) -> some View {
        GraphLegend(color: color, title: title) {
            Text(text).font(.system(size: text.hasSuffix("%") ? 20 : 11, weight: .semibold, design: .rounded))
                .monospacedDigit().frame(height: 24, alignment: .leading)
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
        }.font(.system(size: 10))
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
