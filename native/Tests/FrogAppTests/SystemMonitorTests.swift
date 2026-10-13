import Combine
import XCTest
@testable import FrogApp

@MainActor final class SystemMonitorTests: XCTestCase {
    func testDisabledMonitorDoesNoWorkEvenWhenShown() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5), backgroundInterval: .milliseconds(5))
        monitor.setPresented(true)
        try await Task.sleep(for: .milliseconds(25))
        let calls = await sampler.calls
        XCTAssertTrue(calls.isEmpty, "Default-off monitor must not sample even if a view asks")
        XCTAssertFalse(monitor.isSampling)
    }

    func testEnabledMonitorRecordsOutOfSightAndHasItsHistoryReadyWhenShown() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5), backgroundInterval: .milliseconds(5))
        monitor.configure(enabled: true)
        defer { monitor.stop() }
        try await waitUntil { await sampler.calls.count >= 3 }
        var calls = await sampler.calls
        XCTAssertEqual(calls.first, .init(reset: true, full: false))
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0 == .init(reset: false, full: false) }, "Out of sight only CPU and GPU are read")
        XCTAssertTrue(monitor.isSampling)
        XCTAssertTrue(monitor.history.isEmpty, "Recording out of sight must not redraw a menu that stays mounted")
        XCTAssertEqual(monitor.snapshot, SystemMonitorSnapshot())

        monitor.setPresented(true)
        XCTAssertGreaterThanOrEqual(monitor.history.count, 3, "The graph has its data on the first frame")
        XCTAssertEqual(monitor.snapshot.cpu, .value(0.25))
        try await waitUntil { await sampler.calls.last?.full == true }

        monitor.setPresented(false)
        let shown = monitor.history.count
        let hidden = await sampler.calls.count
        try await waitUntil { await sampler.calls.count >= hidden + 3 }
        calls = await sampler.calls
        XCTAssertTrue(calls.suffix(2).allSatisfy { !$0.full })
        XCTAssertFalse(calls.dropFirst().contains { $0.reset }, "Opening and closing the view must keep the baselines")
        XCTAssertEqual(monitor.history.count, shown)
        monitor.setPresented(true)
        XCTAssertGreaterThan(monitor.history.count, shown)

        monitor.configure(enabled: false)
        let disabled = await sampler.calls.count
        try await Task.sleep(for: .milliseconds(25))
        let afterDisabled = await sampler.calls.count
        XCTAssertEqual(afterDisabled, disabled)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.history.isEmpty)
        monitor.configure(enabled: true)
        try await waitUntil { await sampler.calls.count > disabled }
        calls = await sampler.calls
        XCTAssertEqual(calls[disabled], .init(reset: true, full: true), "Switching back on must not average load over the time spent off")
    }

    func testHidingTheViewPublishesNothing() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .seconds(60), backgroundInterval: .seconds(60))
        monitor.configure(enabled: true)
        monitor.setPresented(true)
        defer { monitor.stop() }
        try await waitUntil { monitor.snapshot.cpu == .value(0.25) }
        var changes = 0
        let watching = monitor.objectWillChange.sink { changes += 1 }
        defer { watching.cancel() }
        // The view reports this while it is taken down, when nothing may be published.
        monitor.setPresented(false)
        XCTAssertEqual(changes, 0, "A view that is going away has nothing to redraw")
        XCTAssertTrue(monitor.isSampling, "Recording goes on out of sight")
        monitor.setPresented(true)
        XCTAssertGreaterThan(changes, 0, "Showing it again brings the recorded history")
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
        XCTAssertEqual(monitor.history.map(\.cpu), [0.25])
        monitor.stop()
        XCTAssertEqual(monitor.snapshot, SystemMonitorSnapshot())
    }

    func testHistoryCoversOnlyTheGraphsWindowAndMissingReadingsRemainGaps() async throws {
        let sampler = MonitorFixture(snapshot: .init(cpu: .value(0.4), gpu: .unavailable))
        let clock = ClockFixture(step: 60)
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(1), backgroundInterval: .milliseconds(1)) { clock.next() }
        monitor.configure(enabled: true)
        monitor.setPresented(true)
        defer { monitor.stop() }
        try await waitUntil { await sampler.calls.count > 20 }
        let history = monitor.history
        XCTAssertEqual(history.count, Int(SystemMonitor.historyWindow / 60) + 1)
        XCTAssertEqual(history.last!.time.timeIntervalSince(history.first!.time), SystemMonitor.historyWindow)
        XCTAssertTrue(history.allSatisfy { $0.cpu == 0.4 && $0.gpu == nil })
    }

    func testHistoryIsBoundedAndAClockSetBackLeavesNoSampleAheadOfTheNewest() async throws {
        let sampler = MonitorFixture()
        let clock = ClockFixture(step: 0.01)
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(1), backgroundInterval: .milliseconds(1)) { clock.next() }
        monitor.configure(enabled: true)
        monitor.setPresented(true)
        defer { monitor.stop() }
        try await waitUntil { await sampler.calls.count > SystemMonitor.historyLimit + 4 }
        XCTAssertEqual(monitor.history.count, SystemMonitor.historyLimit)
        clock.time.addTimeInterval(-3600)
        let count = await sampler.calls.count
        try await waitUntil { await sampler.calls.count > count + 2 }
        XCTAssertLessThan(monitor.history.count, 8)
        XCTAssertEqual(monitor.history.map(\.time), monitor.history.map(\.time).sorted())
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for monitor state")
    }
}

@MainActor private final class ClockFixture {
    var time = Date(timeIntervalSinceReferenceDate: 0)
    let step: TimeInterval
    init(step: TimeInterval) { self.step = step }
    func next() -> Date { time.addTimeInterval(step); return time }
}

private actor MonitorFixture: SystemMonitorSampling {
    struct Call: Equatable { let reset: Bool; let full: Bool }
    private(set) var calls: [Call] = []
    let snapshot: SystemMonitorSnapshot
    init(snapshot: SystemMonitorSnapshot = .init(cpu: .value(0.25))) { self.snapshot = snapshot }
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        calls.append(.init(reset: reset, full: full))
        return snapshot
    }
}

private actor GatedMonitorFixture: SystemMonitorSampling {
    private var continuations: [CheckedContinuation<SystemMonitorSnapshot, Never>?] = []
    var pendingCount: Int { continuations.count }
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
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
        XCTAssertEqual(SystemMonitorDelta.cpu(previous: before, current: after, elapsed: 12), 0.35, "A late background wake-up is still a true average")
    }

    func testCPUMeterRepeatsAReadingAskedForTooSoonAndKeepsItsBaseline() {
        var meter = SystemMonitorCPUMeter()
        let start = [SystemMonitorDelta.CPU(user: 0, system: 0, idle: 100, nice: 0)]
        XCTAssertEqual(meter.reading(start, at: 10), .measuring)
        XCTAssertEqual(meter.reading([.init(user: 50, system: 0, idle: 150, nice: 0)], at: 12), .value(0.5))
        // One busy tick in a tenth of a second would read as a fully loaded Mac.
        XCTAssertEqual(meter.reading([.init(user: 51, system: 0, idle: 150, nice: 0)], at: 12.1), .value(0.5))
        XCTAssertEqual(meter.reading([.init(user: 60, system: 0, idle: 190, nice: 0)], at: 14), .value(0.2), "The baseline stayed at the last real reading")
        XCTAssertEqual(meter.reading([.init(user: 70, system: 0, idle: 200, nice: 0)], at: 80), .measuring, "A stretch too long to trust is not a reading")
        XCTAssertEqual(meter.reading([.init(user: 75, system: 0, idle: 215, nice: 0)], at: 82), .value(0.25))
        XCTAssertEqual(meter.reading(nil, at: 84), .unavailable)
        XCTAssertEqual(meter.reading(start, at: 86), .measuring)
        meter.reset()
        XCTAssertEqual(meter.reading(start, at: 86.1), .measuring)
    }

    func testGraphLineBreaksAtMissingReadingsAndRecordingPauses() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let history = [(0.0, 0.1), (5, 0.2), (10, nil), (15, 1.4), (20, 0.3), (120, 0.5), (125, 0.6)].map {
            SystemMonitorSample(time: start.addingTimeInterval($0.0), cpu: $0.1, gpu: nil)
        }
        let runs = SystemMonitorRun.runs(history, pause: 30, value: \.cpu)
        XCTAssertEqual(runs.map { $0.points.map(\.value) }, [[0.1, 0.2], [1, 0.3], [0.5, 0.6]])
        XCTAssertEqual(runs.map { $0.points.map(\.offset) }, [[-125, -120], [-110, -105], [-5, 0]])
        XCTAssertTrue(SystemMonitorRun.runs(history, pause: 30, value: \.gpu).isEmpty)
        XCTAssertTrue(SystemMonitorRun.runs([], pause: 30, value: \.cpu).isEmpty)
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
