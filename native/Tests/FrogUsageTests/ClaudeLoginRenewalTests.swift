import XCTest
@testable import FrogUsage

/// Fakes only: no test reads a real login, starts Claude Code or sends a request.
@MainActor final class ClaudeLoginRenewalTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date, _login = false, _renewal = ClaudeLoginRenewal.failed
        private var _renewals = 0, _reads = 0, _requests = 0, _held = false, _deadlines: [TimeInterval] = []
        init(now: Date) { _now = now }
        private func locked<Value>(_ body: () -> Value) -> Value { lock.lock(); defer { lock.unlock() }; return body() }
        var now: Date { get { locked { _now } } set { locked { _now = newValue } } }
        var login: Bool { get { locked { _login } } set { locked { _login = newValue } } }
        var renewal: ClaudeLoginRenewal { get { locked { _renewal } } set { locked { _renewal = newValue } } }
        var renewals: Int { locked { _renewals } }
        var reads: Int { locked { _reads } }
        var requests: Int { locked { _requests } }
        /// Keeps a renewal running until it is let go.
        var held: Bool { get { locked { _held } } set { locked { _held = newValue } } }
        var deadlines: [TimeInterval] { locked { _deadlines } }
        func read() -> Bool { locked { _reads += 1; return _login } }
        func renew(deadline: TimeInterval) -> ClaudeLoginRenewal {
            locked { _renewals += 1; _deadlines.append(deadline) }
            while held { usleep(1000) }
            return locked { if _renewal == .renewed { _login = true }; return _renewal }
        }
        func request() { locked { _requests += 1 } }
    }

    private func store(_ world: World, source: ClaudeLoginSource = .automatic, desktop: ClaudeDesktopReading? = nil) -> (Store, UserDefaults, String) {
        let suite = "frog-usage-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defaults.set(source.rawValue, forKey: "claudeLoginSource")
        let limits = Usage(limits: [Limit(id: "five_hour", label: "Session", pct: 12, resetsAt: base.addingTimeInterval(86_400), window: 5 * 3600)])
        let store = Store(defaults: defaults, readAuth: { source, _ in
            world.read() ? ClaudeAuth(token: "fixture", source: source == .automatic ? .claudeCode : source,
                                      identity: "claudeCode|dir|account|org", label: "Fixture", hasAccountMetadata: true) : nil
        }, fetchLimits: { _ in world.request(); return limits }, readDesktop: { _ in desktop },
        renewLogin: { _, deadline in world.renew(deadline: deadline) }, currentDate: { world.now })
        return (store, defaults, suite)
    }

    private func settled(_ store: Store) async throws {
        for _ in 0..<400 where store.inFlight { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testLapsedLoginIsRenewedThroughClaudeCodeAndTheLimitsAreRead() async throws {
        let world = World(now: base); world.renewal = .renewed
        let (store, defaults, suite) = store(world)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.start(); try await settled(store)
        XCTAssertEqual(world.renewals, 1)
        XCTAssertEqual(world.requests, 1)
        XCTAssertEqual(store.displayUsage()?.limits.map(\.pct), [12])
        XCTAssertNil(store.warning)
        XCTAssertFalse(store.needsClaudeCodeLogin)
        // A login that works is not renewed again.
        world.now = base.addingTimeInterval(120); store.tick(); try await settled(store)
        XCTAssertEqual(world.renewals, 1)
        XCTAssertEqual(world.requests, 2)
    }

    func testLoginThatCannotBeRenewedAsksForSignInAndIsRetriedEverMoreRarely() async throws {
        let world = World(now: base)
        let (store, defaults, suite) = store(world)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.start(); try await settled(store)
        XCTAssertEqual(world.renewals, 1)
        XCTAssertEqual(world.requests, 0)
        XCTAssertTrue(store.needsClaudeCodeLogin)
        XCTAssertTrue(store.status.hasPrefix("Claude Code is not signed in on this Mac, or its login can no longer be renewed."), store.status)
        // The login is looked for again after a minute, without starting Claude Code again.
        world.now = base.addingTimeInterval(30); store.tick(); try await settled(store)
        XCTAssertEqual(world.reads, 1)
        world.now = base.addingTimeInterval(70); store.tick(); try await settled(store)
        XCTAssertEqual(world.reads, 2)
        XCTAssertEqual(world.renewals, 1)
        world.now = base.addingTimeInterval(3700); store.tick(); try await settled(store)
        XCTAssertEqual(world.renewals, 2)
        world.now = base.addingTimeInterval(3700 + 3700); store.tick(); try await settled(store)
        XCTAssertEqual(world.renewals, 2, "The second failure doubles the wait")
        world.now = base.addingTimeInterval(3700 + 7300); store.tick(); try await settled(store)
        XCTAssertEqual(world.renewals, 3)
    }

    func testOnlyClaudeCodesOwnLoginIsRenewed() async throws {
        for source in [ClaudeLoginSource.opencode, .pi, .claudeDesktop] {
            let world = World(now: base)
            let (store, defaults, suite) = store(world, source: source)
            defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
            store.start(); try await settled(store)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(world.renewals, 0, source.rawValue)
            XCTAssertEqual(store.needsClaudeCodeLogin, source == .claudeDesktop, source.rawValue)
            if source != .claudeDesktop { XCTAssertFalse(store.status.contains("Claude Code"), store.status) }
        }
    }

    func testSignInWaitsForTheNewLoginWithoutStartingClaudeCodeMeanwhile() async throws {
        let world = World(now: base)
        let (store, defaults, suite) = store(world)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.start(); try await settled(store)
        let needed = await store.beginSignIn()
        try await settled(store)
        XCTAssertTrue(needed)
        XCTAssertEqual(world.renewals, 2, "One renewal is tried before sending the user to sign in")
        let reads = world.reads
        world.now = base.addingTimeInterval(5); store.tick(); try await settled(store)
        XCTAssertEqual(world.reads, reads)
        world.now = base.addingTimeInterval(16); store.tick(); try await settled(store)
        XCTAssertEqual(world.reads, reads + 1, "While waiting, the login is looked for on every pass")
        world.login = true
        world.now = base.addingTimeInterval(31); store.tick(); try await settled(store)
        XCTAssertEqual(world.requests, 1)
        XCTAssertEqual(world.renewals, 2)
        XCTAssertEqual(store.displayUsage()?.limits.map(\.pct), [12])
        XCTAssertFalse(store.needsClaudeCodeLogin)
    }

    func testSignInDuringARenewalWaitsForItAndSaysSoInsteadOfStartingAnother() async throws {
        let world = World(now: base); world.held = true
        let (store, defaults, suite) = store(world)
        defer { world.held = false; store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.start()
        for _ in 0..<400 where world.renewals == 0 { try await Task.sleep(for: .milliseconds(5)) }
        async let first = store.beginSignIn()
        for _ in 0..<400 where !store.checkingLogin { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.checkingLogin)
        XCTAssertTrue(store.status.hasPrefix("Checking Claude Code’s login"), store.status)
        let second = await store.beginSignIn()
        XCTAssertFalse(second, "A second request while the first is checking opens nothing")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(world.renewals, 1, "The sign-in waits for the renewal already under way")
        world.held = false
        let needed = await first
        try await settled(store)
        XCTAssertTrue(needed)
        XCTAssertFalse(store.checkingLogin)
        XCTAssertEqual(world.renewals, 1)
        XCTAssertTrue(store.status.hasPrefix("Claude Code is not signed in on this Mac"), store.status)
        // A renewal the user is waiting for gives up sooner; Terminal's sign-in is there instead.
        let again = await store.beginSignIn()
        XCTAssertTrue(again)
        XCTAssertEqual(world.renewals, 2)
        XCTAssertEqual(world.deadlines.count, 2)
        XCTAssertLessThan(world.deadlines[1], world.deadlines[0])
    }

    func testSignInIsSkippedWhenClaudeCodeStillHasAUsableLogin() async throws {
        let world = World(now: base); world.login = true
        let stale = ClaudeDesktopReading(observedAt: base.addingTimeInterval(-3 * 3600), organization: "org", limits: [
            Limit(id: "five_hour", label: "Session", pct: 55, resetsAt: nil, window: 5 * 3600)], plan: "Max")
        let (store, defaults, suite) = store(world, source: .claudeDesktop, desktop: stale)
        defer { store.stop(); defaults.removePersistentDomain(forName: suite) }
        store.start()
        for _ in 0..<200 where store.desktop == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.needsClaudeCodeLogin)
        XCTAssertEqual(world.reads, 0)
        store.setLoginSource(.automatic)
        let needed = await store.beginSignIn()
        try await settled(store)
        XCTAssertFalse(needed)
        XCTAssertEqual(world.renewals, 0)
        XCTAssertEqual(store.reading()?.source, .account)
        XCTAssertFalse(store.needsClaudeCodeLogin)
    }

    func testLapsedMeansRunOutButRenewableByClaudeCode() {
        let past = base.addingTimeInterval(-60).timeIntervalSince1970 * 1000, future = base.addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let expired: [String: Any] = ["accessToken": "a", "refreshToken": "r", "expiresAt": past]
        XCTAssertTrue(claudeCodeLoginLapsed([expired], now: base))
        XCTAssertFalse(claudeCodeLoginLapsed([["accessToken": "a", "refreshToken": "r", "expiresAt": future]], now: base))
        XCTAssertFalse(claudeCodeLoginLapsed([expired, ["accessToken": "b", "expiresAt": future]], now: base))
        XCTAssertFalse(claudeCodeLoginLapsed([["accessToken": "a", "expiresAt": past]], now: base))
        XCTAssertFalse(claudeCodeLoginLapsed([["accessToken": "a", "refreshToken": "", "expiresAt": past]], now: base))
        XCTAssertFalse(claudeCodeLoginLapsed([], now: base))
    }

    func testClaudeCodeIsStartedWithoutAnotherSessionsCredentials() {
        let inherited = ["HOME": "/Users/someone", "USER": "someone", "PATH": "/custom/bin", "ANTHROPIC_API_KEY": "key",
                         "ANTHROPIC_AUTH_TOKEN": "token", "CLAUDE_CODE_ENTRYPOINT": "desktop", "CLAUDECODE": "1",
                         "CLAUDE_CONFIG_DIR": "/elsewhere", "HTTPS_PROXY": "http://proxy.example:8080"]
        let personal = ClaudeCodeCLI.environment(inherited, directory: ClaudePaths.defaultDirectory)
        XCTAssertEqual(personal, ["HOME": "/Users/someone", "USER": "someone", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                  "HTTPS_PROXY": "http://proxy.example:8080"])
        let work = ClaudeCodeCLI.environment(inherited, directory: URL(fileURLWithPath: "/Users/someone/.claude-work"))
        XCTAssertEqual(work["CLAUDE_CONFIG_DIR"], "/Users/someone/.claude-work")
        XCTAssertTrue(ClaudeCodeCLI.renewalArguments.starts(with: ["-p"]))
        XCTAssertTrue(ClaudeCodeCLI.renewalArguments.contains("--no-session-persistence"))
    }

    func testClaudeCodeIsFoundWhereItsInstallersPutItThenOnTheSearchPath() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let find = { (present: Set<String>) in
            ClaudeCodeCLI.executable(home: home, environment: ["PATH": "/a/bin:/b/bin"], isExecutable: present.contains)?.path
        }
        XCTAssertEqual(find(["/Users/someone/.local/bin/claude", "/opt/homebrew/bin/claude", "/b/bin/claude"]), "/Users/someone/.local/bin/claude")
        XCTAssertEqual(find(["/opt/homebrew/bin/claude", "/b/bin/claude"]), "/opt/homebrew/bin/claude")
        XCTAssertEqual(find(["/b/bin/claude"]), "/b/bin/claude")
        XCTAssertNil(find([]))
    }

    func testClaudeCodeIsNeverTakenFromARelativeSearchPathAndIsFoundUnderToolManagers() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let find = { (path: String, present: Set<String>) in
            ClaudeCodeCLI.executable(home: home, environment: ["PATH": path], isExecutable: present.contains)?.path
        }
        // A relative entry names a place in whatever folder Frog happens to run in.
        XCTAssertNil(find(".:relative/bin::bin", ["./claude", "relative/bin/claude", "bin/claude"]))
        XCTAssertEqual(find("relative:/b/bin", ["relative/claude", "/b/bin/claude"]), "/b/bin/claude")
        // Started from Finder, the search path names none of the folders tool managers install into.
        for folder in [".bun/bin", ".npm-global/bin", ".volta/bin", ".asdf/shims"] {
            XCTAssertEqual(find("/usr/bin:/bin", ["/Users/someone/\(folder)/claude"]), "/Users/someone/\(folder)/claude")
        }
        XCTAssertEqual(find("/b/bin", ["/b/bin/claude", "/Users/someone/.volta/bin/claude"]), "/b/bin/claude")
    }

    func testOpenCodeDataIsLookedUpInAnAbsoluteDataFolderOnly() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(openCodeDataDirectory(environment: ["XDG_DATA_HOME": "/data"], home: home).path, "/data/opencode")
        for value in ["", "relative/data", "./data", "~/data"] {
            XCTAssertEqual(openCodeDataDirectory(environment: ["XDG_DATA_HOME": value], home: home).path,
                           "/Users/someone/.local/share/opencode", value)
        }
        XCTAssertEqual(openCodeDataDirectory(environment: [:], home: home).path, "/Users/someone/.local/share/opencode")
    }

    func testSignInCommandNamesAnotherProfileAndQuotesPaths() {
        let executable = URL(fileURLWithPath: "/Users/some one/it's/claude")
        XCTAssertEqual(ClaudeCodeCLI.signInCommand(executable: executable, directory: ClaudePaths.defaultDirectory),
                       "exec '/Users/some one/it'\\''s/claude' 'auth' 'login'")
        XCTAssertEqual(ClaudeCodeCLI.signInCommand(executable: URL(fileURLWithPath: "/bin/claude"), directory: URL(fileURLWithPath: "/work/.claude")),
                       "exec '/usr/bin/env' 'CLAUDE_CONFIG_DIR=/work/.claude' '/bin/claude' 'auth' 'login'")
    }

    func testToolsRunToTheirEndOrAreStoppedAtTheDeadline() {
        let echo = usageProcess(URL(fileURLWithPath: "/bin/echo"), arguments: ["reading"], timeout: 5)
        XCTAssertEqual(echo?.status, 0)
        XCTAssertEqual(echo.map { String(decoding: $0.output, as: UTF8.self) }, "reading\n")
        XCTAssertEqual(usageProcess(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 5)?.status, 1)
        let started = Date()
        XCTAssertNil(usageProcess(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNil(usageProcess(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 1))
        let environment = usageProcess(URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["ONLY": "this"], timeout: 5)
        XCTAssertEqual(environment.map { String(decoding: $0.output, as: UTF8.self) }, "ONLY=this\n")
    }

    func testRenewalGateBacksOffAndStateSavedByEarlierVersionsStillLoads() throws {
        var state = ClaudePollingState()
        XCTAssertTrue(state.beginRenewal(at: base))
        XCTAssertFalse(state.beginRenewal(at: base.addingTimeInterval(60)))
        state.renewalEnded(.unavailable, at: base)
        XCTAssertFalse(state.beginRenewal(at: base.addingTimeInterval(200)))
        XCTAssertTrue(state.beginRenewal(at: base.addingTimeInterval(301)))
        for _ in 0..<8 { state.renewalEnded(.failed, at: base) }
        XCTAssertEqual(state.renewalInterval, 8 * 3600)
        XCTAssertFalse(state.beginRenewal(at: base.addingTimeInterval(8 * 3600 - 1)))
        state.succeeded(Usage(), at: base)
        XCTAssertNil(state.renewalInterval)
        XCTAssertTrue(state.beginRenewal(at: base))

        XCTAssertTrue(state.begin(at: base))
        state.retry(at: base.addingTimeInterval(10))
        XCTAssertEqual(state.nextFetchAt, base.addingTimeInterval(10))
        state.retry(at: base.addingTimeInterval(500))
        XCTAssertEqual(state.nextFetchAt, base.addingTimeInterval(10), "A retry never postpones the next check")

        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        saved["nextRenewalAt"] = nil; saved["renewalInterval"] = nil
        let suite = "frog-usage-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: ClaudePollingState.defaultsKey)
        XCTAssertNotNil(ClaudePollingState.load(from: defaults).lastGoodAt)
    }
}
