import XCTest
@testable import FrogCore

final class ActivityStatisticsTests: XCTestCase {
    private var directory: URL!
    private let utc = TimeZone(secondsFromGMT: 0)!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-statistics-tests-\(UUID())")
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testPrivateRoundTripAggregatesWithoutContentOrHistory() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        XCTAssertTrue(try store.load().recordingEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let date = day("2026-10-10")
        try store.record(.dictation(recordingSeconds: 30, words: 60), at: date, timeZone: utc)
        try store.record(.dictation(recordingSeconds: 90, words: 120), at: date, timeZone: utc)
        for kind in ActivityRuleKind.allCases { try store.record(.rule(kind), at: date, timeZone: utc) }
        try store.record(.tool(.clipboardPaste), at: date, timeZone: utc)
        let snapshot = try ActivityStatisticsPersistence(directory: directory).load(at: date, timeZone: utc)
        XCTAssertEqual(snapshot.allTime.dictations, 2)
        XCTAssertEqual(snapshot.allTime.words, 180)
        XCTAssertEqual(snapshot.allTime.recordingSeconds, 120)
        XCTAssertEqual(snapshot.allTime.wordsPerMinute, 90)
        XCTAssertEqual(snapshot.allTime.ruleRuns, ActivityRuleKind.allCases.count)
        XCTAssertEqual(snapshot.allTime.ruleRuns(.remote), 1)
        XCTAssertEqual(snapshot.allTime.toolUses(.clipboardPaste), 1)
        XCTAssertEqual(snapshot.allTime.toolUses(.scriptRun), 0)
        XCTAssertEqual(snapshot.daily["2026-10-10"], snapshot.allTime)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["statistics.json"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "recordingEnabled", "allTime", "daily"])
    }

    func testOptOutSurvivesRelaunchAndResetWithoutRecordingWrites() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        try store.record(.rule(.local))
        try store.setRecordingEnabled(false)
        let bytes = try Data(contentsOf: store.file)
        let relaunched = ActivityStatisticsPersistence(directory: directory)
        try relaunched.record(.tool(.clipboardPaste))
        try relaunched.record(.dictation(recordingSeconds: .nan, words: -1))
        XCTAssertEqual(try Data(contentsOf: store.file), bytes)
        let reset = try relaunched.reset(recordingEnabled: false)
        XCTAssertFalse(reset.recordingEnabled)
        XCTAssertEqual(reset.allTime, ActivityStatisticsTotals())
        XCTAssertTrue(reset.daily.isEmpty)
        XCTAssertFalse(try relaunched.load().recordingEnabled)
        try relaunched.setRecordingEnabled(true)
        XCTAssertEqual(try relaunched.record(.rule(.cli)).allTime.ruleRuns, 1)
    }

    func testRecentPeriodsIncludeTodayAndPruneDailyWithoutLosingAllTime() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        let today = day("2026-10-10")
        for age in [365, 364, 30, 29, 7, 6, 0] {
            try store.record(.rule(.local), at: today.addingTimeInterval(-Double(age) * 86_400), timeZone: utc)
        }
        let snapshot = try store.load(at: today, timeZone: utc)
        XCTAssertEqual(snapshot.allTime.ruleRuns, 7)
        XCTAssertEqual(snapshot.daily.count, 6)
        XCTAssertEqual(snapshot.totals(lastDays: 7, endingAt: today, timeZone: utc).ruleRuns, 2)
        XCTAssertEqual(snapshot.totals(lastDays: 30, endingAt: today, timeZone: utc).ruleRuns, 4)
        XCTAssertEqual(snapshot.totals(lastDays: 365, endingAt: today, timeZone: utc).ruleRuns, 6)
        let later = try store.load(at: today.addingTimeInterval(366 * 86_400), timeZone: utc)
        XCTAssertTrue(later.daily.isEmpty)
        XCTAssertEqual(later.allTime.ruleRuns, 7)
    }

    func testDailyStorageNeverExceeds365Buckets() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        let start = day("2025-01-01")
        var snapshot = ActivityStatisticsSnapshot()
        for offset in 0..<370 {
            snapshot = try store.record(.tool(.windowCommand), at: start.addingTimeInterval(Double(offset) * 86_400), timeZone: utc)
        }
        XCTAssertEqual(snapshot.daily.count, 365)
        XCTAssertEqual(snapshot.allTime.toolUses(.windowCommand), 370)
        XCTAssertLessThan(try Data(contentsOf: store.file).count, 1_024 * 1_024)
    }

    func testCivilDaysHandleDSTAndNonGregorianUserCalendars() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: "2026-03-09T06:30:00Z")) // March 8, after DST starts.
        let snapshot = try store.record(.rule(.local), at: date, timeZone: zone)
        XCTAssertNotNil(snapshot.daily["2026-03-08"])
        XCTAssertEqual(snapshot.totals(lastDays: 1, endingAt: date, timeZone: zone).ruleRuns, 1)
    }

    func testInvalidDurationsAndCountsDoNotCreateStatistics() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertThrowsError(try store.record(.dictation(recordingSeconds: duration, words: 3)))
        }
        for words in [-1, 0, Int.max] {
            XCTAssertThrowsError(try store.record(.dictation(recordingSeconds: 10, words: words)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(ActivityStatisticsTotals().wordsPerMinute)
    }

    func testCorruptionAndFutureVersionsArePreservedUntilExplicitReset() throws {
        let store = ActivityStatisticsPersistence(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let valid = try JSONEncoder().encode(ActivityStatisticsSnapshot())
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any]); future["version"] = 99
        var negative = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var totals = try XCTUnwrap(negative["allTime"] as? [String: Any]); totals["words"] = -1; negative["allTime"] = totals
        for bytes in [Data("{broken".utf8), try JSONSerialization.data(withJSONObject: future), try JSONSerialization.data(withJSONObject: negative)] {
            try bytes.write(to: store.file)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.record(.rule(.local)))
            XCTAssertThrowsError(try store.setRecordingEnabled(false))
            XCTAssertEqual(try Data(contentsOf: store.file), bytes)
        }
        XCTAssertEqual(try store.reset(recordingEnabled: false).allTime, ActivityStatisticsTotals())
        XCTAssertFalse(try store.load().recordingEnabled)
    }

    func testSymlinkRefusedAndExplicitResetDoesNotModifyTarget() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("unrelated.json"), bytes = Data("preserve me".utf8)
        try bytes.write(to: target)
        let store = ActivityStatisticsPersistence(directory: directory)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.record(.rule(.local)))
        try store.reset(recordingEnabled: false)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertFalse(try store.load().recordingEnabled)
    }

    func testUnicodeWordsAreNotWhitespaceOrPunctuationCounts() {
        XCTAssertEqual(ActivityStatisticsSnapshot.wordCount(in: "  Hello,\nworld! café déjà vu  "), 5)
        XCTAssertEqual(ActivityStatisticsSnapshot.wordCount(in: "Привет мир مرحبا بالعالم"), 4)
        XCTAssertGreaterThan(ActivityStatisticsSnapshot.wordCount(in: "你好世界。今日は良い天気です。"), 1)
        XCTAssertEqual(ActivityStatisticsSnapshot.wordCount(in: " \n 👩🏽‍💻 🎉 — … !"), 0)
        XCTAssertEqual(ActivityStatisticsSnapshot.wordCount(in: ""), 0)
    }

    func testConcurrentStoreInstancesDoNotLoseIncrements() throws {
        let root = directory!
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            _ = try? ActivityStatisticsPersistence(directory: root).record(.tool(.applicationCommand))
        }
        XCTAssertEqual(try ActivityStatisticsPersistence(directory: root).load().allTime.toolUses(.applicationCommand), 40)
    }

    private func day(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value + "T12:00:00Z")!
    }
}
