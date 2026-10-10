import Foundation
import SQLite3
import XCTest
@testable import FrogUsage

@MainActor final class UsageParityTests: XCTestCase {
    func testOpenCodeV2AndLegacyUsageReachCombinedOpenAIChart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "frog-opencode-v2-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ statement: String) throws {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteFixture", code: 1)
            }
        }
        try sql("PRAGMA journal_mode=WAL;")
        try sql("CREATE TABLE message (time_created INTEGER, data TEXT);")
        try sql("CREATE TABLE session_message (id TEXT, type TEXT, time_created INTEGER, data TEXT);")
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        try sql("INSERT INTO message VALUES (\(time - 1000), '{\"role\":\"assistant\",\"providerID\":\"openai\",\"modelID\":\"gpt-5.1\",\"tokens\":{\"input\":10}}');")
        let data = "{\"model\":{\"providerID\":\"openai\",\"id\":\"gpt-5.1\"},\"time\":{\"created\":\(time),\"completed\":\(time+1)},\"tokens\":{\"input\":100,\"output\":20,\"reasoning\":30,\"cache\":{\"read\":40,\"write\":5}}}"
        try sql("INSERT INTO session_message VALUES ('original', 'assistant', \(time), '\(data)'), ('fork-copy', 'assistant', \(time), '\(data)'), ('user', 'user', \(time), '\(data)'), ('malformed', 'assistant', \(time), 'not-json');")
        let reader = OpenCodeReader(root: directory)
        var scan = await reader.scan()
        XCTAssertNil(scan.warning)
        XCTAssertEqual(scan.records.count, 2, "Read both storage generations without counting fork copies or user rows")
        XCTAssertEqual(scan.records.reduce(0) { $0 + $1.input }, 110)
        XCTAssertEqual(scan.records.reduce(0) { $0 + $1.output }, 50, "Reasoning is billed output, counted once")
        let codex = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "codex-fixture", "model_provider": "openai"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.1"]],
            ["type": "token_usage_record", "payload": ["session_id": "codex-fixture", "response_id": "reply", "usage": ["input_tokens": 10, "output_tokens": 5]]]
        ]
        var log = Data()
        for var event in events {
            event["timestamp"] = ISO8601DateFormatter().string(from: Date())
            log += try JSONSerialization.data(withJSONObject: event); log.append(10)
        }
        try log.write(to: codex.appendingPathComponent("fixture.jsonl"))
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        model.applyPreferences(UsageDashboardPreferences(provider: "OpenAI", allDevices: false))
        model.setActive(true)
        defer { model.setActive(false) }
        for _ in 0..<200 where !model.loaded { try await Task.sleep(for: .milliseconds(5)) }
        let chart = model.chart(provider: "OpenAI", range: "7d", metric: "Input")
        XCTAssertEqual(chart.totalTokens, 220, "Combine Codex and both generations of OpenCode activity")
        XCTAssertEqual(chart.sources.first { $0.name == "OpenCode" }?.value, 110)
        XCTAssertEqual(chart.sources.first { $0.name == "Codex" }?.value, 10)
        try sql("UPDATE session_message SET data=json_set(data,'$.tokens.input',120) WHERE id IN ('original','fork-copy');")
        scan = await reader.scan()
        XCTAssertEqual(scan.records.reduce(0) { $0 + $1.input }, 130, "V2 WAL updates refresh the same cached database")
        try sql("DROP TABLE message;")
        scan = await reader.scan()
        XCTAssertNil(scan.warning, "V2-only databases do not require the legacy table")
        XCTAssertEqual(scan.records.count, 1)
    }

    func testExplicitRefreshReadsNewLocalActivityImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "frog-usage-parity-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        model.setActive(true)
        defer { model.setActive(false) }
        for _ in 0..<200 where !model.loaded { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.loaded)
        let line = try JSONSerialization.data(withJSONObject: ["type": "assistant",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["id": "fixture", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 42]]]) + Data([10])
        try line.write(to: directory.appendingPathComponent("session.jsonl"))
        model.refresh()
        for _ in 0..<200 where model.chart(provider: "Claude", range: "7d", metric: "Input").total != "42" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.chart(provider: "Claude", range: "7d", metric: "Input").total, "42")
        let cost = model.chart(provider: "Claude", range: "7d", metric: "Output")
        XCTAssertTrue(cost.hasActivity, "A zero selected metric does not mean there was no token activity")
        XCTAssertEqual(cost.totalTokens, 42)
        XCTAssertEqual(cost.totals.first { $0.name == "Input" }?.value, 42)
    }

    func testAccountActivityOffersDailyRangesLikeStandalone() {
        let suite = "frog-usage-parity-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: URL(fileURLWithPath: "/nonexistent-fixture"))
        model.applyPreferences(UsageDashboardPreferences(provider: "OpenAI", range: "24h", allDevices: false))
        XCTAssertEqual(model.ranges, ["7d", "30d"])
        XCTAssertEqual(model.preferences.range, "7d", "Daily account totals must not appear as hourly measurements")
    }

    func testDashboardExposesClaudeLifetimeSeparatelyFromDeduplicatedPeriod() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "frog-usage-parity-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try JSONSerialization.data(withJSONObject: ["modelUsage": ["fixture": ["inputTokens": 20, "outputTokens": 30,
            "cacheReadInputTokens": 40, "cacheCreationInputTokens": 10]], "totalSessions": 7,
            "lastComputedDate": "2026-10-09", "dailyActivity": [["date": "2026-10-09", "messageCount": 3]]])
            .write(to: directory.appendingPathComponent("stats-cache.json"))
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        model.setActive(true)
        defer { model.setActive(false) }
        for _ in 0..<200 where !model.loaded { try await Task.sleep(for: .milliseconds(5)) }
        let lifetime = try XCTUnwrap(model.lifetime(provider: "Claude"))
        XCTAssertEqual(lifetime.statistics.first { $0.name == "Total tokens" }?.value, "100")
        XCTAssertEqual(lifetime.statistics.first { $0.name == "Sessions" }?.value, "7")
        XCTAssertTrue(lifetime.detail.contains("2026-10-09"))
        XCTAssertEqual(model.chart(provider: "Claude", range: "30d", metric: "Input").totalTokens, 0)
    }

    func testOpenAIHistoryAndLifetimePreserveAccountUnitsAndFields() throws {
        let activity = try XCTUnwrap(parseAccountActivity(["stats": ["lifetime_tokens": 1234.0,
            "peak_daily_tokens": 900.0, "current_streak_days": 2, "longest_streak_days": 8,
            "total_threads": 12, "most_used_reasoning_effort": "high", "most_used_reasoning_effort_percentage": 80.0],
            "metadata": ["stats_as_of": "2026-10-09"]], breakdown: nil))
        let shown = UsageLifetime(activity)
        XCTAssertEqual(shown.statistics.count, 6)
        XCTAssertEqual(shown.statistics.first { $0.name == "Chats" }?.value, "12")
        XCTAssertEqual(shown.statistics.first { $0.name == "Current streak" }?.value, "2d")
        XCTAssertTrue(shown.detail.contains("2026-10-09 UTC"))
        let history = parsePlanHistory(["periods": [["id": "fixture", "starts_at": "2026-10-01T00:00:00Z",
            "ends_at": "2026-10-08T00:00:00Z", "used_basis_points": 2345.0,
            "breakdowns": [["dimension": "model", "rows": [["key": "gpt-5.1", "basis_points": 2345.0]]]]]]])
        let period = UsagePlanPeriod(try XCTUnwrap(history.periods.first))
        XCTAssertEqual(period.percentage, 23.45, accuracy: 0.001)
        XCTAssertEqual(period.models.first?.value, 23.45)
        XCTAssertEqual(period.models.first?.name, "GPT-5.1")
    }

    func testClaudeProfilesIncludeXDGAndKeepMachinePathOutOfPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configured = root.appendingPathComponent("work-profile")
        let roots = ClaudePaths.transcriptRoots(home: root, configured: configured)
        XCTAssertEqual(roots.map(\.path), [".claude/projects", ".config/claude/projects", "work-profile/projects"].map { root.appendingPathComponent($0).path })
        XCTAssertEqual(ClaudePaths.transcriptRoots(home: root, configured: root.appendingPathComponent(".claude")).count, 2)
        let suite = "frog-usage-parity-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        model.selectClaudeConfigDirectory(configured)
        XCTAssertEqual(model.claudeConfigDirectory, configured)
        XCTAssertEqual(model.loginSource, "Claude Code")
        XCTAssertFalse(model.active)
        let portable = String(decoding: try JSONEncoder().encode(model.preferences), as: UTF8.self)
        XCTAssertFalse(portable.contains("work-profile"))
        XCTAssertEqual(claudePlanName(["organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x"]), "Max 20×")
        XCTAssertEqual(claudePlanName(["organizationType": "team"]), "Team")
        XCTAssertNil(claudePlanName([:]))
    }

    func testMalformedAccountStatisticsCannotBecomeDisplayCounts() throws {
        XCTAssertNil(parseAccountActivity(["stats": ["lifetime_tokens": true]], breakdown: nil))
        XCTAssertNil(parseAccountActivity(["stats": ["lifetime_tokens": Double.infinity]], breakdown: nil))
        let activity = try XCTUnwrap(parseAccountActivity(["stats": ["lifetime_tokens": 100,
            "current_streak_days": true, "longest_streak_days": -8, "total_threads": 2.5,
            "peak_daily_tokens": Double.nan, "most_used_reasoning_effort": "high",
            "most_used_reasoning_effort_percentage": Double.infinity]], breakdown: nil))
        XCTAssertEqual(activity.currentStreak, 0)
        XCTAssertEqual(activity.longestStreak, 0)
        XCTAssertEqual(activity.peakDay, 0)
        XCTAssertNil(activity.chats)
        XCTAssertEqual(UsageLifetime(activity).statistics.first { $0.name == "Reasoning" }?.value, "high · 0%")
        XCTAssertTrue(parsePlanHistory(["periods": [["starts_at": "2026-10-01T00:00:00Z",
            "ends_at": "2026-10-08T00:00:00Z", "used_basis_points": true]]]).periods.isEmpty)
    }

    func testOpenCodeWALUpdatesRecoveryAndDeletedDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ value: String) { XCTAssertEqual(sqlite3_exec(db, value, nil, nil, nil), SQLITE_OK) }
        sql("PRAGMA journal_mode=WAL;")
        sql("CREATE TABLE message (time_created INTEGER, data TEXT);")
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        func insert(_ input: Int) {
            sql("INSERT INTO message VALUES (\(time), '{\"role\":\"assistant\",\"providerID\":\"openai\",\"modelID\":\"gpt-5.1\",\"tokens\":{\"input\":\(input)}}');")
        }
        insert(10)
        let reader = OpenCodeReader(root: root)
        var scan = await reader.scan()
        XCTAssertEqual(scan.records.first?.input, 10)
        scan = await reader.scan()
        XCTAssertEqual(scan.records.first?.input, 10)
        sql("UPDATE message SET data=json_set(data, '$.tokens.input', 20);")
        scan = await reader.scan()
        XCTAssertEqual(scan.records.first?.input, 20, "WAL changes invalidate the cached counters")
        sql("ALTER TABLE message RENAME TO unavailable;")
        scan = await reader.scan()
        XCTAssertEqual(scan.records.first?.input, 20, "A temporarily unreadable schema must not publish an invented zero")
        XCTAssertNotNil(scan.warning)
        sql("ALTER TABLE unavailable RENAME TO message;")
        sql("DELETE FROM message;")
        insert(3)
        scan = await reader.scan()
        XCTAssertEqual(scan.records.first?.input, 3, "Recovery and mutable corrections replace the previous snapshot")
        XCTAssertNil(scan.warning)
        sqlite3_close(db); db = nil
        try FileManager.default.removeItem(at: url)
        scan = await reader.scan()
        XCTAssertTrue(scan.records.isEmpty)
        XCTAssertFalse(scan.found)
    }
}
