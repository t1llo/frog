import SwiftUI
import Darwin

struct MemorySparkline: View {
    var showUsage = false
    @State private var samples: [Double] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        if showUsage {
            HStack {
                Label("Frog RAM", systemImage: "memorychip").foregroundStyle(FrogStyle.muted)
                Spacer()
                Text(samples.isEmpty ? "—" : ByteCountFormatter.string(fromByteCount: Int64(samples.last ?? 0), countStyle: .memory))
                    .monospacedDigit().foregroundStyle(FrogStyle.ink)
            }.font(.system(size: 11))
        }
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let maximum = max(samples.max() ?? 1, 64 * 1024 * 1024)
            var line = Path()
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: Double(index) / Double(samples.count - 1) * size.width, y: size.height * (1 - value / maximum))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(FrogStyle.accent.opacity(0.65)), lineWidth: 1)
        }.frame(maxWidth: .infinity)
        }
            .help("Frog memory: \(ByteCountFormatter.string(fromByteCount: Int64(samples.last ?? 0), countStyle: .memory))")
            .accessibilityLabel("Frog memory usage")
            .task {
                while !Task.isCancelled {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
                    }
                    if result == KERN_SUCCESS { samples.append(Double(info.phys_footprint)); samples = Array(samples.suffix(24)) }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
    }
}
