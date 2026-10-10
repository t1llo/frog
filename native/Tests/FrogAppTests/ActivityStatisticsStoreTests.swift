import XCTest
@testable import FrogApp
import FrogCore

@MainActor final class ActivityStatisticsStoreTests: XCTestCase {
    func testCompletionHooksIgnoreEmptyDictationAndPersistToggleAndReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStatisticsStore(directory: directory)
        XCTAssertTrue(store.loaded)
        store.recordDictation(recordingSeconds: 4, text: "… 🎉")
        store.recordDictation(recordingSeconds: .nan, text: "hello")
        XCTAssertEqual(store.snapshot.allTime.dictations, 0)
        store.recordDictation(recordingSeconds: 2, text: "hello world")
        store.recordRuleExecution(kind: .dictation)
        store.recordToolUse(.clipboardPaste)
        XCTAssertEqual(store.snapshot.allTime.words, 2)
        XCTAssertEqual(store.snapshot.allTime.dictations, 1)
        XCTAssertEqual(store.snapshot.allTime.ruleRuns(.dictation), 1)
        store.setRecordingEnabled(false)
        store.recordRuleExecution(kind: .remote)
        XCTAssertEqual(store.snapshot.allTime.ruleRuns(.remote), 0)
        let relaunched = ActivityStatisticsStore(directory: directory)
        XCTAssertEqual(relaunched.snapshot, store.snapshot)
        relaunched.reset()
        XCTAssertFalse(relaunched.snapshot.recordingEnabled)
        XCTAssertEqual(relaunched.snapshot.allTime, ActivityStatisticsTotals())
        XCTAssertNil(relaunched.issue)
    }

    func testUnreadableStatisticsDoNotPreventActionsOrSilentlyEnableRecordingOnReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("statistics.json"), bytes = Data("broken".utf8)
        try bytes.write(to: file)
        let store = ActivityStatisticsStore(directory: directory)
        XCTAssertFalse(store.loaded)
        XCTAssertNotNil(store.issue)
        store.recordRuleExecution(kind: .local)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        store.reset()
        XCTAssertTrue(store.loaded)
        XCTAssertFalse(store.snapshot.recordingEnabled)
        XCTAssertNil(store.issue)
    }
}
