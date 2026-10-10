import Foundation

enum SystemMonitorMetric: Equatable, Sendable {
    case measuring
    case unavailable
    case value(Double)

    var value: Double? {
        if case .value(let value) = self { return value }
        return nil
    }
}

struct SystemMonitorSnapshot: Equatable, Sendable {
    var cpu: SystemMonitorMetric = .measuring
    var gpu: SystemMonitorMetric = .measuring
    var diskCapacity: SystemMonitorCapacity?
    var diskRead: SystemMonitorMetric = .measuring
    var diskWrite: SystemMonitorMetric = .measuring
    var power = SystemMonitorPower()
}

struct SystemMonitorCapacity: Equatable, Sendable {
    let total: Int64
    let available: Int64
    var usedFraction: Double { total > 0 ? Double(total - available) / Double(total) : 0 }
}

struct SystemMonitorPower: Equatable, Sendable {
    var source = "Unavailable"
    var batteryPercent: Int?
    var charging = false
    var thermal = "Unavailable"
    var lowPower: Bool?
    var batteryFlow: SystemMonitorBatteryFlow?
}

/// Counter math is independent of OS access so resets, hot-plug and sleep gaps
/// cannot accidentally become huge usage spikes or a fabricated zero reading.
enum SystemMonitorDelta {
    struct CPU: Equatable, Sendable {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    struct Disk: Equatable, Sendable {
        let read: UInt64
        let written: UInt64
    }

    static func cpu(previous: [CPU], current: [CPU], elapsed: TimeInterval) -> Double? {
        guard validInterval(elapsed), !current.isEmpty, previous.count == current.count else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for (old, new) in zip(previous, current) {
            // The kernel exposes unsigned 32-bit tick counters. Subtraction must
            // allow wraparound, but not a counter reset/hot-plug discontinuity.
            let user = UInt64(new.user &- old.user)
            let system = UInt64(new.system &- old.system)
            let idle = UInt64(new.idle &- old.idle)
            let nice = UInt64(new.nice &- old.nice)
            let sum = user + system + idle + nice
            guard sum < 1_000_000 else { return nil }
            busy += user + system + nice
            total += sum
        }
        return total > 0 ? Double(busy) / Double(total) : nil
    }

    static func disk(previous: [UInt64: Disk], current: [UInt64: Disk], elapsed: TimeInterval) -> (read: Double, write: Double)? {
        guard validInterval(elapsed), !current.isEmpty, previous.keys.sorted() == current.keys.sorted() else { return nil }
        var read = 0.0
        var write = 0.0
        for (id, next) in current {
            guard let old = previous[id], next.read >= old.read, next.written >= old.written else { return nil }
            read += Double(next.read - old.read)
            write += Double(next.written - old.written)
        }
        return (read / elapsed, write / elapsed)
    }

    static func gpu(percent: Double) -> Double? {
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent / 100
    }

    private static func validInterval(_ elapsed: TimeInterval) -> Bool {
        elapsed.isFinite && elapsed > 0 && elapsed <= 10
    }
}
