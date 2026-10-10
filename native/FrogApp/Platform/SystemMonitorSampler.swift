import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Actor-isolated native reads run on the cooperative executor, never the UI
/// thread. No process inventory, subprocesses, privileged helpers or disk scans.
actor NativeSystemMonitorSampler: SystemMonitorSampling {
    private var previousCPU: [SystemMonitorDelta.CPU]?
    private var previousDisk: [UInt64: SystemMonitorDelta.Disk]?
    private var previousTime: TimeInterval?
    private var capacity: SystemMonitorCapacity?
    private var capacityTime: TimeInterval?

    func sample(reset: Bool) async -> SystemMonitorSnapshot {
        if reset {
            previousCPU = nil
            previousDisk = nil
            previousTime = nil
        }
        guard !Task.isCancelled else { return SystemMonitorSnapshot() }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 } ?? 0
        var result = SystemMonitorSnapshot()
        let cpu = readCPU()
        if let cpu {
            if let previousCPU, let usage = SystemMonitorDelta.cpu(previous: previousCPU, current: cpu, elapsed: elapsed) {
                result.cpu = .value(usage)
            }
        } else { result.cpu = .unavailable }
        previousCPU = cpu
        guard !Task.isCancelled else { return result }
        result.gpu = readGPU().map(SystemMonitorMetric.value) ?? .unavailable
        let disks = readDiskCounters()
        if let disks {
            if let previousDisk, let rates = SystemMonitorDelta.disk(previous: previousDisk, current: disks, elapsed: elapsed) {
                result.diskRead = .value(rates.read)
                result.diskWrite = .value(rates.write)
            }
        } else {
            result.diskRead = .unavailable
            result.diskWrite = .unavailable
        }
        previousDisk = disks
        previousTime = now
        guard !Task.isCancelled else { return result }
        if capacityTime == nil || now - (capacityTime ?? 0) >= 30 {
            capacity = readCapacity()
            capacityTime = now
        }
        result.diskCapacity = capacity
        result.power = readPower()
        return result
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

    private func readDiskCounters() -> [UInt64: SystemMonitorDelta.Disk]? {
        var counters: [UInt64: SystemMonitorDelta.Disk] = [:]
        withServices("IOBlockStorageDriver", limit: 128) { service in
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let stats = property(service, key: "Statistics") as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber,
                  let written = stats["Bytes (Write)"] as? NSNumber,
                  read.doubleValue >= 0, written.doubleValue >= 0 else { return }
            counters[id] = .init(read: read.uint64Value, written: written.uint64Value)
        }
        return counters.isEmpty ? nil : counters
    }

    private func readCapacity() -> SystemMonitorCapacity? {
        // The writable startup volume, not the read-only sealed OS snapshot.
        let url = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
              total > 0, free >= 0 else { return nil }
        return SystemMonitorCapacity(total: Int64(total), available: Int64(min(total, free)))
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
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return result }
        if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            switch source {
            case kIOPSACPowerValue: result.source = "Power adapter"
            case kIOPSBatteryPowerValue: result.source = "Battery"
            case kIOPMUPSPowerKey: result.source = "UPS"
            default: break
            }
        }
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int,
                      current >= 0, maximum > 0, current <= maximum else { continue }
                result.batteryPercent = Int((Double(current) / Double(maximum) * 100).rounded())
                result.charging = description[kIOPSIsChargingKey] as? Bool ?? false
                break
            }
        }
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
