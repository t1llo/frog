import XCTest
@testable import FrogApp

@MainActor final class SystemMonitorTests: XCTestCase {
    func testDisabledAndHiddenMonitorDoNoWorkAndReopeningResetsBaselines() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5))
        monitor.setPresented(true)
        try await Task.sleep(for: .milliseconds(25))
        var calls = await sampler.resets
        XCTAssertTrue(calls.isEmpty, "Default-off monitor must not sample even if a view asks")
        monitor.setPresented(false)
        monitor.configure(enabled: true)
        try await Task.sleep(for: .milliseconds(25))
        calls = await sampler.resets
        XCTAssertTrue(calls.isEmpty, "Enabling alone must not start a background collector")
        monitor.setPresented(true)
        try await waitUntil { await sampler.resets.count >= 2 }
        XCTAssertTrue(monitor.isSampling)
        calls = await sampler.resets
        XCTAssertEqual(Array(calls.prefix(2)), [true, false])
        monitor.setPresented(false)
        let hiddenCount = await sampler.resets.count
        try await Task.sleep(for: .milliseconds(25))
        let afterHidden = await sampler.resets.count
        XCTAssertEqual(afterHidden, hiddenCount)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.cpuHistory.isEmpty)
        monitor.setPresented(true)
        try await waitUntil { await sampler.resets.count > hiddenCount }
        calls = await sampler.resets
        XCTAssertTrue(calls[hiddenCount], "Reopening must not average load over time spent hidden")
        monitor.configure(enabled: false)
        let disabledCount = await sampler.resets.count
        try await Task.sleep(for: .milliseconds(25))
        let afterDisabled = await sampler.resets.count
        XCTAssertEqual(afterDisabled, disabledCount)
        XCTAssertFalse(monitor.isSampling)
    }

    func testCancellationRejectsLateSamplerCompletionAcrossReenable() async throws {
        let sampler = GatedMonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .seconds(60))
        monitor.configure(enabled: true)
        monitor.setPresented(true)
        try await waitUntil { await sampler.pendingCount == 1 }
        monitor.stop()
        monitor.configure(enabled: true)
        monitor.setPresented(true)
        try await waitUntil { await sampler.pendingCount == 2 }
        await sampler.finish(index: 1, cpu: 0.25)
        try await waitUntil { monitor.snapshot.cpu == .value(0.25) }
        await sampler.finish(index: 0, cpu: 0.99)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(monitor.snapshot.cpu, .value(0.25))
        XCTAssertEqual(monitor.cpuHistory, [0.25])
        monitor.stop()
        XCTAssertEqual(monitor.snapshot, SystemMonitorSnapshot())
    }

    func testHistoryIsBoundedAndMissingReadingsRemainGaps() async throws {
        let sampler = MonitorFixture(snapshot: .init(cpu: .value(0.4), gpu: .unavailable))
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(1))
        monitor.configure(enabled: true)
        monitor.setPresented(true)
        defer { monitor.stop() }
        try await waitUntil { await sampler.resets.count > SystemMonitor.historyLimit + 4 }
        XCTAssertEqual(monitor.cpuHistory.count, SystemMonitor.historyLimit)
        XCTAssertEqual(monitor.gpuHistory.count, SystemMonitor.historyLimit)
        XCTAssertTrue(monitor.cpuHistory.allSatisfy { $0 == 0.4 })
        XCTAssertTrue(monitor.gpuHistory.allSatisfy { $0 == nil })
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for monitor state")
    }
}

private actor MonitorFixture: SystemMonitorSampling {
    private(set) var resets: [Bool] = []
    let snapshot: SystemMonitorSnapshot
    init(snapshot: SystemMonitorSnapshot = .init(cpu: .value(0.25))) { self.snapshot = snapshot }
    func sample(reset: Bool) async -> SystemMonitorSnapshot {
        resets.append(reset)
        return snapshot
    }
}

private actor GatedMonitorFixture: SystemMonitorSampling {
    private var continuations: [CheckedContinuation<SystemMonitorSnapshot, Never>?] = []
    var pendingCount: Int { continuations.count }
    func sample(reset: Bool) async -> SystemMonitorSnapshot {
        await withCheckedContinuation { continuations.append($0) }
    }
    func finish(index: Int, cpu: Double) {
        continuations[index]?.resume(returning: .init(cpu: .value(cpu)))
        continuations[index] = nil
    }
}

final class SystemMonitorDeltaTests: XCTestCase {
    func testCPUUsesIntervalBusyShareAcrossCoresNotLifetimeAverage() {
        let before: [SystemMonitorDelta.CPU] = [.init(user: 100, system: 50, idle: 800, nice: 50), .init(user: 0, system: 0, idle: 1000, nice: 0)]
        let after: [SystemMonitorDelta.CPU] = [.init(user: 125, system: 60, idle: 850, nice: 65), .init(user: 10, system: 10, idle: 1080, nice: 0)]
        XCTAssertEqual(SystemMonitorDelta.cpu(previous: before, current: after, elapsed: 2), 0.35)
        XCTAssertNil(SystemMonitorDelta.cpu(previous: before, current: after, elapsed: 120))
        XCTAssertNil(SystemMonitorDelta.cpu(previous: before, current: after, elapsed: 0))
        XCTAssertNil(SystemMonitorDelta.cpu(previous: before, current: before, elapsed: 2))
        XCTAssertNil(SystemMonitorDelta.cpu(previous: before, current: [after[0]], elapsed: 2))
        XCTAssertNil(SystemMonitorDelta.cpu(previous: after, current: before, elapsed: 2))
    }

    func testCPUCounterWrapIsHandledWithoutOverflow() {
        let before = SystemMonitorDelta.CPU(user: UInt32.max - 4, system: 0, idle: 5, nice: 0)
        let after = SystemMonitorDelta.CPU(user: 5, system: 0, idle: 15, nice: 0)
        XCTAssertEqual(SystemMonitorDelta.cpu(previous: [before], current: [after], elapsed: 2), 0.5)
    }

    func testDiskRatesRejectCounterResetHotplugAndSleepGaps() throws {
        let before: [UInt64: SystemMonitorDelta.Disk] = [1: .init(read: 100, written: 300), 2: .init(read: 0, written: 0)]
        let after: [UInt64: SystemMonitorDelta.Disk] = [1: .init(read: 500, written: 500), 2: .init(read: 200, written: 400)]
        let rate = try XCTUnwrap(SystemMonitorDelta.disk(previous: before, current: after, elapsed: 2))
        XCTAssertEqual(rate.read, 300)
        XCTAssertEqual(rate.write, 300)
        XCTAssertNil(SystemMonitorDelta.disk(previous: after, current: before, elapsed: 2))
        XCTAssertNil(SystemMonitorDelta.disk(previous: before, current: after, elapsed: 11))
        XCTAssertNil(SystemMonitorDelta.disk(previous: before, current: [1: after[1]!], elapsed: 2))
        XCTAssertNil(SystemMonitorDelta.disk(previous: [:], current: [:], elapsed: 2))
    }

    func testUnsupportedOrInvalidGPUStatsAreNotInvented() {
        XCTAssertNil(SystemMonitorDelta.gpu(percent: .nan))
        XCTAssertNil(SystemMonitorDelta.gpu(percent: .infinity))
        XCTAssertNil(SystemMonitorDelta.gpu(percent: -1))
        XCTAssertNil(SystemMonitorDelta.gpu(percent: 101))
        XCTAssertEqual(SystemMonitorDelta.gpu(percent: 0), 0)
        XCTAssertEqual(SystemMonitorDelta.gpu(percent: 42), 0.42)
        XCTAssertEqual(SystemMonitorDelta.gpu(percent: 100), 1)
    }
}
