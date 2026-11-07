import FrogCore
import Combine
import Foundation

/// The places that show the overview. Each says for itself whether it is on screen,
/// so one closing leaves the others live.
enum SystemMonitorPresenter: Hashable { case frogMenu, statusPopup, page }

protocol SystemMonitorSampling: Sendable {
    /// `reset` drops the baselines, so time before monitoring began is not read as usage.
    /// `full` adds power to the CPU, GPU and memory readings.
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot
}

/// Samples every two seconds while something shows the readings: an open overview or a menu-bar
/// item. With recording on, it also keeps a lighter reading every few seconds out of sight, so an
/// overview opens on the last ten minutes instead of an empty graph.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemMonitorSnapshot()
    /// The graph's samples, oldest first. Published only while an overview is shown.
    @Published private(set) var history: [SystemMonitorSample] = []
    /// Not published: no view reads it, and hiding the view must not publish while it is taken down.
    var isSampling: Bool { task != nil }
    /// The newest reading, for the menu-bar item. A subject rather than `@Published`, so a mounted
    /// overview does not redraw for samples taken only for the item. Nil while nothing samples.
    let readings = CurrentValueSubject<SystemMonitorReading?, Never>(nil)

    private let sampler: any SystemMonitorSampling
    private let interval: Duration
    private let now: @MainActor () -> Date
    private var recorded: [SystemMonitorSample] = []
    private var presenters: Set<SystemMonitorPresenter> = []
    private var presented: Bool { !presenters.isEmpty }
    private var liveReadout = false
    private var recording = false
    private let backgroundInterval: Duration
    private var generation = UUID()
    private var task: Task<Void, Never>?
    /// The stretch of time the graph covers.
    nonisolated static let historyWindow: TimeInterval = 600
    nonisolated static let historyLimit = 600
    /// Samples further apart than this were not recorded back to back.
    nonisolated static let recordingPause: TimeInterval = 30

    init(sampler: any SystemMonitorSampling = NativeSystemMonitorSampler(), interval: Duration = .seconds(2),
         backgroundInterval: Duration = .seconds(10), now: @escaping @MainActor () -> Date = { FrogClock.now }) {
        self.sampler = sampler
        self.interval = interval
        self.backgroundInterval = backgroundInterval
        self.now = now
    }

    func setPresented(_ shown: Bool, for presenter: SystemMonitorPresenter) {
        let wasPresented = presented
        if shown { presenters.insert(presenter) } else { presenters.remove(presenter) }
        guard presented != wasPresented else { return }
        // Hiding publishes nothing: the view reports it while it is taken down.
        if presented { history = recorded }
        reschedule()
    }

    /// While a menu-bar item shows the readings, they are taken out of sight too.
    func setLiveReadout(_ live: Bool) {
        guard liveReadout != live else { return }
        liveReadout = live
        if !live, readings.value != nil { readings.send(nil) }
        reschedule()
    }

    /// Keeps the graph's history while nothing shows it.
    func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        reschedule()
    }

    /// One reading for an agent: the newest if sampling runs, otherwise two readings a second apart.
    func current() async -> SystemMonitorSnapshot {
        if presented, case .value = snapshot.cpu { return snapshot }
        _ = await sampler.sample(reset: !isSampling, full: true)
        try? await Task.sleep(for: .seconds(1))
        return await sampler.sample(reset: false, full: true)
    }

    /// Starts the graph from readings taken earlier, such as the sample readings of the UI pictures; the next
    /// reading continues it.
    func restore(_ samples: [SystemMonitorSample]) {
        recorded = Array(samples.sorted { $0.time < $1.time }.suffix(Self.historyLimit))
        if presented { history = recorded }
    }

    func stop() {
        presenters = []
        liveReadout = false
        recording = false
        cancel()
        recorded = []
        history = []
        snapshot = SystemMonitorSnapshot()
    }

    private func reschedule() {
        guard presented || liveReadout || recording else { cancel(); return }
        task?.cancel()
        generation = UUID()
        let token = generation
        let sampler = sampler
        let full = presented
        let interval = presented || liveReadout ? interval : backgroundInterval
        // A recent sample keeps the CPU baseline valid, so the first reading is a real one.
        let recent = recorded.last.map { now().timeIntervalSince($0.time) < Self.recordingPause } ?? false
        task = Task(priority: .utility) { [weak self] in
            var reset = !recent
            while !Task.isCancelled {
                let reading = await sampler.sample(reset: reset, full: full)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.record(reading, full: full)
                // After a reset the CPU needs a second reading to show anything; take it soon.
                let pause = reset ? min(interval, .seconds(1)) : interval
                reset = false
                do { try await Task.sleep(for: pause, tolerance: full ? nil : pause / 5) } catch { return }
            }
        }
    }

    private func record(_ reading: SystemMonitorSnapshot, full: Bool) {
        let time = now()
        // A clock set back must not leave samples ahead of the newest one.
        recorded.removeAll { $0.time < time.addingTimeInterval(-Self.historyWindow) || $0.time >= time }
        recorded.append(.init(time: time, cpu: reading.cpu.value, gpu: reading.gpu.value, memory: reading.memory?.fraction))
        if recorded.count > Self.historyLimit { recorded.removeFirst(recorded.count - Self.historyLimit) }
        if liveReadout {
            let memory = reading.memory.map { SystemMonitorMetric.value($0.fraction) } ?? .unavailable
            let live = SystemMonitorReading(cpu: reading.cpu, gpu: reading.gpu, memory: memory)
            if readings.value != live { readings.send(live) }
        }
        guard full else { return }
        snapshot = reading
        history = recorded
    }

    /// Stops sampling but keeps the recent graph, so reopening within a few minutes shows it at once.
    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if readings.value != nil { readings.send(nil) }
    }

    deinit { task?.cancel() }
}
