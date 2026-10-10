import Combine
import Foundation

protocol SystemMonitorSampling: Sendable {
    /// Reset baselines when a new presentation starts; paused time is not usage.
    func sample(reset: Bool) async -> SystemMonitorSnapshot
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemMonitorSnapshot()
    @Published private(set) var cpuHistory: [Double?] = []
    @Published private(set) var gpuHistory: [Double?] = []
    @Published private(set) var isSampling = false

    private let sampler: any SystemMonitorSampling
    private let interval: Duration
    private var enabled = false
    private var presented = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    nonisolated static let historyLimit = 30

    init(sampler: any SystemMonitorSampling = NativeSystemMonitorSampler(), interval: Duration = .seconds(2)) {
        self.sampler = sampler
        self.interval = interval
    }

    func configure(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        reconcile()
    }

    func setPresented(_ presented: Bool) {
        guard self.presented != presented else { return }
        self.presented = presented
        reconcile()
    }

    func stop() {
        enabled = false
        presented = false
        cancel()
    }

    private func reconcile() {
        guard enabled && presented else { cancel(); return }
        guard task == nil else { return }
        generation = UUID()
        let token = generation
        let sampler = sampler
        let interval = interval
        isSampling = true
        // No synchronous OS reads occur here or during menu construction.
        task = Task(priority: .utility) { [weak self] in
            var reset = true
            while !Task.isCancelled {
                let reading = await sampler.sample(reset: reset)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.snapshot = reading
                self.cpuHistory.append(reading.cpu.value)
                self.gpuHistory.append(reading.gpu.value)
                if self.cpuHistory.count > Self.historyLimit { self.cpuHistory.removeFirst() }
                if self.gpuHistory.count > Self.historyLimit { self.gpuHistory.removeFirst() }
                reset = false
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isSampling = false
        snapshot = SystemMonitorSnapshot()
        cpuHistory = []
        gpuHistory = []
    }

    deinit { task?.cancel() }
}
