import Foundation
import FrogTestSupport
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
        let summary = summarizeMetrics(complete, provider: .claude, range: .week, now: now.addingTimeInterval(1))[.input] ?? TokenSummary()
        XCTAssertEqual(summary.totalTokens, 231)
        XCTAssertEqual(summary.buckets.reduce(0) { $0 + $1.value }, 6)
    }

    /// A month of logs takes minutes to read after a launch; the newest file comes first and
    /// each slice is handed back, so today's calls show before the older ones are read.
    func testScanReadsTheNewestTranscriptFirstAndStopsAtTheDeadline() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        for (name, age) in [("old", 5 * 86_400.0), ("new", 60.0)] {
            let file = root.appendingPathComponent("\(name).jsonl")
            try jsonLine(["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age)),
                "message": ["id": name, "model": "claude-opus-5-5", "usage": ["input_tokens": 1_000, "output_tokens": 100]]]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        let scanner = TokenScanner(root: root)
        let first = await scanner.revisedScan(roots: [root], until: .distantPast)
        XCTAssertFalse(first.complete)
        XCTAssertEqual(first.result.map(\.model), ["claude-opus-5-5"])
        XCTAssertEqual(first.result.first?.input, 1_000)
        XCTAssertEqual(first.result.first?.cost ?? 0, 0.006, accuracy: 1e-9, "1,000 input at $4 and 100 output at $20 per million")
        XCTAssertGreaterThan(first.result.first?.date ?? .distantPast, now.addingTimeInterval(-3_600), "The newest file is read first")
        let rest = await scanner.revisedScan(roots: [root], until: .distantPast)
        XCTAssertTrue(rest.complete)
        XCTAssertEqual(rest.result.count, 2)
        XCTAssertGreaterThan(rest.revision, first.revision)
    }

    func testLogLinesCrossingAReadBoundaryAreNeitherLostNorSplitNorReadTwice() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.jsonl")
        let lines = ["first", "", "a line that is longer than every small read below", "x", "", "{\"k\":1}"]
        let written = lines.joined(separator: "\n") + "\n", unfinished = "still being wri"
        // Every byte, the byte before a newline, the newline itself and the byte after it end a read.
        for chunk in [1, 2, 3, 5, 6, 7, 16, 64, 1 << 20] {
            try Data((written + unfinished).utf8).write(to: file)
            var seen: [String] = []
            let consumed = usageLines(in: file, from: 0, chunk: chunk) { seen.append(String(decoding: $0, as: UTF8.self)) }
            XCTAssertEqual(seen, lines, "reads of \(chunk)")
            XCTAssertEqual(consumed, UInt64(written.utf8.count), "The unfinished last line waits for the next pass")
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("tten\nlast\n".utf8)); try handle.close()
            seen = []
            let rest = usageLines(in: file, from: consumed, chunk: chunk) { seen.append(String(decoding: $0, as: UTF8.self)) }
            XCTAssertEqual(seen, ["still being written", "last"], "reads of \(chunk)")
            XCTAssertEqual(consumed + rest, UInt64((written + unfinished).utf8.count + 10))
            XCTAssertEqual(usageLines(in: file, from: consumed + rest, chunk: chunk) { _ in XCTFail("Nothing is left") }, 0)
        }
        XCTAssertEqual(usageLines(in: root.appendingPathComponent("missing.jsonl"), from: 0) { _ in XCTFail("No file") }, 0)
    }

    func testTranscriptLargerThanOneReadCountsEveryResponseOnce() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = ISO8601DateFormatter().string(from: Date()), responses = 1200
        var data = Data()
        for index in 0..<responses {
            // Tool output between two replies, of a length that moves the line ends around.
            data += try jsonLine(["type": "user", "timestamp": time, "content": String(repeating: "o", count: 900 + index % 257)])
            data += try jsonLine(["type": "assistant", "timestamp": time,
                "message": ["id": "reply-\(index)", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 1, "output_tokens": index]]])
        }
        XCTAssertGreaterThan(data.count, 1 << 20, "The fixture has to span more than one read")
        let partial = try jsonLine(["type": "assistant", "timestamp": time,
            "message": ["id": "unfinished", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 1, "output_tokens": 7]]])
        try (data + partial.dropLast()).write(to: root.appendingPathComponent("large.jsonl"))
        let scanner = TokenScanner(root: root)
        let first = await scanner.scan(), repeated = await scanner.scan()
        XCTAssertEqual(first.count, responses)
        XCTAssertEqual(first.reduce(0) { $0 + $1.output }, responses * (responses - 1) / 2)
        XCTAssertEqual(repeated.count, responses)
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

    func testLoggedCodexLimitsAreAsOldAsTheirMainPlanSnapshot() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let main = now.addingTimeInterval(-3600), model = now.addingTimeInterval(-300)
        func snapshot(at date: Date, _ limits: [String: Any]) throws -> Data {
            try jsonLine(["timestamp": ISO8601DateFormatter().string(from: date), "type": "event_msg",
                          "payload": ["type": "token_count", "rate_limits": limits]])
        }
        let window = ["used_percent": 40, "window_minutes": 300, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970]
        var data = try snapshot(at: main, ["primary": window, "plan_type": "plus"])
        // A model with its own allowance logs its own limit id, later than the main plan's.
        data += try snapshot(at: model, ["limit_id": "codex_fixture_model", "limit_name": "Fixture model", "primary": window])
        try data.write(to: folder.appendingPathComponent("rollout.jsonl"))
        let scanned = await CodexScanner(root: root).scan()
        let limits = try XCTUnwrap(scanned.limits)
        XCTAssertEqual(limits.usage.limits.count, 2)
        XCTAssertEqual(limits.asOf, main, "A newer live reading of the main plan must not lose to an older logged one")

        let other = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try snapshot(at: model, ["limit_id": "codex_fixture_model", "primary": window])
            .write(to: other.appendingPathComponent("sessions/rollout.jsonl"))
        let alone = await CodexScanner(root: other).scan()
        XCTAssertEqual(alone.limits?.asOf, model, "Without a main plan snapshot the newest one dates the set")
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
        let measured = summarizeMetrics(local, provider: .openai, range: .week, now: now)[.input] ?? TokenSummary()
        XCTAssertEqual(measured.bySource.map(\.name), ["OpenCode", "Codex"])
        XCTAssertEqual(measured.bySource.map(\.value), [25, 10])
        let reconciled = reconciledOpenAIRecords(local: local, account: [record(yesterday, .openai, .chatgpt, 40)])
        let account = summarizeMetrics(reconciled, provider: .openai, range: .week, now: now, calendar: usageUTCCalendar)[.input] ?? TokenSummary()
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

    func testAnEmptyAccountDayAfterTheReportsOwnDateIsNotYetReported() throws {
        let activity = try XCTUnwrap(parseAccountActivity(["stats": ["lifetime_tokens": 40.0, "daily_usage_buckets": [
            ["start_date": "2026-09-30", "tokens": 40], ["start_date": "2026-10-01", "tokens": 0],
            ["start_date": "2026-10-02", "tokens": 0]]], "metadata": ["stats_as_of": "2026-10-01"]], breakdown: nil))
        func local(_ time: String, _ input: Int) -> TokenRecord {
            TokenRecord(date: isoDate(time)!, model: "gpt-5.1", provider: .openai, source: .codex, input: input, output: 0, cacheWrite: 0, cacheRead: 0, cost: 0)
        }
        let result = reconciledOpenAIRecords(local: [local("2026-09-30T12:00:00Z", 10), local("2026-10-01T12:00:00Z", 20),
                                                     local("2026-10-02T12:00:00Z", 5)],
                                             account: estimatedRecords(activity, mix: .codex), asOf: activity.asOf)
        XCTAssertEqual(result.filter { $0.source == .codex }.map(\.input), [5],
                       "A zero up to the report's date is reported; one after it has not been aggregated yet")
    }

    @MainActor func testLastGoodLimitsAndGlobalCooldownSurviveAccountChangeAndRestart() throws {
        let now = Date()
        let defaults = temporaryDefaults()
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

    func testPollSlowedByThrottlingEasesBackAnHourAtATimeAlsoAcrossARestart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000), hour: TimeInterval = 3600
        let limited = FetchError.http(429, retryAfter: nil, message: nil)
        var state = ClaudePollingState()
        for _ in 0..<5 { state.failed(limited, at: start) }
        XCTAssertEqual(state.interval, 600)
        // What throttling taught is kept while it is recent, so the poll does not swing back into it.
        state.succeeded(Usage(), at: start.addingTimeInterval(600))
        state.succeeded(Usage(), at: start.addingTimeInterval(hour - 1))
        XCTAssertEqual(state.interval, 600)
        state.succeeded(Usage(), at: start.addingTimeInterval(hour))
        XCTAssertEqual(state.interval, 300, "An hour without throttling takes one step back")
        state.succeeded(Usage(), at: start.addingTimeInterval(hour + 600))
        XCTAssertEqual(state.interval, 300, "The next step waits another hour")
        state.failed(limited, at: start.addingTimeInterval(hour + 900))
        XCTAssertEqual(state.interval, 600)
        state.succeeded(Usage(), at: start.addingTimeInterval(2 * hour))
        XCTAssertEqual(state.interval, 600, "Throttled again: the hour starts over")
        // A clock set back must not leave the slower pace waiting for a time far ahead.
        var setBack = state
        setBack.succeeded(Usage(), at: start.addingTimeInterval(-24 * hour))
        setBack.succeeded(Usage(), at: start.addingTimeInterval(-23 * hour))
        XCTAssertEqual(setBack.interval, 300)
        for step in 1...4 { state.succeeded(Usage(), at: start.addingTimeInterval(hour + 900 + Double(step) * hour)) }
        XCTAssertEqual(state.interval, 60)
        XCTAssertTrue(state.begin(at: start.addingTimeInterval(9 * hour)))
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(9 * hour + 60), "Every minute again")
        // Hours in which nothing was asked, without a login for example, are quiet hours too.
        var unasked = ClaudePollingState()
        for _ in 0..<5 { unasked.failed(limited, at: start) }
        unasked.succeeded(Usage(), at: start.addingTimeInterval(3 * hour))
        XCTAssertEqual(unasked.interval, 75, "A step for each of the three quiet hours")

        let defaults = temporaryDefaults()
        var slowed = ClaudePollingState()
        for _ in 0..<5 { slowed.failed(FetchError.http(429, retryAfter: 7200, message: nil), at: start) }
        slowed.save(to: defaults)
        XCTAssertEqual(ClaudePollingState.load(from: defaults, now: start.addingTimeInterval(60)).interval, 600)
        var paused = ClaudePollingState.load(from: defaults, now: start.addingTimeInterval(2.5 * hour))
        XCTAssertEqual(paused.interval, 150, "A start after a pause takes a step for every hour of it")
        paused.succeeded(Usage(), at: start.addingTimeInterval(3 * hour))
        XCTAssertEqual(paused.interval, 75, "The half hour already gone counts towards the next step")
        let later = ClaudePollingState.load(from: defaults, now: start.addingTimeInterval(8 * hour))
        XCTAssertEqual(later.interval, 60, "A start long after the throttling is back at every minute")
        XCTAssertEqual(later.nextFetchAt, start.addingTimeInterval(7200), "The server's own wait is never shortened")
        // An earlier version saved the slower pace without saying when it was learned.
        var earlier = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(slowed)) as? [String: Any])
        earlier["slowedAt"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: earlier), forKey: ClaudePollingState.defaultsKey)
        let restored = ClaudePollingState.load(from: defaults, now: start.addingTimeInterval(60))
        XCTAssertEqual(restored.interval, 60, "A pace kept for good counts as learned long ago")
    }

    func testAnOutageDelaysThePollWithoutTeachingItASlowerPace() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let down = FetchError.http(503, retryAfter: nil, message: nil)
        var state = ClaudePollingState()
        XCTAssertTrue(state.begin(at: start))
        state.failed(down, at: start)
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(120))
        state.failed(down, at: start); state.failed(down, at: start)
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(480), "Longer waits while the outage lasts")
        for _ in 0..<5 { state.failed(down, at: start) }
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(600), "Ten minutes at most")
        state.failed(FetchError.http(502, retryAfter: 1800, message: nil), at: start)
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(1800), "Never sooner than the server asks")
        XCTAssertEqual(state.interval, 60, "An outage says nothing about how often the server may be asked")
        state.succeeded(Usage(), at: start.addingTimeInterval(1800))
        XCTAssertTrue(state.begin(at: start.addingTimeInterval(1800)))
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(1860), "Every minute again once the service answers")
        state.failed(down, at: start.addingTimeInterval(1900))
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(1900 + 120), "A new outage starts with the short wait")
        // A pace learned from throttling is kept through an outage, neither lengthened nor forgotten.
        let limited = FetchError.http(429, retryAfter: nil, message: nil)
        state.failed(limited, at: start.addingTimeInterval(2000)); state.failed(limited, at: start.addingTimeInterval(2000))
        XCTAssertEqual(state.interval, 240)
        state.failed(down, at: start.addingTimeInterval(2100))
        XCTAssertEqual(state.interval, 240)
        XCTAssertEqual(state.nextFetchAt, start.addingTimeInterval(2100 + 480))
    }

    func testChatGPTLimitsAreAskedForAtTheUsualPaceAgainAfterAnAnswer() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var schedule = LiveFetchSchedule()
        XCTAssertTrue(schedule.begin(at: start))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(119)))
        schedule.failed(FetchError.http(429, retryAfter: nil, message: nil), at: start)
        schedule.failed(FetchError.http(503, retryAfter: nil, message: nil), at: start)
        schedule.failed(FetchError.badJSON, at: start)
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(479)))
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(480)))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(480 + 479)), "Slower until the service answers")
        schedule.succeeded()
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(960)))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(960 + 119)))
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(960 + 120)), "Two minutes again after an answer")
        schedule.failed(FetchError.http(429, retryAfter: 3600, message: nil), at: start.addingTimeInterval(1080))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(1080 + 3599)), "Never sooner than the server asks")
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(1080 + 3600)))
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func jsonLine(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) + Data([10]) }
}
