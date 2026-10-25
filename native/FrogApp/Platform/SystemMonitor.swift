import Combine
import Foundation

protocol SystemMonitorSampling: Sendable {
    /// `reset` drops the baselines, so time before monitoring began is not read as usage.
    /// `full` adds disk and power to the CPU and GPU readings.
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemMonitorSnapshot()
    /// The graph's samples, oldest first. Published only while shown, so recording out of
    /// sight does not redraw a menu that stays mounted after it closes.
    @Published private(set) var history: [SystemMonitorSample] = []
    /// Not published: no view reads it, and hiding the view must not publish while it is taken down.
    var isSampling: Bool { task != nil }
    /// The newest CPU and GPU reading, also while the overview is out of sight, for the menu-bar
    /// item. A subject rather than `@Published`, so the mounted menu does not redraw with every
    /// background sample. Nil while monitoring is off.
    let readings = CurrentValueSubject<SystemMonitorReading?, Never>(nil)

    private let sampler: any SystemMonitorSampling
    private let interval: Duration
    private let backgroundInterval: Duration
    private let now: @MainActor () -> Date
    private var recorded: [SystemMonitorSample] = []
    private var latest: (cpu: SystemMonitorMetric, gpu: SystemMonitorMetric)?
    private var enabled = false
    private var presented = false
    /// A menu-bar item shows the readings, so they are taken as often as for the open overview.
    private var liveReadout = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    /// The stretch of time the graph covers.
    nonisolated static let historyWindow: TimeInterval = 600
    nonisolated static let historyLimit = 600
    /// Samples further apart than this were not recorded back to back.
    nonisolated static let recordingPause: TimeInterval = 30

    init(sampler: any SystemMonitorSampling = NativeSystemMonitorSampler(), interval: Duration = .seconds(2),
         backgroundInterval: Duration = .seconds(5), now: @escaping @MainActor () -> Date = { Date() }) {
        self.sampler = sampler
        self.interval = interval
        self.backgroundInterval = backgroundInterval
        self.now = now
    }

    /// While enabled, CPU and GPU are recorded whether or not the view is open.
    func configure(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled { run(reset: true) } else { cancel() }
    }

    func setPresented(_ presented: Bool) {
        guard self.presented != presented else { return }
        self.presented = presented
        guard enabled else { return }
        if presented {
            // What was recorded out of sight is there on the first frame.
            if let latest { snapshot.cpu = latest.cpu; snapshot.gpu = latest.gpu }
            history = recorded
        }
        run(reset: false)
    }

    /// While a menu-bar item shows CPU and GPU, out-of-sight readings come as often as shown ones.
    func setLiveReadout(_ live: Bool) {
        guard liveReadout != live else { return }
        liveReadout = live
        if enabled, !presented { run(reset: false) }
    }

    func stop() {
        enabled = false
        presented = false
        cancel()
    }

    private func run(reset: Bool) {
        task?.cancel()
        generation = UUID()
        let token = generation
        let sampler = sampler
        let full = presented
        let pause = full || liveReadout ? interval : backgroundInterval
        // Closing the view follows a sample taken a moment ago; opening it wants one now.
        let startsPaused = !full && !reset
        // No synchronous OS reads occur here or during menu construction.
        task = Task(priority: .utility) { [weak self] in
            var reset = reset
            var paused = startsPaused
            while !Task.isCancelled {
                if paused {
                    do { try await Task.sleep(for: pause, tolerance: full ? nil : pause / 5) } catch { return }
                }
                paused = true
                let reading = await sampler.sample(reset: reset, full: full)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.record(reading, full: full)
                reset = false
            }
        }
    }

    private func record(_ reading: SystemMonitorSnapshot, full: Bool) {
        let time = now()
        // A clock set back must not leave samples ahead of the newest one.
        recorded.removeAll { $0.time < time.addingTimeInterval(-Self.historyWindow) || $0.time >= time }
        recorded.append(.init(time: time, cpu: reading.cpu.value, gpu: reading.gpu.value))
        if recorded.count > Self.historyLimit { recorded.removeFirst(recorded.count - Self.historyLimit) }
        latest = (reading.cpu, reading.gpu)
        let live = SystemMonitorReading(cpu: reading.cpu, gpu: reading.gpu)
        if readings.value != live { readings.send(live) }
        guard full else { return }
        snapshot = reading
        history = recorded
    }

    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        snapshot = SystemMonitorSnapshot()
        history = []
        recorded = []
        latest = nil
        if readings.value != nil { readings.send(nil) }
    }

    deinit { task?.cancel() }
}
