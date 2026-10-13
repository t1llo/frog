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

    func testCountedEventsShowAtOnceAndAreSavedOffTheCallingThread() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = DispatchQueue(label: "frog.tests.activity-statistics")
        let store = ActivityStatisticsStore(directory: directory, writes: writes)
        // Nothing can be saved while the queue is held, so whatever reaches the disk
        // before the hooks return was written on the calling thread.
        writes.suspend()
        store.recordToolUse(.clipboardPaste)
        store.recordDictation(recordingSeconds: 2, text: "hello world", rule: .dictation)
        let saved = FileManager.default.fileExists(atPath: directory.path)
        writes.resume()
        XCTAssertFalse(saved, "A completion hook must not wait for the disk")
        XCTAssertEqual(store.snapshot.allTime.toolUses(.clipboardPaste), 1)
        XCTAssertEqual(store.snapshot.allTime.words, 2)
        XCTAssertEqual(store.snapshot.allTime.ruleRuns(.dictation), 1)
        store.waitForWrites()
        XCTAssertEqual(try ActivityStatisticsPersistence(directory: directory).load(), store.snapshot)
        XCTAssertNil(store.issue)
    }

    func testReloadPauseAndResetWaitForEventsStillBeingSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStatisticsStore(directory: directory), file = ActivityStatisticsPersistence(directory: directory)
        store.recordToolUse(.scriptRun)
        store.reload()
        XCTAssertEqual(store.snapshot.allTime.toolUses(.scriptRun), 1, "Reading the file again must not drop an event that is still being saved")
        store.recordToolUse(.scriptRun)
        store.setRecordingEnabled(false)
        XCTAssertEqual(store.snapshot.allTime.toolUses(.scriptRun), 2, "Pausing must keep the event counted just before it")
        XCTAssertEqual(try file.load(), store.snapshot)
        store.setRecordingEnabled(true)
        store.recordToolUse(.scriptRun)
        store.reset()
        store.waitForWrites()
        XCTAssertEqual(try file.load().allTime, ActivityStatisticsTotals(), "An event saved late must not undo a reset")
        XCTAssertEqual(store.snapshot.allTime, ActivityStatisticsTotals())
    }

    func testEventThatCouldNotBeSavedIsReportedAndNotCounted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStatisticsStore(directory: directory)
        store.recordRuleExecution(kind: .local)
        store.waitForWrites()
        // The file stays readable, but nothing can replace it in a read-only directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        store.recordRuleExecution(kind: .local)
        store.waitForWrites()
        for _ in 0..<500 where store.issue == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.issue)
        XCTAssertTrue(store.loaded)
        XCTAssertEqual(store.snapshot.allTime.ruleRuns(.local), 1, "The counts must not include an event that was not saved")
    }

    func testEventsThatCompleteTogetherAreSavedTogetherOrNotAtAll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ActivityStatisticsPersistence(directory: directory)
        let saved = try file.record([.dictation(recordingSeconds: 2, words: 2), .rule(.dictation)])
        XCTAssertEqual(saved.allTime.dictations, 1)
        XCTAssertEqual(saved.allTime.ruleRuns(.dictation), 1)
        XCTAssertEqual(try file.load(), saved)
        XCTAssertThrowsError(try file.record([.rule(.dictation), .dictation(recordingSeconds: .nan, words: 1)]))
        XCTAssertEqual(try file.load(), saved, "A rejected event must not leave half of its group behind")
    }
}
