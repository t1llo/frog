import Combine
import XCTest
@testable import FrogApp

@MainActor final class SystemMonitorTests: XCTestCase {
    func testNothingSamplesWhileNothingShowsTheReadings() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(25))
        let calls = await sampler.calls
        XCTAssertTrue(calls.isEmpty, "With every overview closed and no menu-bar item, nothing is read")
        XCTAssertFalse(monitor.isSampling)
    }

    func testAShownOverviewSamplesInFullAndStopsOnceHidden() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5))
        defer { monitor.stop() }
        monitor.setPresented(true, for: .page)
        try await waitUntil { await sampler.calls.count >= 3 }
        var calls = await sampler.calls
        XCTAssertEqual(calls.first, .init(reset: true, full: true), "The first reading starts a new baseline")
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0 == .init(reset: false, full: true) })
        XCTAssertEqual(monitor.snapshot.cpu, .value(0.25))
        XCTAssertGreaterThanOrEqual(monitor.history.count, 3)

        monitor.setPresented(false, for: .page)
        XCTAssertFalse(monitor.isSampling, "Hidden, the task ends at once")
        let hidden = await sampler.calls.count
        try await Task.sleep(for: .milliseconds(25))
        let later = await sampler.calls.count
        XCTAssertEqual(later, hidden, "Nothing is read while nothing is shown")

        // Back within half a minute: the recorded graph shows on the first frame and the baseline holds.
        let shown = monitor.history.count
        monitor.setPresented(true, for: .page)
        XCTAssertEqual(monitor.history.count, shown)
        try await waitUntil { await sampler.calls.count > hidden }
        calls = await sampler.calls
        XCTAssertEqual(calls[hidden], .init(reset: false, full: true), "A recent sample keeps the CPU baseline valid")
    }

    func testTheMenuBarItemGetsLiveReadingsWithoutRedrawingTheClosedMenu() async throws {
        let sampler = MonitorFixture(snapshot: .init(cpu: .value(0.25), gpu: .value(0.5),
                                                     memory: SystemMonitorMemory(used: 4, total: 16)))
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5))
        defer { monitor.stop() }
        monitor.setLiveReadout(true)
        try await waitUntil { await sampler.calls.count >= 3 }
        XCTAssertEqual(monitor.readings.value, SystemMonitorReading(cpu: .value(0.25), gpu: .value(0.5), memory: .value(0.25)))
        XCTAssertTrue(monitor.history.isEmpty, "The item reads its own subject; the overview stays untouched")
        XCTAssertEqual(monitor.snapshot, SystemMonitorSnapshot())
        let full = await sampler.calls.contains { $0.full }
        XCTAssertFalse(full, "The item needs no power reading")
        monitor.setLiveReadout(false)
        XCTAssertNil(monitor.readings.value, "Without the item, no stale load stays around")
        XCTAssertFalse(monitor.isSampling)
    }

    func testHidingTheViewPublishesNothing() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .seconds(60))
        monitor.setPresented(true, for: .page)
        defer { monitor.stop() }
        try await waitUntil { monitor.snapshot.cpu == .value(0.25) }
        var changes = 0
        let watching = monitor.objectWillChange.sink { changes += 1 }
        defer { watching.cancel() }
        // The view reports this while it is taken down, when nothing may be published.
        monitor.setPresented(false, for: .page)
        XCTAssertEqual(changes, 0, "A view that is going away has nothing to redraw")
        monitor.setPresented(true, for: .page)
        XCTAssertGreaterThan(changes, 0, "Showing it again brings the recorded history")
    }

    func testAPopupClosingLeavesTheOpenPageLive() async throws {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5))
        defer { monitor.stop() }
        monitor.setPresented(true, for: .page)
        monitor.setPresented(true, for: .statusPopup)
        monitor.setPresented(false, for: .statusPopup)
        let shown = await sampler.calls.count
        try await waitUntil { await sampler.calls.count >= shown + 3 }
        XCTAssertTrue(monitor.isSampling, "The page is still on screen")
        monitor.setPresented(false, for: .page)
        let hidden = monitor.history.count
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(monitor.history.count, hidden, "With nothing on screen the graph stops redrawing")
    }

    func testAnAgentReadingTakesTwoSamplesAndLeavesNothingRunning() async {
        let sampler = MonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5))
        let snapshot = await monitor.current()
        XCTAssertEqual(snapshot.cpu, .value(0.25))
        let calls = await sampler.calls
        XCTAssertEqual(calls, [.init(reset: true, full: true), .init(reset: false, full: true)])
        XCTAssertFalse(monitor.isSampling)
    }

    func testCancellationRejectsLateSamplerCompletionAcrossReopening() async throws {
        let sampler = GatedMonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .seconds(60))
        monitor.setPresented(true, for: .page)
        try await waitUntil { await sampler.pendingCount == 1 }
        monitor.stop()
        monitor.setPresented(true, for: .page)
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
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(1)) { clock.next() }
        monitor.setPresented(true, for: .page)
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
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(1)) { clock.next() }
        monitor.setPresented(true, for: .page)
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
