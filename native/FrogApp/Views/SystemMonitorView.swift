import SwiftUI

enum SystemMonitorMenuTab: String, CaseIterable, Identifiable {
    case frog = "Frog"
    case system = "System"
    var id: Self { self }
}

struct SystemMonitorMenuSelector: View {
    @Binding var selection: SystemMonitorMenuTab

    var body: some View {
        Picker("Menu view", selection: $selection) {
            ForEach(SystemMonitorMenuTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 6).padding(.vertical, 8)
    }
}

struct SystemMonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        SystemMonitorOverview(snapshot: monitor.snapshot, cpuHistory: monitor.cpuHistory, gpuHistory: monitor.gpuHistory)
            .background(FeatureVisibility { monitor.setPresented($0) })
    }
}

/// Value-only content also makes synthetic native previews independent of the
/// user's machine, settings, power source and current workload.
struct SystemMonitorOverview: View {
    let snapshot: SystemMonitorSnapshot
    var cpuHistory: [Double?] = []
    var gpuHistory: [Double?] = []

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                usageCard("CPU", symbol: "cpu", metric: snapshot.cpu, history: cpuHistory)
                    .help("Busy time across all logical CPU cores, sampled every two seconds.")
                usageCard("GPU", symbol: "square.3.layers.3d", metric: snapshot.gpu, history: gpuHistory)
                    .help("Busiest GPU with a supported driver utilization statistic. Unavailable when the driver does not expose it.")
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("Disk", symbol: "internaldrive")
                if let capacity = snapshot.diskCapacity {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(capacity.available)).font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("free").foregroundStyle(FrogStyle.muted)
                        Spacer(minLength: 0)
                        Text("of \(bytes(capacity.total))").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }
                    meter(capacity.usedFraction)
                } else {
                    Text("Capacity unavailable").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                HStack {
                    Label(rate(snapshot.diskRead), systemImage: "arrow.down")
                    Spacer(minLength: 4)
                    Label(rate(snapshot.diskWrite), systemImage: "arrow.up")
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(FrogStyle.muted)
                Text("Startup volume · I/O across supported disks")
                    .font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
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
                    meter(Double(percent) / 100)
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
                detail("System wattage", value: "Unavailable")
                    .help("macOS does not provide a portable public total-system wattage API. Battery charge is not power consumption.")
            }.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))

            Text("Live while open · 2-second refresh")
                .font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
        }.padding(.horizontal, 6).padding(.bottom, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("System overview")
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
    }

    private func usageCard(_ title: String, symbol: String, metric: SystemMonitorMetric, history: [Double?]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(title, symbol: symbol)
            Text(percent(metric)).font(.system(size: metric.value == nil ? 11 : 21, weight: .semibold, design: .rounded))
                .monospacedDigit().frame(height: 25, alignment: .leading)
            SystemMonitorSparkline(values: metric.value == nil ? [] : history).stroke(FrogStyle.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(height: 18).background(alignment: .bottom) { Rectangle().fill(FrogStyle.muted.opacity(0.15)).frame(height: 1) }
                .accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
    }

    private func meter(_ value: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(FrogStyle.muted.opacity(0.15))
            Capsule().fill(FrogStyle.accent).frame(width: geometry.size.width * min(1, max(0, value)))
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

private struct SystemMonitorSparkline: Shape {
    let values: [Double?]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var connected = false
        for (index, value) in values.suffix(SystemMonitor.historyLimit).enumerated() {
            guard let value, value.isFinite else { connected = false; continue }
            let x = rect.width * Double(index) / Double(max(1, SystemMonitor.historyLimit - 1))
            let point = CGPoint(x: x, y: rect.height * (1 - min(1, max(0, value))))
            if connected { path.addLine(to: point) } else { path.move(to: point) }
            connected = true
        }
        return path
    }
}
