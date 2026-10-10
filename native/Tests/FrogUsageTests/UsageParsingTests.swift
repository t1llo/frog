import Foundation
import SQLite3
import XCTest
@testable import FrogUsage

final class UsageParsingTests: XCTestCase {
    func testClaudeStreamingDeduplicationAndPartialLineAcrossScans() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), file = root.appendingPathComponent("fixture.jsonl")
        func line(_ id: String, _ output: Int) throws -> Data {
            try jsonLine(["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now),
                "message": ["id": id, "model": "claude-sonnet-4-6", "usage": ["input_tokens": 3, "output_tokens": output, "cache_read_input_tokens": 100]]])
        }
        let tail = try line("second", 5)
        try (line("first", 10) + line("first", 20) + tail.dropLast()).write(to: file)
        let scanner = TokenScanner(root: root)
        let first = await scanner.scan()
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first.first?.output, 20)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        let complete = await scanner.scan(), repeated = await scanner.scan()
        XCTAssertEqual(complete.count, 2); XCTAssertEqual(repeated.count, 2)
        let summary = summarize(complete, provider: .claude, range: .week, metric: .input, now: now.addingTimeInterval(1))
        XCTAssertEqual(summary.totalTokens, 231)
        XCTAssertEqual(summary.buckets.reduce(0) { $0 + $1.value }, 6)
    }

    func testCodexResponseRecordsSupersedeRunningTotals() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            try jsonLine(["timestamp": ISO8601DateFormatter().string(from: Date()), "type": type, "payload": payload])
        }
        let counts = ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10, "reasoning_output_tokens": 6, "total_tokens": 110]
        var data = try line("session_meta", ["id": "fixture-thread"])
        data += try line("turn_context", ["model": "gpt-5.1"])
        data += try line("event_msg", ["type": "token_count", "info": ["last_token_usage": counts, "total_token_usage": counts]])
        data += try line("token_usage_record", ["thread_id": "fixture-thread", "response_id": "response", "usage": counts])
        try data.write(to: folder.appendingPathComponent("rollout.jsonl"))
        let scan = await CodexScanner(root: root).scan()
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertEqual(scan.records.first?.input, 20); XCTAssertEqual(scan.records.first?.cacheRead, 80); XCTAssertEqual(scan.records.first?.output, 10)
    }

    func testOpenCodeRereadsMutableRowsAndDeduplicatesCopies() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("opencode-fixture.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message (time_created INTEGER, data TEXT);", nil, nil, nil), SQLITE_OK)
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        let json = try JSONSerialization.data(withJSONObject: ["role": "assistant", "providerID": "openai", "modelID": "gpt-5.1",
            "time": ["created": time, "completed": time + 1], "tokens": ["input": 3, "output": 10, "reasoning": 5, "cache": ["read": 100, "write": 20]]])
        let sql = "INSERT INTO message VALUES (\(time), '\(String(decoding: json, as: UTF8.self))');"
        for _ in 0..<2 { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
        let reader = OpenCodeReader(root: root)
        let first = await reader.scan()
        XCTAssertEqual(first.records.count, 1); XCTAssertEqual(first.records.first?.output, 15)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM message;", nil, nil, nil), SQLITE_OK)
        let empty = await reader.scan()
        XCTAssertTrue(empty.records.isEmpty)
    }

    func testModernCodexSessionIDsStreamingCopiesAndProviderScope() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let time = ISO8601DateFormatter().string(from: Date())
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            try jsonLine(["timestamp": time, "type": type, "payload": payload])
        }
        func response(_ output: Int, session: String? = "session-fixture", id: String? = "reply-fixture") throws -> Data {
            var payload: [String: Any] = ["usage": ["input_tokens": 100, "cached_input_tokens": 70,
                "cache_write_input_tokens": 10, "output_tokens": output, "reasoning_output_tokens": 3]]
            if let session { payload["session_id"] = session }
            if let id { payload["response_id"] = id }
            return try line("token_usage_record", payload)
        }
        var data = try line("session_meta", ["id": "session-fixture", "model_provider": "openai"])
        data += try line("turn_context", ["model": "gpt-5.1"])
        data += try response(12)
        data += try response(4) // A resumed copy must not lower the response's counters.
        data += try response(6, session: nil, id: "without-session")
        data += try response(7, id: nil) // Observed format permits a missing response ID.
        data += try response(90, session: "other-session", id: "copied-parent")
        try data.write(to: folder.appendingPathComponent("modern.jsonl"))
        var local = try line("session_meta", ["id": "local-fixture", "model_provider": "ollama"])
        local += try line("turn_context", ["model": "gpt-5.1"])
        local += try line("token_usage_record", ["thread_id": "local-fixture", "response_id": "not-openai",
            "usage": ["input_tokens": 900, "output_tokens": 900]])
        try local.write(to: folder.appendingPathComponent("local.jsonl"))
        let scanner = CodexScanner(root: root)
        let first = await scanner.scan(), repeated = await scanner.scan()
        XCTAssertEqual(first.records.count, 3)
        XCTAssertEqual(first.records.map(\.output).sorted(), [6, 7, 12])
        XCTAssertEqual(first.records.reduce(0) { $0 + $1.input }, 60)
        XCTAssertEqual(first.records.reduce(0) { $0 + $1.cacheRead }, 210)
        XCTAssertEqual(first.records.reduce(0) { $0 + $1.cacheWrite }, 30)
        XCTAssertEqual(repeated.records.map(\.output).sorted(), [6, 7, 12])
    }

    func testOpenCodeMalformedRowsDoNotHideValidUsageAndMissingTimestampUsesColumn() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message (time_created INTEGER, data TEXT);", nil, nil, nil), SQLITE_OK)
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES (\(time), '{incomplete');", nil, nil, nil), SQLITE_OK)
        let json = try JSONSerialization.data(withJSONObject: ["role": "assistant", "providerID": "anthropic",
            "modelID": "claude-sonnet-4-6", "tokens": ["input": 5, "output": 10, "reasoning": 2,
                "cache": ["read": 30, "write": 4]]])
        let sql = "INSERT INTO message VALUES (\(time), '\(String(decoding: json, as: UTF8.self))');"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let scan = await OpenCodeReader(root: root).scan()
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertEqual(scan.records.first?.source, .opencode)
        XCTAssertEqual(scan.records.first?.provider, .claude)
        XCTAssertEqual(scan.records.first?.output, 12)
        XCTAssertEqual(scan.records.first?.date.timeIntervalSince1970 ?? 0, Double(time) / 1000, accuracy: 0.001)
    }

    func testExpiredCodexWindowIsUnknownInsteadOfAnInventedZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = CodexLimits(asOf: now.addingTimeInterval(-600), usage: Usage(limits: [
            Limit(id: "session", label: "Session", pct: 83, resetsAt: now.addingTimeInterval(-1), window: 18000),
            Limit(id: "week", label: "Week", pct: 54, resetsAt: now.addingTimeInterval(3600), window: 604800)
        ]), plan: "plus", live: false, credits: nil)
        XCTAssertEqual(limits.current(now: now).limits.map(\.id), ["week"])
        XCTAssertEqual(limits.current(now: now.addingTimeInterval(3600)).limits.count, 0)
    }

    func testCodexCacheBoundsAndLegacyTotalsAreScopedToSession() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let time = ISO8601DateFormatter().string(from: Date())
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            try jsonLine(["timestamp": time, "type": type, "payload": payload])
        }
        let counts = ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10, "total_tokens": 110]
        for id in ["first", "second"] {
            var data = try line("session_meta", ["id": id])
            data += try line("turn_context", ["model": "gpt-5.1"])
            data += try line("event_msg", ["type": "token_count", "info": ["total_token_usage": counts, "last_token_usage": counts]])
            try data.write(to: folder.appendingPathComponent("\(id).jsonl"))
        }
        let scanner = CodexScanner(root: root)
        let legacy = await scanner.scan()
        XCTAssertEqual(legacy.records.count, 2, "Independent sessions can report identical totals at the same time")
        var bounded = try line("session_meta", ["id": "bounded"])
        bounded += try line("token_usage_record", ["session_id": "bounded", "response_id": "bounded-reply",
            "usage": ["input_tokens": 10, "cached_input_tokens": 99, "cache_write_input_tokens": 90,
                "output_tokens": true, "reasoning_output_tokens": -4]])
        try bounded.write(to: folder.appendingPathComponent("bounded.jsonl"))
        let next = await scanner.scan()
        let record = try XCTUnwrap(next.records.first { $0.model == "unknown" })
        XCTAssertEqual(record.input, 0); XCTAssertEqual(record.cacheRead, 10)
        XCTAssertEqual(record.cacheWrite, 0); XCTAssertEqual(record.output, 0)
    }

    func testSourceTotalsKeepOpenCodeInsideProviderAndAccountDaysReplaceSources() {
        let now = isoDate("2026-10-10T12:00:00Z")!, yesterday = now.addingTimeInterval(-86400)
        func record(_ date: Date, _ provider: Provider, _ source: Source, _ count: Int) -> TokenRecord {
            TokenRecord(date: date, model: "fixture-model", provider: provider, source: source,
                        input: count, output: 0, cacheWrite: 0, cacheRead: 0, cost: nil)
        }
        let local = [record(yesterday, .openai, .codex, 10), record(yesterday, .openai, .opencode, 20),
                     record(now, .openai, .opencode, 5), record(now, .claude, .opencode, 99)]
        let measured = summarize(local, provider: .openai, range: .week, metric: .input, now: now)
        XCTAssertEqual(measured.bySource.map(\.name), ["OpenCode", "Codex"])
        XCTAssertEqual(measured.bySource.map(\.value), [25, 10])
        let reconciled = reconciledOpenAIRecords(local: local, account: [record(yesterday, .openai, .chatgpt, 40)])
        let account = summarize(reconciled, provider: .openai, range: .week, metric: .input, now: now, calendar: usageUTCCalendar)
        XCTAssertEqual(account.bySource.map(\.name), ["ChatGPT account", "OpenCode"])
        XCTAssertEqual(account.bySource.map(\.value), [40, 5])
        XCTAssertEqual(account.bySource.reduce(0) { $0 + $1.value }, account.totals[.input])
        XCTAssertNil(Provider(rawValue: "OpenCode"))
    }

    func testAccountReportsReplaceWholeUTCDaysWhileRecentLocalUsageRemains() {
        let first = isoDate("2026-10-01T12:00:00Z")!, next = first.addingTimeInterval(86400)
        func record(_ date: Date, _ source: Source, _ input: Int) -> TokenRecord {
            TokenRecord(date: date, model: "gpt-5.1", provider: .openai, source: source, input: input, output: 0, cacheWrite: 0, cacheRead: 0, cost: 0)
        }
        let result = reconciledOpenAIRecords(local: [record(first, .codex, 10), record(first, .opencode, 20), record(next, .codex, 5)], account: [record(first, .chatgpt, 40)])
        XCTAssertEqual(result.map(\.input).sorted(), [5, 40])
    }

    @MainActor func testLastGoodLimitsAndGlobalCooldownSurviveAccountChangeAndRestart() throws {
        let suite = "frog-usage-gate-\(UUID().uuidString)", now = Date()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = ClaudePollingState()
        XCTAssertTrue(state.begin(at: now))
        state.succeeded(Usage(limits: [Limit(id: "session", label: "Session", pct: 34, resetsAt: now.addingTimeInterval(5000), window: 18000)]), at: now)
        state.failed(FetchError.http(429, retryAfter: 7200, message: nil), at: now)
        state.save(to: defaults)
        let restored = Store(defaults: defaults)
        XCTAssertEqual(restored.displayUsage(now: now)?.limits.first?.pct, 34)
        restored.setLoginSource(.pi)
        XCTAssertNil(restored.usage)
        XCTAssertEqual(restored.nextFetchAt, now.addingTimeInterval(7200))
        var restarted = ClaudePollingState.load(from: defaults)
        XCTAssertFalse(restarted.begin(at: now.addingTimeInterval(7199)))
        XCTAssertTrue(restarted.begin(at: now.addingTimeInterval(7200)))
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func jsonLine(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) + Data([10]) }
}
