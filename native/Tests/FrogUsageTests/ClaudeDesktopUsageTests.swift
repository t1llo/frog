import XCTest
@testable import FrogUsage

/// Synthetic histories only; no test reads the Claude app's real file.
@MainActor final class ClaudeDesktopUsageTests: XCTestCase {
    /// A whole half hour, so inferred renewals are exact.
    private let base: TimeInterval = 1_800_000_000

    private func history(version: Int = 2, _ samples: [(offset: TimeInterval, org: String?, used: [String: Any])]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "samples": samples.map { sample -> [String: Any] in
            var entry: [String: Any] = ["t": (base + sample.offset) * 1000]
            if let org = sample.org { entry["org"] = org }
            if version == 1 { entry.merge(sample.used) { $1 } } else { entry["u"] = sample.used }
            return entry
        }])
    }

    func testNewestSampleOfBothVersionsBecomesTheReading() throws {
        for version in [1, 2] {
            let data = try history(version: version, [
                (-600, "org-a", ["fh": 10, "sd": 20]),
                (0, "org-a", ["fh": 12.5, "sd": 140, "so": 7, "sn": -3, "xu": 55]),
            ])
            let reading = try XCTUnwrap(ClaudeDesktopUsage.reading(from: data), "version \(version)")
            XCTAssertEqual(reading.observedAt, Date(timeIntervalSince1970: base))
            XCTAssertEqual(reading.organization, "org-a")
            XCTAssertEqual(reading.limits.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"])
            XCTAssertEqual(reading.limits.map(\.pct), [12.5, 100, 0, 7], "Percentages are kept inside 0...100")
            XCTAssertEqual(reading.limits.map(\.label), ["Session", "Week", "Week · Sonnet", "Week · Opus"])
        }
    }

    func testUnknownFormatsAreSkippedInsteadOfGuessed() throws {
        XCTAssertNil(ClaudeDesktopUsage.reading(from: try history(version: 3, [(0, nil, ["fh": 10])])))
        XCTAssertNil(ClaudeDesktopUsage.reading(from: try history([(0, nil, ["unknown": 10])])))
        XCTAssertNil(ClaudeDesktopUsage.reading(from: Data("not json".utf8)))
        XCTAssertNil(ClaudeDesktopUsage.reading(from: try history([])))
    }

    func testRenewalsAreInferredOnlyFromCloseReadingsOfTheSameAccount() throws {
        let pinned = try XCTUnwrap(ClaudeDesktopUsage.reading(from: try history([
            (-900, "org-a", ["fh": 0, "sd": 80]),
            // Another account's readings in between say nothing about this one.
            (-300, "org-b", ["fh": 90, "sd": 1]),
            (300, "org-a", ["fh": 4, "sd": 2]),
            (900, "org-a", ["fh": 9, "sd": 3]),
        ])))
        XCTAssertEqual(pinned.limits.first { $0.id == "five_hour" }?.resetsAt, Date(timeIntervalSince1970: base + 5 * 3600))
        XCTAssertEqual(pinned.limits.first { $0.id == "seven_day" }?.resetsAt, Date(timeIntervalSince1970: base + 7 * 86_400))

        // Hours between the readings: when the session opened or the week renewed is unknown.
        let loose = try XCTUnwrap(ClaudeDesktopUsage.reading(from: try history([
            (-4 * 3600, "org-a", ["fh": 0, "sd": 80]),
            (300, "org-a", ["fh": 4, "sd": 2]),
        ])))
        XCTAssertEqual(loose.limits.map(\.resetsAt), [nil, nil])
    }

    func testReadingExpiresWithItsWindows() {
        let seen = Date(timeIntervalSince1970: base)
        let reading = ClaudeDesktopReading(observedAt: seen, organization: nil, limits: [
            Limit(id: "five_hour", label: "Session", pct: 40, resetsAt: nil, window: 5 * 3600),
            Limit(id: "seven_day", label: "Week", pct: 60, resetsAt: seen.addingTimeInterval(3 * 86_400), window: 7 * 86_400),
            Limit(id: "seven_day_opus", label: "Week · Opus", pct: 5, resetsAt: nil, window: 7 * 86_400),
        ])
        XCTAssertEqual(reading.usage(at: seen.addingTimeInterval(3600))?.limits.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
        // A session percentage without a renewal time is only current within one session.
        XCTAssertEqual(reading.usage(at: seen.addingTimeInterval(6 * 3600))?.limits.map(\.id), ["seven_day", "seven_day_opus"])
        XCTAssertEqual(reading.usage(at: seen.addingTimeInterval(2 * 86_400))?.limits.map(\.id), ["seven_day"])
        XCTAssertNil(reading.usage(at: seen.addingTimeInterval(4 * 86_400)))
        XCTAssertNil(reading.usage(at: seen.addingTimeInterval(-3600)), "A reading from the future is a wrong clock, not a reading")
    }

    func testHistoryIsReadFromTheClaudeAppFolderAndPlanOnlyFromTheSameOrganization() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("frog-desktop-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = ClaudeDesktopUsage.historyURL(home: home), claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        XCTAssertNil(readClaudeDesktop(home: home, directory: claude))
        try history([(0, "org-a", ["fh": 10])]).write(to: file)
        XCTAssertEqual(readClaudeDesktop(home: home, directory: claude)?.limits.map(\.pct), [10])
    }

    /// Rewrites `url` in place, so the file stays the same one and only what the test changes differs.
    private func rewrite(_ url: URL, with data: Data, modified: Date) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testFilesAreReadAgainOnlyOnceTheyChanged() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("frog-desktop-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = ClaudeDesktopUsage.historyURL(home: home), claude = home.appendingPathComponent(".claude")
        let profile = claude.appendingPathComponent(".claude.json"), files = ClaudeDesktopFiles()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let saved = Date(timeIntervalSince1970: base), later = saved.addingTimeInterval(60)
        func account(_ type: String) -> Data { Data(#"{"oauthAccount":{"organizationUuid":"org-a","organizationType":"\#(type)"}}"#.utf8) }
        func read() -> ClaudeDesktopReading? { readClaudeDesktop(home: home, directory: claude, files: files) }

        try rewrite(file, with: history([(0, "org-a", ["fh": 10])]), modified: saved)
        try rewrite(profile, with: account("claude_max"), modified: saved)
        XCTAssertEqual(read()?.limits.map(\.pct), [10])
        XCTAssertEqual(read()?.plan, "Max")

        // Same size and modification time: the reading already made from it is kept.
        try rewrite(file, with: history([(0, "org-a", ["fh": 20])]), modified: saved)
        try rewrite(profile, with: account("claude_pro"), modified: saved)
        XCTAssertEqual(read()?.limits.map(\.pct), [10])
        XCTAssertEqual(read()?.plan, "Max")

        // A new modification time, or a new size, is a changed file.
        try rewrite(file, with: history([(0, "org-a", ["fh": 20])]), modified: later)
        XCTAssertEqual(read()?.limits.map(\.pct), [20])
        try rewrite(file, with: history([(0, "org-a", ["fh": 5])]), modified: later)
        XCTAssertEqual(read()?.limits.map(\.pct), [5])
        try rewrite(profile, with: account("claude_pro"), modified: later)
        XCTAssertEqual(read()?.plan, "Pro")

        // A file the Claude app could not have written is not read at all.
        try rewrite(file, with: Data(count: 5 << 20), modified: saved)
        XCTAssertNil(read())
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(read())
    }

    private func store(account: Usage?, accountAge: TimeInterval = 0, identity: String = "claudeCode|dir|account|org-a",
                       desktop: ClaudeDesktopReading?, now: Date, reads: Counter = Counter()) -> (Store, UserDefaults, String) {
        let suite = "frog-usage-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        if let account {
            var state = ClaudePollingState()
            state.selectIdentity(ClaudeAuth(token: "fixture", source: .claudeCode, identity: identity, label: "Fixture", hasAccountMetadata: true))
            state.succeeded(account, at: now.addingTimeInterval(-accountAge))
            state.save(to: defaults)
        }
        let store = Store(defaults: defaults, readAuth: { _, _ in reads.increment(); return nil },
                          readDesktop: { _ in desktop }, currentDate: { now })
        return (store, defaults, suite)
    }

    private func desktopReading(age: TimeInterval, now: Date, session: Double = 55) -> ClaudeDesktopReading {
        ClaudeDesktopReading(observedAt: now.addingTimeInterval(-age), organization: "org-a", limits: [
            Limit(id: "five_hour", label: "Session", pct: session, resetsAt: nil, window: 5 * 3600),
            Limit(id: "seven_day", label: "Week", pct: 30, resetsAt: nil, window: 7 * 86_400),
        ], plan: "Max")
    }

    private func accountUsage(now: Date) -> Usage {
        Usage(limits: [
            Limit(id: "five_hour", label: "Session", pct: 20, resetsAt: now.addingTimeInterval(3 * 3600), window: 5 * 3600),
            Limit(id: "seven_day", label: "Week", pct: 25, resetsAt: now.addingTimeInterval(4 * 86_400), window: 7 * 86_400),
        ])
    }

    private func started(_ store: Store, expectDesktop: Bool = true) async throws {
        store.start()
        for _ in 0..<200 where store.inFlight || (expectDesktop && store.desktop == nil) { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testAutomaticShowsTheNewerReadingAndBorrowsTheAccountsRenewalTimes() async throws {
        let now = Date(timeIntervalSince1970: base)
        let (store, defaults, suite) = store(account: accountUsage(now: now), accountAge: 1200, desktop: desktopReading(age: 120, now: now), now: now)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        try await started(store)
        let shown = try XCTUnwrap(store.reading())
        XCTAssertEqual(shown.source, .desktop)
        XCTAssertEqual(shown.usage.limits.map(\.pct), [55, 30])
        XCTAssertEqual(shown.usage.limits.map(\.resetsAt), [now.addingTimeInterval(3 * 3600), now.addingTimeInterval(4 * 86_400)])
        XCTAssertEqual(store.plan, "Max")
        XCTAssertNil(store.warning, "A reading the Claude app saved minutes ago is current even when the login failed")
    }

    func testAutomaticKeepsTheAccountReadingWhileItIsNewer() async throws {
        let now = Date(timeIntervalSince1970: base)
        let saved = desktopReading(age: 5400, now: now)
        let (store, defaults, suite) = store(account: accountUsage(now: now), accountAge: 600, desktop: saved, now: now)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        try await started(store)
        XCTAssertEqual(store.reading()?.source, .account)
        XCTAssertEqual(store.displayUsage()?.limits.map(\.pct), [20, 25])
        // The Claude app's own saving cannot be kept going from outside it, so the advice
        // is the one thing that works: a Claude Code login Frog can check with.
        let warning = try XCTUnwrap(store.warning)
        XCTAssertTrue(warning.hasPrefix("Claude Code is not signed in on this Mac"), warning)
        XCTAssertTrue(warning.contains("Sign in to Claude Code"), warning)
        XCTAssertFalse(warning.contains("menu bar icon"), warning)
        XCTAssertFalse(warning.contains("Sign in there"), warning)
        XCTAssertTrue(store.needsClaudeCodeLogin)
    }

    func testAnotherAccountsRenewalTimesAreNotBorrowed() async throws {
        let now = Date(timeIntervalSince1970: base)
        let (store, defaults, suite) = store(account: accountUsage(now: now), accountAge: 1200, identity: "claudeCode|dir|account|org-b",
                                             desktop: desktopReading(age: 120, now: now), now: now)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        try await started(store)
        XCTAssertEqual(store.reading()?.usage.limits.map(\.resetsAt), [nil, nil])
    }

    func testClaudeDesktopSourceNeverReadsALoginAndFlagsAStaleReading() async throws {
        let now = Date(timeIntervalSince1970: base), reads = Counter()
        let (store, defaults, suite) = store(account: nil, desktop: desktopReading(age: 3 * 3600, now: now), now: now, reads: reads)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.setLoginSource(.claudeDesktop)
        try await started(store)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(store.reading()?.source, .desktop)
        XCTAssertEqual(store.displayUsage()?.limits.map(\.pct), [55, 30])
        XCTAssertEqual(store.warning?.contains("Sign in to Claude Code"), true)
        XCTAssertTrue(store.needsClaudeCodeLogin)
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: "claudeLoginSource"), "Claude Desktop")
    }

    func testClaudeDesktopSourceWithoutAReadingSaysHowToGetOne() async throws {
        let now = Date(timeIntervalSince1970: base)
        let (store, defaults, suite) = store(account: accountUsage(now: now), desktop: nil, now: now)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.setLoginSource(.claudeDesktop)
        try await started(store, expectDesktop: false)
        XCTAssertNil(store.reading(), "Limits read with another login are not shown as the Claude app's")
        XCTAssertEqual(store.warning?.hasPrefix("No current reading from the Claude app."), true)
        XCTAssertEqual(store.status.contains("only while its menu-bar icon is on and was opened recently"), true)
        XCTAssertEqual(store.status.hasSuffix("Sign in to Claude Code and Frog checks them itself."), true)
    }

    func testSavedAccountLimitsStayUntilTheirWindowRenewsForADayAtMost() async throws {
        let now = Date(timeIntervalSince1970: base)
        let (store, defaults, suite) = store(account: accountUsage(now: now), desktop: nil, now: now)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.reading(now: now.addingTimeInterval(2 * 3600))?.usage.limits.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(store.reading(now: now.addingTimeInterval(10 * 3600))?.usage.limits.map(\.id), ["seven_day"],
                       "A renewed session is unknown, not an invented zero")
        XCTAssertNil(store.reading(now: now.addingTimeInterval(25 * 3600)))
    }

    func testRenewedClaudeSessionKeepsItsRowAsUnknown() {
        let suite = "frog-usage-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        var state = ClaudePollingState()
        state.succeeded(Usage(limits: [
            Limit(id: "five_hour", label: "Session", pct: 21, resetsAt: now.addingTimeInterval(-3600), window: 5 * 3600),
            Limit(id: "seven_day", label: "Week", pct: 6, resetsAt: now.addingTimeInterval(4 * 86_400), window: 7 * 86_400),
        ]), at: now.addingTimeInterval(-10 * 3600))
        state.save(to: defaults)
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let windows = model.windows(provider: "Claude", now: now)
        XCTAssertEqual(windows.map(\.title), ["Session", "Week"])
        XCTAssertTrue(windows[0].percentage.isNaN, "The old 21% belongs to a session that is over")
        XCTAssertNil(windows[0].pace(at: now))
        XCTAssertEqual(windows[1].percentage, 6)
        XCTAssertTrue(model.windows(provider: "OpenAI", now: now).isEmpty)
    }

    func testCostAxisUsesWholeDollars() {
        let suite = "frog-usage-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(model.axisLabel(100, metric: "API cost"), "$100")
        XCTAssertEqual(model.axisLabel(0, metric: "API cost"), "$0")
        XCTAssertEqual(model.axisLabel(0.5, metric: "API cost"), "$0.50")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
