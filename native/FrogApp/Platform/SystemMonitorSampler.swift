import Darwin
import Foundation
import IOKit

/// Actor-isolated native reads run on the cooperative executor, never the UI
/// thread. No process inventory, subprocesses, privileged helpers or disk scans.
actor NativeSystemMonitorSampler: SystemMonitorSampling {
    private var cpu = SystemMonitorCPUMeter()

    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        if reset { cpu.reset() }
        guard !Task.isCancelled else { return SystemMonitorSnapshot() }
        var result = SystemMonitorSnapshot()
        result.cpu = cpu.reading(readCPU(), at: ProcessInfo.processInfo.systemUptime)
        guard !Task.isCancelled else { return result }
        result.gpu = readGPU().map(SystemMonitorMetric.value) ?? .unavailable
        result.memory = Self.readMemory()
        // Power is shown, not graphed, so only a visible overview reads it.
        guard full, !Task.isCancelled else { return result }
        result.power = readPower()
        return result
    }

    /// Memory in use as Activity Monitor counts it: app memory, wired and compressed.
    static func readMemory() -> SystemMonitorMemory? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Int64(info.internal_page_count) - Int64(info.purgeable_count) + Int64(info.wire_count) + Int64(info.compressor_page_count)
        return SystemMonitorMemory(used: max(0, pages) * Int64(getpagesize()), total: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    private func readCPU() -> [SystemMonitorDelta.CPU]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var processors: natural_t = 0
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let stride = Int(CPU_STATE_MAX)
        guard processors > 0, processors <= 4096, Int(count) >= Int(processors) * stride else { return nil }
        return (0..<Int(processors)).map { core in
            let offset = core * stride
            return SystemMonitorDelta.CPU(
                user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
        }
    }

    private func readGPU() -> Double? {
        // This optional driver statistic exists on some Intel and Apple Silicon
        // GPUs. Other counters have different units; never guess their scale.
        var values: [Double] = []
        withServices("IOAccelerator", limit: 16) { service in
            guard let stats = property(service, key: "PerformanceStatistics") as? [String: Any],
                  let number = stats["Device Utilization %"] as? NSNumber,
                  let value = SystemMonitorDelta.gpu(percent: number.doubleValue) else { return }
            values.append(value)
        }
        // Multi-GPU systems show the busiest supported device, not a made-up sum.
        return values.max()
    }

    private func readPower() -> SystemMonitorPower {
        var result = SystemMonitorPower()
        result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermal = "Normal"
        case .fair: result.thermal = "Warm"
        case .serious: result.thermal = "Serious"
        case .critical: result.thermal = "Critical"
        @unknown default: result.thermal = "Unavailable"
        }
        result.batteryFlow = readBatteryFlow()
        guard let sources = PowerSources.read() else { return result }
        switch sources.source {
        case .adapter: result.source = "Power adapter"
        case .battery: result.source = "Battery"
        case .ups: result.source = "UPS"
        case nil: break
        }
        result.batteryPercent = sources.batteryPercent
        result.charging = sources.charging
        return result
    }

    private func readBatteryFlow() -> SystemMonitorBatteryFlow? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        // One registry snapshot keeps voltage/current and connection flags
        // together. Retain only the validated flow, not battery metadata.
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(battery, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return SystemMonitorBatteryPower.reading(properties: values)
    }

    private func property(_ service: io_service_t, key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func withServices(_ name: String, limit: Int, read: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        for _ in 0..<limit {
            guard !Task.isCancelled else { return }
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return }
            read(service)
            IOObjectRelease(service)
        }
    }
}
