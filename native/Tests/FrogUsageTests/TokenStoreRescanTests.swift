import Combine
import Foundation
import SQLite3
import XCTest
@testable import FrogUsage

/// What a scan may publish when the logs did not change since the last one. Synthetic logs of
/// all four tools in a temporary folder; nothing reads this Mac's own.
@MainActor final class TokenStoreRescanTests: XCTestCase {
    func testAScanThatFindsNothingNewPublishesNothing() async throws {
        let logs = try Logs()
        defer { logs.remove() }
        // A new hour beginning in the middle of the test would be a reason to publish.
        let now = Date()
        let store = TokenStore(fixtureRoot: logs.root, clock: { now })
        store.start()
        defer { store.stop() }
        await settled(store)
        XCTAssertTrue(store.loaded)
        XCTAssertEqual(store.summary(.claude, account: false, range: .week, metric: .input).totals[.input], 42 + 7)
        XCTAssertEqual(store.summary(.openai, account: true, range: .week, metric: .input).totals[.input], 10 + 100)

        var published = 0
        let observation = store.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        for _ in 0..<3 {
            store.refresh(forceLocal: true)
            await settled(store)
        }
        XCTAssertEqual(published, 0, "Unchanged logs are no reason to redraw every usage view and the menu bar readout")
        XCTAssertEqual(store.summary(.claude, account: false, range: .week, metric: .input).totals[.input], 42 + 7)
    }

    func testNewActivityInAnyToolsLogIsShownAfterScansThatFoundNothing() async throws {
        let logs = try Logs()
        defer { logs.remove() }
        let store = TokenStore(fixtureRoot: logs.root)
        store.start()
        defer { store.stop() }
        func rescanned() async -> [Double?] {
            store.refresh(forceLocal: true)
            await settled(store)
            return [store.summary(.claude, account: false, range: .week, metric: .input).totals[.input],
                    store.summary(.openai, account: true, range: .week, metric: .input).totals[.input]]
        }
        var totals = await rescanned()
        XCTAssertEqual(totals, [49, 110])
        totals = await rescanned()
        XCTAssertEqual(totals, [49, 110])
        try logs.addClaude(input: 1000)
        totals = await rescanned()
        XCTAssertEqual(totals, [1049, 110])
        try logs.addPi(input: 2000)
        totals = await rescanned()
        XCTAssertEqual(totals, [3049, 110])
        try logs.addCodex(input: 3000)
        totals = await rescanned()
        XCTAssertEqual(totals, [3049, 3110])
        XCTAssertEqual(Set(store.records.filter { $0.source == .codex }.map(\.model)), ["gpt-5.1"], "Codex's calls carry their session's model")
        try logs.addOpenCode(input: 4000)
        totals = await rescanned()
        XCTAssertEqual(totals, [3049, 7110])
    }

    /// Claude Code busy in two accounts writes new lines faster than the store sums up a month of
    /// them, and the open page or popup scans every ten seconds. Each scan here brings a line.
    func testTheChartsAreShownWhileNewLinesKeepArrivingDuringTheirSummary() async throws {
        let logs = try Logs()
        defer { logs.remove() }
        // Enough calls that many scans land while one summary is worked out.
        try logs.addClaude(input: 1, count: 20_000)
        let store = TokenStore(fixtureRoot: logs.root)
        store.start()
        defer { store.stop() }
        // A Mac busy elsewhere takes many seconds for one summary; without the fix none is ever shown.
        let deadline = Date().addingTimeInterval(60)
        var added = 0
        while !store.loaded, Date() < deadline {
            try logs.addClaude(input: 1000)
            added += 1
            store.refresh(forceLocal: true)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.loaded, "Still “Reading token activity…” after \(added) scans with new lines")
        await settled(store)
        XCTAssertEqual(store.summary(.claude, account: false, range: .week, metric: .input).totals[.input],
                       Double(42 + 7 + 20_000 + 1000 * added), "The last summary has every line")
    }

    func testChartsRollOverWithTheClockWhileTheLogsStayAsTheyWere() async throws {
        let logs = try Logs()
        defer { logs.remove() }
        final class Clock { var now = Date() }
        let clock = Clock()
        let store = TokenStore(fixtureRoot: logs.root, clock: { clock.now })
        store.start()
        defer { store.stop() }
        await settled(store)
        func day() -> TokenSummary { store.summary(.claude, account: false, range: .day, metric: .input) }
        func hour(_ date: Date) throws -> Date { try XCTUnwrap(Calendar.current.dateInterval(of: .hour, for: date)).start }
        XCTAssertEqual(day().buckets.last?.start, try hour(clock.now))
        XCTAssertEqual(day().buckets.last?.value, 49)

        var published = 0
        let observation = store.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        clock.now += 3600
        store.refresh(forceLocal: true)
        await settled(store)
        XCTAssertEqual(day().buckets.last?.start, try hour(clock.now), "A new hour has begun")
        XCTAssertEqual(day().buckets.last?.value, 0)
        XCTAssertEqual(day().totals[.input], 49)
        XCTAssertEqual(published, 1, "Only the summaries changed")

        // A day later the calls have left the 24 hours and moved one day back in the week.
        clock.now += 86_400
        store.refresh(forceLocal: true)
        await settled(store)
        XCTAssertEqual(day().totals[.input] ?? 0, 0)
        let week = store.summary(.claude, account: false, range: .week, metric: .input)
        XCTAssertEqual(week.totals[.input], 49)
        XCTAssertEqual(week.buckets.last?.value, 0)
        XCTAssertEqual(week.buckets.last?.start, Calendar.current.startOfDay(for: clock.now))
        let account = store.summary(.openai, account: true, range: .week, metric: .input)
        XCTAssertEqual(account.buckets.last?.start, usageUTCCalendar.startOfDay(for: clock.now), "The account's days are UTC days")
        XCTAssertEqual(account.totals[.input], 110)
    }

    func testReadingAndSummarisingTheLogsYieldToWhatThePersonIsDoing() async throws {
        let logs = try Logs()
        defer { logs.remove() }
        // The store reads its clock inside the aggregation and inside a scan that found nothing
        // new, which shows the priority each of the two was started with.
        var priorities: [TaskPriority?] = []
        let store = TokenStore(fixtureRoot: logs.root, clock: { priorities.append(Task.basePriority); return Date() })
        store.start()
        defer { store.stop() }
        await settled(store)
        // Claude Code's records are shown before the other tools', so this may summarise twice.
        XCTAssertFalse(priorities.isEmpty, "The aggregation")
        XCTAssertEqual(priorities.filter { $0 != .utility }, [], "The aggregation")
        store.refresh(forceLocal: true)
        await settled(store)
        XCTAssertEqual(priorities.last, .utility, "The scan")
        XCTAssertGreaterThan(priorities.count, 1)
        // The aggregation above was started by the scan, whose priority it would inherit anyway.
        // Started again with records already scanned, it begins straight from the main actor.
        store.stop(); priorities = []
        store.start()
        await settled(store)
        XCTAssertEqual(priorities.first, .utility, "An aggregation started from the main actor")
    }

    /// Waits for the scan that is under way, the aggregation it asked for, and a scan that was
    /// asked for meanwhile.
    private func settled(_ store: TokenStore) async {
        var finished: Task<Void, Never>?
        while let scan = store.scanTask, scan != finished {
            await scan.value
            finished = scan
        }
        await store.aggregationTask?.value
    }
}

/// One model call in the log of each tool.
@MainActor private final class Logs {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var database: OpaquePointer?
    private var calls = 0

    init() throws {
        for folder in ["claude", "codex/sessions", "opencode", "pi"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        guard sqlite3_open(root.appendingPathComponent("opencode/opencode.db").path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: 1)
        }
        try sql("PRAGMA journal_mode=WAL;")
        try sql("CREATE TABLE session_message (id TEXT, type TEXT, time_created INTEGER, data TEXT);")
        try addClaude(input: 42); try addPi(input: 7); try addCodex(input: 10); try addOpenCode(input: 100)
    }
    func remove() {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: root)
    }

    func addClaude(input: Int) throws {
        try append("claude/session.jsonl", claudeCall(input: input))
    }
    /// `count` calls written at once, for a month of busy logs.
    func addClaude(input: Int, count: Int) throws {
        try append("claude/session.jsonl", (0..<count).map { _ in claudeCall(input: input) })
    }
    private func claudeCall(input: Int) -> [String: Any] {
        ["type": "assistant", "timestamp": stamp(),
         "message": ["id": name(), "model": "claude-sonnet-4-6", "usage": ["input_tokens": input]]]
    }
    func addPi(input: Int) throws {
        try append("pi/session.jsonl", ["type": "message", "id": name(), "timestamp": stamp(),
            "message": ["role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-6",
                        "timestamp": (Date().timeIntervalSince1970 * 1000).rounded() - Double(calls),
                        "usage": ["input": input, "output": 0]]])
    }
    func addCodex(input: Int) throws {
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("codex/sessions/rollout-fixture.jsonl").path) {
            try append("codex/sessions/rollout-fixture.jsonl", ["type": "session_meta", "timestamp": stamp(),
                "payload": ["id": "fixture", "model_provider": "openai"]])
            try append("codex/sessions/rollout-fixture.jsonl", ["type": "turn_context", "timestamp": stamp(), "payload": ["model": "gpt-5.1"]])
        }
        try append("codex/sessions/rollout-fixture.jsonl", ["type": "token_usage_record", "timestamp": stamp(),
            "payload": ["session_id": "fixture", "response_id": name(), "usage": ["input_tokens": input, "output_tokens": 0]]])
    }
    func addOpenCode(input: Int) throws {
        let time = Int64(Date().timeIntervalSince1970 * 1000) - Int64(calls)
        let data = "{\"model\":{\"providerID\":\"openai\",\"id\":\"gpt-5.1\"},\"time\":{\"created\":\(time),\"completed\":\(time)},\"tokens\":{\"input\":\(input)}}"
        try sql("INSERT INTO session_message VALUES ('\(name())', 'assistant', \(time), '\(data)');")
    }

    private func name() -> String { calls += 1; return "call-\(calls)" }
    private func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func sql(_ statement: String) throws {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: 2) }
    }
    private func append(_ path: String, _ line: [String: Any]) throws { try append(path, [line]) }
    private func append(_ path: String, _ lines: [[String: Any]]) throws {
        let url = root.appendingPathComponent(path)
        let data = try lines.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1) + Data([10]) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return try data.write(to: url) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
