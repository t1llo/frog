import XCTest
@testable import FrogUsage

/// A fixture home in a temporary folder whose name has a space, fake organization ids, and fakes
/// for every login, request and renewal: no test reads a real login or sends anything.
@MainActor final class ClaudeAccountsStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)
    private var home: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("frog tests \(UUID().uuidString)")
        suite = "frog-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
        defaults.removePersistentDomain(forName: suite)
    }

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        private var _fetches: [String: Int] = [:], _authReads: [String] = [], _desktopReads: [String] = []
        private var _organizations: [String: Bool] = [:]
        /// Logins by Claude Code folder name, with their organization, and the profile beside
        /// each, which names the login's organization unless another session rewrote it.
        private var _logins: [String: String], _profiles: [String: String] = [:], _tokens: [String: String] = [:]
        var throttled: Set<String> = []
        init(now: Date, logins: [String: String]) { _now = now; _logins = logins }
        private func locked<Value>(_ body: () -> Value) -> Value { lock.lock(); defer { lock.unlock() }; return body() }
        var now: Date { get { locked { _now } } set { locked { _now = newValue } } }
        func fetches(_ folder: String) -> Int { locked { _fetches[folder] ?? 0 } }
        var authReads: [String] { locked { _authReads } }
        var desktopReads: [String] { locked { _desktopReads } }
        var organizationReads: [String] { locked { Array(_organizations.keys) } }
        /// Every organization read, one per folder and detection.
        var organizationReadCount: Int { locked { _organizationReadCount } }
        private var _organizationReadCount = 0
        /// A folder signed in again, as the account of `organization`: a new token.
        func signIn(_ name: String, organization: String, token: String) { locked { _logins[name] = organization; _tokens[name] = token } }
        /// Another session rewrote the folder's profile; its login stays.
        func rewriteProfile(_ name: String, organization: String) { locked { _profiles[name] = organization } }
        func auth(_ directory: URL) -> ClaudeAuth? {
            let name = directory.lastPathComponent
            let login = locked { () -> (token: String, organization: String?, profile: String?) in
                _authReads.append(name)
                return (_tokens[name] ?? name, _logins[name], _profiles[name] ?? _logins[name])
            }
            guard login.organization != nil, let profile = login.profile else { return nil }
            return ClaudeAuth(token: login.token, source: .claudeCode, identity: "claudeCode|\(directory.path)|account-\(profile)|\(profile)",
                              label: "Fixture \(profile)", hasAccountMetadata: true, organization: profile)
        }
        func fetch(_ token: String, at now: Date) throws -> Usage {
            let throttle = locked { _fetches[token, default: 0] += 1; return throttled.contains(token) }
            if throttle { throw FetchError.http(429, retryAfter: nil, message: nil) }
            return Usage(limits: [Limit(id: "five_hour", label: "Session", pct: 12, resetsAt: now.addingTimeInterval(3600), window: 5 * 3600),
                                  Limit(id: "seven_day", label: "Week", pct: 20, resetsAt: now.addingTimeInterval(3 * 86_400), window: 7 * 86_400)])
        }
        func readDesktop(_ folder: URL) { locked { _desktopReads.append(folder.lastPathComponent) } }
        func readOrganization(_ source: ClaudeAccountSource) {
            locked { _organizations[source.folder.lastPathComponent] = true; _organizationReadCount += 1 }
        }
    }

    // MARK: Fixtures

    private var support: URL { home.appendingPathComponent("Library/Application Support") }

    /// A Claude app folder whose history's newest sample names `organization`.
    private func app(_ name: String, organization: String, at date: Date, session: Double = 55) throws {
        let folder = support.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sample: [String: Any] = ["t": date.timeIntervalSince1970 * 1000, "org": organization, "u": ["fh": session, "sd": 40]]
        try JSONSerialization.data(withJSONObject: ["version": 2, "samples": [sample]])
            .write(to: folder.appendingPathComponent("plan-usage-history.json"), options: .atomic)
    }

    /// A Claude Code profile signed in to `organization`; `.claude` keeps its file in the home folder.
    private func profile(_ name: String, organization: String) throws {
        let folder = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = name == ".claude" ? home.appendingPathComponent(".claude.json") : folder.appendingPathComponent(".claude.json")
        let account: [String: Any] = ["organizationUuid": organization, "accountUuid": "account-\(name)",
                                      "emailAddress": "someone@example.com", "organizationRateLimitTier": "default_claude_max_20x"]
        try JSONSerialization.data(withJSONObject: ["oauthAccount": account]).write(to: file)
    }

    /// Two accounts: A in the default Claude app folder and `~/.claude`, B in `Claude-Account-B`,
    /// with a Claude Code profile of its own unless `appOnlyB`.
    private func twoAccounts(appOnlyB: Bool = false, readingB: Date? = nil) throws {
        try app("Claude", organization: "org-test-1", at: base.addingTimeInterval(-300))
        try app("Claude-Account-B", organization: "org-test-2", at: readingB ?? base.addingTimeInterval(-300), session: 80)
        try profile(".claude", organization: "org-test-1")
        if !appOnlyB { try profile(".claude-account-b", organization: "org-test-2") }
    }

    private func accountsModel(_ world: World) -> ClaudeAccountsModel {
        let defaults = defaults!
        return ClaudeAccountsModel(defaults: defaults, home: home, environment: [:], makeStore: { account, delay in
            let files = ClaudeDesktopFiles(), profiles = [account.profileFile].compactMap { $0 }
            let store = Store(account: account, defaults: defaults,
                              readAuth: { _, directory in world.auth(directory) },
                              fetchLimits: { token in try world.fetch(token, at: world.now) },
                              readDesktop: { folder in
                                  world.readDesktop(folder)
                                  return readClaudeDesktop(folder: folder, profiles: profiles, files: files)
                              },
                              renewLogin: { _, _ in .unavailable }, currentDate: { world.now })
            store.startDelay = delay
            return store
        }, readOrganization: { source in
            world.readOrganization(source)
            return ClaudeAccountsModel.organization(of: source)
        })
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func settled(_ model: ClaudeAccountsModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        try await until { !model.stores.values.contains { $0.inFlight } }
    }

    private func store(_ model: ClaudeAccountsModel, _ label: String) -> Store? {
        model.accounts.first { model.label($0) == label }.flatMap { model.stores[$0.id] }
    }

    private func world() -> World { World(now: base, logins: [".claude": "org-test-1", ".claude-account-b": "org-test-2"]) }

    // MARK: Tests

    func testThrottlingOfOneAccountLeavesTheOthersScheduleAloneAndTheSecondStartsLater() async throws {
        try twoAccounts()
        let world = world(); world.throttled = [".claude-account-b"]
        let model = accountsModel(world)
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await until { model.stores.count == 2 && world.fetches(".claude") == 1 }
        try await settled(model)
        let a = try XCTUnwrap(store(model, "A")), b = try XCTUnwrap(store(model, "B"))
        XCTAssertEqual(a.nextFetchAt, base.addingTimeInterval(60))
        XCTAssertEqual(world.fetches(".claude-account-b"), 0, "B waits 30 s after A")
        world.now = base.addingTimeInterval(29); model.tick(); try await settled(model)
        XCTAssertEqual(world.fetches(".claude-account-b"), 0)
        world.now = base.addingTimeInterval(31); model.tick(); try await settled(model)
        XCTAssertEqual(world.fetches(".claude-account-b"), 1)
        XCTAssertEqual(b.lastError, "rate limited")
        XCTAssertEqual(b.nextFetchAt, base.addingTimeInterval(31 + 120), "B's own pace doubles")
        XCTAssertEqual(a.nextFetchAt, base.addingTimeInterval(60), "A's schedule is untouched")
        XCTAssertNil(a.lastError)
        XCTAssertEqual(world.fetches(".claude"), 1)
    }

    func testTheDefaultAccountKeepsTheSavedGateAndTheOthersSaveTheirOwn() async throws {
        try twoAccounts()
        var saved = ClaudePollingState()
        _ = saved.begin(at: base)
        saved.failed(FetchError.http(429, retryAfter: 600, message: nil), at: base)
        saved.save(to: defaults)
        let world = world()
        let model = accountsModel(world)
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await until { model.stores.count == 2 }
        try await settled(model)
        let a = try XCTUnwrap(model.accounts.first { model.label($0) == "A" })
        let b = try XCTUnwrap(model.accounts.first { model.label($0) == "B" })
        XCTAssertEqual(a.pollingKey, ClaudePollingState.defaultsKey)
        XCTAssertNotEqual(b.pollingKey, ClaudePollingState.defaultsKey)
        XCTAssertEqual(model.stores[a.id]?.nextFetchAt, base.addingTimeInterval(600), "A cooldown saved before honours")
        XCTAssertEqual(world.fetches(".claude"), 0)
        world.now = base.addingTimeInterval(31); model.tick(); try await settled(model)
        XCTAssertEqual(world.fetches(".claude-account-b"), 1)
        XCTAssertNotNil(defaults.data(forKey: b.pollingKey))
        XCTAssertEqual(ClaudePollingState.load(from: defaults, now: world.now).nextFetchAt, base.addingTimeInterval(600))
        XCTAssertEqual(ClaudePollingState.load(from: defaults, key: b.pollingKey, now: world.now).nextFetchAt, base.addingTimeInterval(91))
    }

    func testWithTheSwitchOffOnlyNamesAreLookedAtAndOneStoreReads() async throws {
        try twoAccounts()
        let world = world()
        let opened = Opened()
        nonisolated(unsafe) let defaults = defaults!
        let model = ClaudeAccountsModel(defaults: defaults, home: home, environment: [:], makeStore: { account, _ in
            XCTFail("No store is made while the switch is off")
            return Store(account: account, defaults: defaults)
        }, discover: { home, extra in
            ClaudeAccountDiscovery.sources(home: home, extraFolders: extra, environment: [:], defaults: defaults,
                                           read: { opened.add($0); return try? Data(contentsOf: $0) })
        }, readOrganization: { world.readOrganization($0); return nil })
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        try await until { usage.detectedAccountCount == 2 }
        XCTAssertEqual(usage.detectedAccountCount, 2)
        XCTAssertTrue(model.stores.isEmpty, "Only the one store reads while the switch is off")
        XCTAssertTrue(usage.accounts().isEmpty)
        XCTAssertTrue(world.organizationReads.isEmpty)
        XCTAssertTrue(world.desktopReads.isEmpty)
        XCTAssertFalse(opened.paths.contains { $0.hasSuffix("plan-usage-history.json") }, "\(opened.paths)")
        XCTAssertTrue(opened.paths.allSatisfy { $0.hasSuffix(".claude.json") }, "\(opened.paths)")
    }

    func testNotNowHidesTheNoticeForGood() async throws {
        try twoAccounts()
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home)
        usage.setAvailable(true)
        try await until { usage.detectedAccountCount == 2 }
        XCTAssertTrue(usage.accountsNoticeVisible)
        XCTAssertEqual(usage.accountsNoticeAction, "Show both")
        XCTAssertEqual(usage.accountsNoticeText,
                       "Frog found 2 Claude accounts on this Mac: the Claude app’s “Claude” and “Claude-Account-B” folders. Show usage for each? Frog reads their saved limits locally.")
        usage.dismissAccountsNotice()
        XCTAssertFalse(usage.accountsNoticeVisible)
        usage.setAvailable(false)
        let again = UsageDashboardModel(defaults: defaults, fixtureRoot: home)
        again.setAvailable(true)
        defer { again.setAvailable(false) }
        try await until { again.detectedAccountCount == 2 }
        XCTAssertEqual(again.detectedAccountCount, 2)
        XCTAssertFalse(again.accountsNoticeVisible)
        XCTAssertFalse(again.preferences.claudeAccounts, "The switch stays off and on the page")
    }

    func testShowBothTurnsTheSwitchOnOnceAndReadsTheSecondAccount() async throws {
        try twoAccounts()
        let world = world()
        let model = accountsModel(world)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        var changes: [UsageDashboardPreferences] = []
        usage.onPreferencesChange = { changes.append($0) }
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        try await until { usage.accountsNoticeVisible }
        usage.showAllAccounts()
        XCTAssertEqual(changes.map(\.claudeAccounts), [true])
        XCTAssertTrue(usage.claudeAccountsEnabled)
        XCTAssertFalse(usage.accountsNoticeVisible)
        try await until { world.desktopReads.contains("Claude-Account-B") && usage.accounts(now: world.now).count == 2 }
        XCTAssertTrue(world.desktopReads.contains("Claude-Account-B"))
        let accounts = usage.accounts(now: world.now)
        XCTAssertEqual(accounts.map(\.label), ["A", "B"])
        XCTAssertEqual(accounts.map(\.sources), [["Claude app · Claude", "Claude Code · ~/.claude"],
                                                 ["Claude app · Claude-Account-B", "Claude Code · ~/.claude-account-b"]])
        try await until { usage.accounts(now: world.now).last?.windows.first?.percentage == 80 }
        XCTAssertEqual(usage.accounts(now: world.now).last?.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(usage.combinedWindows(now: world.now).map(\.id), ["five_hour", "seven_day"])
        usage.showAllAccounts()
        XCTAssertEqual(changes.count, 1, "Reported once")
    }

    func testAnAccountKnownOnlyFromTheClaudeAppNeverSendsARequestAndOffersLiveReadings() async throws {
        try twoAccounts(appOnlyB: true, readingB: base.addingTimeInterval(-31 * 60))
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("claude").path)
        let world = world()
        let model = accountsModel(world)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        usage.applyPreferences(UsageDashboardPreferences(claudeAccounts: true))
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        try await until { model.stores.count == 2 && world.desktopReads.contains("Claude-Account-B") }
        try await settled(model)
        world.now = base.addingTimeInterval(120); usage.refresh(); try await settled(model)
        XCTAssertEqual(world.authReads.filter { $0 != ".claude" }, [], "B has no login to read")
        XCTAssertEqual(world.fetches("Claude-Account-B"), 0)
        let accounts = usage.accounts(now: base)
        XCTAssertEqual(accounts.map(\.label), ["A", "B"])
        XCTAssertEqual(accounts.map(\.needsLiveSetup), [false, true])
        XCTAssertEqual(accounts.last?.stale, true)
        let id = try XCTUnwrap(accounts.last?.id)
        let command = try XCTUnwrap(usage.liveSetupCommand(for: id))
        XCTAssertTrue(command.contains("'CLAUDE_CONFIG_DIR=\(home.path)/.claude-account-b'"), command)
        XCTAssertTrue(command.contains(" '\(bin.path)/claude' 'auth' 'login'"), command)
        XCTAssertNil(usage.liveSetupCommand(for: try XCTUnwrap(accounts.first?.id)), "A already has a login")
        XCTAssertEqual(ClaudeAccountsModel.liveSetupFolder(for: URL(fileURLWithPath: "/x/Work Stuff"), home: home).lastPathComponent,
                       ".claude-work-stuff")
    }

    func testAnAccountWhoseOwnLoginIsGoneOffersItsOwnSignInAndSaysWhy() async throws {
        try twoAccounts(readingB: base.addingTimeInterval(-31 * 60))
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("claude").path)
        // B has its own Claude Code folder, but no login in it.
        let world = World(now: base, logins: [".claude": "org-test-1"])
        let model = accountsModel(world)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        usage.applyPreferences(UsageDashboardPreferences(claudeAccounts: true))
        XCTAssertFalse(usage.searchingClaudeAccounts, "Nothing is looked for before Mr. Usage is on")
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        XCTAssertTrue(usage.searchingClaudeAccounts, "The empty list says it is still looking")
        try await until { model.stores.count == 2 && store(model, "A")?.usage != nil }
        XCTAssertFalse(usage.searchingClaudeAccounts)
        world.now = base.addingTimeInterval(31); usage.refresh(); try await settled(model)
        let accounts = usage.accounts(now: world.now)
        XCTAssertEqual(accounts.map(\.label), ["A", "B"])
        XCTAssertEqual(accounts.map(\.needsSignIn), [false, true])
        XCTAssertEqual(accounts.map(\.needsLiveSetup), [false, false], "B signs in to its own folder; no new profile")
        XCTAssertNil(accounts.first?.warning, "A's reading is current")
        let warning = try XCTUnwrap(accounts.last?.warning)
        XCTAssertTrue(warning.contains("Sign in to Claude Code"), warning)
        let command = try XCTUnwrap(usage.claudeSignInCommand(for: try XCTUnwrap(accounts.last?.id)))
        XCTAssertTrue(command.contains("'CLAUDE_CONFIG_DIR=\(home.path)/.claude-account-b'"), command)
        XCTAssertTrue(command.contains(" '\(bin.path)/claude' 'auth' 'login'"), command)
        XCTAssertNil(usage.claudeSignInCommand(for: "/no/such/slot"))
    }

    func testAFolderSignedInToAnotherAccountDropsTheOldLoginsReadingAndKeepsItsLabel() async throws {
        try twoAccounts()
        let world = world()
        let model = accountsModel(world)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        usage.applyPreferences(UsageDashboardPreferences(claudeAccounts: true))
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        try await until { world.fetches(".claude") == 1 && store(model, "A")?.usage != nil }
        try await settled(model)
        XCTAssertEqual(usage.accounts(now: world.now).first?.windows.first?.percentage, 12, "The newer endpoint reading shows")
        try app("Claude", organization: "org-test-9", at: base.addingTimeInterval(10), session: 70)
        world.now = base.addingTimeInterval(20); model.tick()
        try await until { model.accounts.first?.codeFolder == nil && store(model, "A")?.desktop?.organization == "org-test-9" }
        let a = try XCTUnwrap(store(model, "A"))
        XCTAssertNil(a.usage, "The old login's reading belongs to another account")
        let first = try XCTUnwrap(usage.accounts(now: world.now).first)
        XCTAssertEqual(first.label, "A")
        XCTAssertEqual(first.windows.first?.percentage, 70)
        XCTAssertEqual(first.sources, ["Claude app · Claude"], "The profile no longer belongs to the folder")
    }

    /// The Claude app's Claude Code sessions write `~/.claude.json` too, so it may name B beside
    /// A's unchanged login: A keeps its reading and its name, and nothing is matched again. A new
    /// login is believed with the account its profile names.
    func testAProfileRewrittenBesideTheSameLoginKeepsItsReadingAndName() async throws {
        try twoAccounts()
        let world = world()
        let model = accountsModel(world)
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await until { world.fetches(".claude") == 1 && store(model, "A")?.usage != nil }
        try await settled(model)
        let a = try XCTUnwrap(store(model, "A"))
        XCTAssertEqual(a.authLabel, "Fixture org-test-1")
        let detections = world.organizationReadCount

        try profile(".claude", organization: "org-test-2")
        world.rewriteProfile(".claude", organization: "org-test-2")
        world.throttled = [".claude"]
        world.now = base.addingTimeInterval(61); model.tick(); try await settled(model)
        XCTAssertEqual(world.fetches(".claude"), 2)
        XCTAssertEqual(a.lastError, "rate limited")
        XCTAssertEqual(a.usage?.limits.map(\.pct), [12, 20], "The same login's reading stays")
        XCTAssertEqual(a.authLabel, "Fixture org-test-1")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(world.organizationReadCount, detections, "The same login is no reason to match the folders again")

        world.signIn(".claude", organization: "org-test-2", token: "a-signed-in-again")
        world.now = base.addingTimeInterval(61 + 121); model.tick(); try await settled(model)
        XCTAssertEqual(world.fetches("a-signed-in-again"), 1)
        XCTAssertEqual(a.authLabel, "Fixture org-test-2", "A new login comes with the account its profile names")
        try await until { world.organizationReadCount > detections }
        XCTAssertGreaterThan(world.organizationReadCount, detections, "and has the folders matched again")
        try await settled(model)
        XCTAssertEqual(model.accounts.map { $0.codeFolder?.lastPathComponent }, [".claude", ".claude-account-b"],
                       "B keeps its own folder, so A keeps the default one")
        XCTAssertTrue(store(model, "A") === a)
    }

    /// `~/.claude-work` signed in again as B's account belongs to B from its next reading on,
    /// not only after a relaunch or Refresh.
    func testAFolderSignedInAgainAsAnotherAccountIsMatchedAgain() async throws {
        try app("Claude", organization: "org-test-1", at: base.addingTimeInterval(-300))
        try app("Claude-Account-B", organization: "org-test-2", at: base.addingTimeInterval(-300))
        try profile(".claude", organization: "org-test-1")
        try profile(".claude-work", organization: "org-test-3")
        let world = World(now: base, logins: [".claude": "org-test-1", ".claude-work": "org-test-3"])
        let model = accountsModel(world)
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await until { model.accounts.count == 3 }
        XCTAssertEqual(model.accounts.map { model.label($0) }, ["A", "B", "Work"])
        XCTAssertNil(model.accounts[1].codeFolder)
        world.now = base.addingTimeInterval(61); model.tick(); try await settled(model)
        XCTAssertEqual(world.fetches(".claude-work"), 1)

        try profile(".claude-work", organization: "org-test-2")
        world.signIn(".claude-work", organization: "org-test-2", token: "work-as-b")
        world.now = base.addingTimeInterval(122); model.tick()
        try await until { model.accounts.count == 2 }
        XCTAssertEqual(model.accounts.map { model.label($0) }, ["A", "B"])
        XCTAssertEqual(model.accounts.map { $0.codeFolder?.lastPathComponent }, [".claude", ".claude-work"])
    }

    /// B's Claude Code works in `~/.claude-account-b`, which the usual folders leave out. While each
    /// account is shown, the activity and its API cost count both accounts' calls.
    func testTheActivityCountsTheClaudeCodeCallsOfEveryAccountShown() async throws {
        try twoAccounts()
        func call(_ path: String, id: String, input: Int) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: Date()),
                                       "message": ["id": id, "model": "claude-sonnet-4-6", "usage": ["input_tokens": input]]]
            try (JSONSerialization.data(withJSONObject: line) + Data([10])).write(to: url)
        }
        // The fixture's usual folder, then A's and B's own.
        try call("claude/session.jsonl", id: "usual", input: 3)
        try call(".claude/projects/app/a.jsonl", id: "a", input: 100)
        try call(".claude-account-b/projects/app/b.jsonl", id: "b", input: 20)
        let world = world()
        let model = accountsModel(world)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        func input() -> Double? { usage.chart(provider: "Claude", range: "7d", metric: "Input").totals.first { $0.name == "Input" }?.value }
        try await until { usage.loaded && input() == 3 }
        XCTAssertEqual(input(), 3, "One account shown reads the usual folders as before")

        usage.showAllAccounts()
        try await until { input() == 123 }
        XCTAssertEqual(usage.accounts(now: world.now).count, 2)
        XCTAssertEqual(input(), 123, "Both accounts' calls")
        let cost = try XCTUnwrap(usage.chart(provider: "Claude", range: "7d", metric: "API cost").totals.first { $0.name == "API cost" }?.value)
        let price = try XCTUnwrap(apiCost(model: "claude-sonnet-4-6", input: 123, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, fast: false))
        XCTAssertEqual(cost, price, accuracy: 1e-12)

        var off = usage.preferences; off.claudeAccounts = false; usage.updatePreferences(off)
        try await until { input() == 3 }
        XCTAssertEqual(input(), 3, "Turned off, the accounts' own folders are left out again")
    }

    func testSummariesNeverShowAnEmailAddress() async throws {
        try twoAccounts()
        let world = world()
        let model = accountsModel(world)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: home, claudeAccounts: model)
        usage.applyPreferences(UsageDashboardPreferences(claudeAccounts: true))
        usage.setAvailable(true)
        defer { usage.setAvailable(false) }
        try await until { usage.accounts(now: world.now).count == 2 && store(model, "A")?.usage != nil }
        try await settled(model)
        usage.renameAccount(try XCTUnwrap(usage.accounts(now: world.now).last?.id), to: "  Work  ")
        let accounts = usage.accounts(now: world.now)
        XCTAssertEqual(accounts.map(\.label), ["A", "Work"])
        XCTAssertEqual(accounts.last?.plan, "Max 20×", "From the profile of the same organization")
        for account in accounts {
            let texts = [account.id, account.label, account.shortLabel, account.plan ?? "", account.status ?? "", account.mergedNote ?? ""]
                + account.sources + account.windows.map(\.title)
            XCTAssertFalse(texts.contains { $0.contains("@") || $0.contains("example.com") }, "\(texts)")
        }
    }
}

private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var paths: [String] { lock.withLock { urls.map(\.path) } }
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
}
