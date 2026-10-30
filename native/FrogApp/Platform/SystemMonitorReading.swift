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
    var memory: SystemMonitorMemory?
    var power = SystemMonitorPower()
}

/// Memory in use as Activity Monitor counts it: app memory, wired and compressed.
struct SystemMonitorMemory: Equatable, Sendable {
    let used: Int64
    let total: Int64
    var fraction: Double { total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0 }
}

/// The newest load, as the menu-bar item shows it.
struct SystemMonitorReading: Equatable, Sendable {
    let cpu: SystemMonitorMetric
    let gpu: SystemMonitorMetric
    var memory: SystemMonitorMetric = .measuring
}

/// One recorded moment of the CPU/GPU graph. A missing reading stays a gap.
struct SystemMonitorSample: Equatable, Sendable {
    let time: Date
    let cpu: Double?
    let gpu: Double?
}

/// A stretch of consecutive readings; the line breaks where one is missing or recording paused.
struct SystemMonitorRun: Identifiable, Equatable {
    struct Point: Identifiable, Equatable {
        let time: Date
        /// Seconds from the newest sample, zero or less.
        let offset: Double
        let value: Double
        var id: Date { time }
    }
    let id: Int
    var points: [Point]

    static func runs(_ history: [SystemMonitorSample], pause: TimeInterval,
                     value: (SystemMonitorSample) -> Double?) -> [SystemMonitorRun] {
        guard let end = history.last?.time else { return [] }
        var runs: [SystemMonitorRun] = []
        var previous: Date?
        for sample in history {
            guard let reading = value(sample), reading.isFinite else { previous = nil; continue }
            let point = Point(time: sample.time, offset: sample.time.timeIntervalSince(end), value: min(1, max(0, reading)))
            if let previous, sample.time.timeIntervalSince(previous) <= pause {
                runs[runs.count - 1].points.append(point)
            } else {
                runs.append(.init(id: runs.count, points: [point]))
            }
            previous = sample.time
        }
        return runs
    }
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

    static func cpu(previous: [CPU], current: [CPU], elapsed: TimeInterval) -> Double? {
        // A background wake-up can arrive late. The busy share of a longer stretch is still a
        // true average, which a byte rate across a pause is not.
        guard validInterval(elapsed, limit: 30), !current.isEmpty, previous.count == current.count else { return nil }
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

    static func gpu(percent: Double) -> Double? {
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent / 100
    }

    private static func validInterval(_ elapsed: TimeInterval, limit: TimeInterval) -> Bool {
        elapsed.isFinite && elapsed > 0 && elapsed <= limit
    }
}

/// CPU load between successive tick readings. Ticks step in hundredths of a second per core, so
/// a reading asked for a moment after the last one repeats it instead of measuring a sliver.
struct SystemMonitorCPUMeter {
    static let minimumInterval: TimeInterval = 0.5
    private var ticks: [SystemMonitorDelta.CPU]?
    private var time: TimeInterval?
    private var last: Double?

    mutating func reset() { ticks = nil; time = nil; last = nil }

    mutating func reading(_ current: [SystemMonitorDelta.CPU]?, at now: TimeInterval) -> SystemMonitorMetric {
        guard let current else { reset(); return .unavailable }
        if let time, ticks != nil, now >= time, now - time < Self.minimumInterval {
            return last.map(SystemMonitorMetric.value) ?? .measuring
        }
        if let ticks, let time {
            last = SystemMonitorDelta.cpu(previous: ticks, current: current, elapsed: now - time)
        }
        ticks = current
        time = now
        return last.map(SystemMonitorMetric.value) ?? .measuring
    }
}
