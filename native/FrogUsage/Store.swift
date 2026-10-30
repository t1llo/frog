// Polling state. Every minute; a 429 doubles that up to 10 minutes, and the slower pace eases
// back a step for every hour without one. A 5xx only delays the next attempt. Never faster than
// the server's Retry-After, and menu opens cannot bypass it.
import Foundation
import Combine

@MainActor
final class Store: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var lastGoodAt: Date?
    @Published var lastError: String?
    @Published private(set) var inFlight = false
    @Published private(set) var loginSource: ClaudeLoginSource
    @Published private(set) var authLabel: String?
    @Published private(set) var authPlan: String?
    /// The newest reading the Claude app saved on this Mac, if any.
    @Published private(set) var desktop: ClaudeDesktopReading?
    /// The user asked to sign in, and Frog is first finding out whether Claude Code's login
    /// can still be used or renewed.
    @Published private(set) var checkingLogin = false
    /// The Claude account this store reads, when Frog shows each account on its own. Nil for the
    /// one account Frog reads otherwise, through the login source and folder chosen on the page.
    let account: ClaudeAccount?
    var configDirectory: URL {
        guard let account else { return ClaudePaths.directory(defaults: defaults) }
        return account.codeFolder ?? account.appFolder ?? URL(fileURLWithPath: account.slotPath)
    }
    /// Stores of several accounts start a little apart, so their first requests do not arrive together.
    /// Only the first start sets that time: a store started again after a pause keeps it, so it reads
    /// at once when it is due instead of waiting its turn over again.
    var startDelay: TimeInterval = 0
    private var startedBefore = false
    /// Told when the account the Claude app's folder is signed in to is no longer the one it was,
    /// or the Claude Code folder holds a new login of another account than when it was matched.
    var onOrganizationChange: (() -> Void)?

    private let defaults: UserDefaults
    private let pollingKey: String
    private var polling: ClaudePollingState
    var nextFetchAt: Date { polling.nextFetchAt }
    /// Claude Code rewrites the Keychain item when it refreshes the token. A read that lands in
    /// that window finds nothing, so remember the last token we saw and fall back to it.
    private var cachedToken: String?
    private var loginGeneration = 0
    private let readAuth: @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth?
    private let fetchLimits: @Sendable (String) async throws -> Usage
    private let readDesktop: @Sendable (URL) -> ClaudeDesktopReading?
    private let renewLogin: @Sendable (URL, TimeInterval) -> ClaudeLoginRenewal
    private let currentDate: @Sendable () -> Date
    private(set) var timer: Timer?
    private var request: Task<Void, Never>?
    private var desktopRead: Task<Void, Never>?
    /// Claude Code's run that renews its login. A poll and a sign-in share it, so Claude Code
    /// is never started twice at once.
    private var renewal: Task<ClaudeLoginRenewal, Never>?
    /// A poll renews in the background; someone waiting to sign in has Terminal's sign-in to
    /// fall back on and is not kept waiting as long.
    static let renewalDeadline: TimeInterval = 90
    static let signInRenewalDeadline: TimeInterval = 30
    /// The last check found no login at all, as opposed to a request that failed.
    private var missingLogin = false
    /// The user was sent to sign in: look for the new login often, and leave Claude Code alone.
    private var awaitingLoginUntil: Date?
    private var awaitingLogin: Bool { awaitingLoginUntil.map { currentDate() < $0 } ?? false }
    private var active = false
    /// No request before this time, which `startDelay` puts after the start.
    private var fetchesFrom = Date.distantPast
    private var delayedStart: Task<Void, Never>?
    /// The organization the Claude app's folder was last seen signed in to.
    private var knownOrganization: String?
    /// The organization the Claude Code folder's profile named with the login last read anew.
    private var knownProfileOrganization: String?

    convenience init(defaults: UserDefaults = UsagePreferences.defaults, startPolling: Bool = false,
                     readAuth: @escaping @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth? = { readClaudeAuth(source: $0, directory: $1) },
                     fetchLimits: @escaping @Sendable (String) async throws -> Usage = { try await fetchUsage(token: $0) },
                     readDesktop: @escaping @Sendable (URL) -> ClaudeDesktopReading? = { _ in nil },
                     renewLogin: @escaping @Sendable (URL, TimeInterval) -> ClaudeLoginRenewal = { _, _ in .unavailable },
                     currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.init(slot: nil, defaults: defaults, readAuth: readAuth, fetchLimits: fetchLimits, readDesktop: readDesktop,
                  renewLogin: renewLogin, currentDate: currentDate)
        if startPolling { start() }
    }

    /// One of several Claude accounts. It works as Automatic does, with the account's own Claude
    /// Code login, its own Claude app folder and its own request gate. An account known only from
    /// the Claude app reads that app's file and sends nothing. `readDesktop` is handed the
    /// account's Claude app folder.
    convenience init(account: ClaudeAccount, defaults: UserDefaults = UsagePreferences.defaults,
                     readAuth: @escaping @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth? = { readClaudeAuth(source: $0, directory: $1) },
                     fetchLimits: @escaping @Sendable (String) async throws -> Usage = { try await fetchUsage(token: $0) },
                     readDesktop: @escaping @Sendable (URL) -> ClaudeDesktopReading? = { _ in nil },
                     renewLogin: @escaping @Sendable (URL, TimeInterval) -> ClaudeLoginRenewal = { _, _ in .unavailable },
                     currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.init(slot: account, defaults: defaults, readAuth: readAuth, fetchLimits: fetchLimits, readDesktop: readDesktop,
                  renewLogin: renewLogin, currentDate: currentDate)
    }

    private init(slot account: ClaudeAccount?, defaults: UserDefaults,
                 readAuth: @escaping @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth?,
                 fetchLimits: @escaping @Sendable (String) async throws -> Usage,
                 readDesktop: @escaping @Sendable (URL) -> ClaudeDesktopReading?,
                 renewLogin: @escaping @Sendable (URL, TimeInterval) -> ClaudeLoginRenewal,
                 currentDate: @escaping @Sendable () -> Date) {
        self.account = account
        self.defaults = defaults
        self.readAuth = readAuth
        self.fetchLimits = fetchLimits
        self.readDesktop = readDesktop
        self.renewLogin = renewLogin
        self.currentDate = currentDate
        if let account {
            loginSource = account.codeFolder == nil ? .claudeDesktop : .automatic
            pollingKey = account.pollingKey
            knownOrganization = account.appFolder == nil ? nil : account.organization
            knownProfileOrganization = account.profileOrganization
        } else {
            loginSource = defaults.string(forKey: "claudeLoginSource").flatMap(ClaudeLoginSource.init(rawValue:)) ?? .automatic
            pollingKey = ClaudePollingState.defaultsKey
        }
        polling = ClaudePollingState.load(from: defaults, key: pollingKey, now: currentDate())
        usage = polling.usage
        lastGoodAt = polling.lastGoodAt
        lastError = polling.lastFailure
        authLabel = polling.authLabel
    }

    func start() {
        guard !active else { return }; active = true
        // The first start sets when this store may first ask; a later start keeps that time.
        if !startedBefore { fetchesFrom = currentDate().addingTimeInterval(startDelay) }
        startedBefore = true
        let delay = max(0, fetchesFrom.timeIntervalSince(currentDate()))
        tick()
        if delay > 0 {
            delayedStart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 3
    }

    /// The saved state again, after another store of the same account saved its own.
    func reloadPolling() {
        guard !active else { return }
        polling = ClaudePollingState.load(from: defaults, key: pollingKey, now: currentDate())
        usage = polling.usage; lastGoodAt = polling.lastGoodAt; lastError = polling.lastFailure; authLabel = polling.authLabel
    }

    func stop() {
        active = false; loginGeneration += 1
        delayedStart?.cancel(); delayedStart = nil
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        desktopRead?.cancel(); desktopRead = nil
        renewal?.cancel(); renewal = nil
        inFlight = false; cachedToken = nil; awaitingLoginUntil = nil
    }

    /// Fetch if the schedule says so. The timer, panel opens and the Refresh button all go
    /// through here, so none of them can exceed the current cadence. The Claude app's saved
    /// reading is a small local file, looked at every time and read again once it has changed.
    func tick() {
        guard active else { return }
        refreshDesktop()
        let now = currentDate()
        if loginSource != .claudeDesktop, now >= nextFetchAt, now >= fetchesFrom { fetch() }
    }

    private func refreshDesktop() {
        // An account known only from its Claude Code login has no Claude app folder to look in.
        guard desktopRead == nil, account == nil || account?.appFolder != nil else { return }
        let generation = loginGeneration, directory = account?.appFolder ?? configDirectory, reader = readDesktop
        desktopRead = Task {
            let reading = try? await usageWork { reader(directory) }
            guard !Task.isCancelled, generation == loginGeneration else { return }
            desktopRead = nil
            guard reading != desktop else { return }
            desktop = reading
            guard account != nil, let organization = reading?.organization else { return }
            defer { knownOrganization = organization }
            // The folder is signed in to another account now: what was read with the old one's
            // login, and the renewal times borrowed from it, belong to that other account.
            if let known = knownOrganization, known != organization {
                clearSelectedLogin()
                onOrganizationChange?()
            }
        }
    }

    func setLoginSource(_ source: ClaudeLoginSource) {
        guard account == nil, source != loginSource else { return }
        loginSource = source
        defaults.set(source.rawValue, forKey: "claudeLoginSource")
        clearSelectedLogin()
    }

    func setConfigDirectory(_ directory: URL) {
        guard account == nil else { return }
        defaults.set(directory.standardizedFileURL.path, forKey: ClaudePaths.directoryPreference)
        loginSource = .claudeCode
        defaults.set(loginSource.rawValue, forKey: "claudeLoginSource")
        clearSelectedLogin()
    }

    private func clearSelectedLogin() {
        loginGeneration += 1
        request?.cancel(); request = nil; inFlight = false
        desktopRead?.cancel(); desktopRead = nil
        renewal?.cancel(); renewal = nil
        cachedToken = nil
        polling.clearReading()
        usage = nil; lastGoodAt = nil; lastError = nil; authLabel = nil; authPlan = nil; missingLogin = false
        polling.save(to: defaults, key: pollingKey)
        tick()
    }

    /// The user asked to sign in to Claude Code. Reports whether that is really needed: a login
    /// that is current, or that Claude Code can still renew, is simply used. Asking again while
    /// this is being checked does nothing.
    func beginSignIn() async -> Bool {
        guard active, !checkingLogin else { return false }
        // An account known only from the Claude app has no Claude Code folder to look in yet.
        if let account, account.codeFolder == nil { return true }
        checkingLogin = true
        defer { checkingLogin = false }
        // Set before the first suspension, so a check already under way starts no second renewal.
        awaitingLoginUntil = currentDate().addingTimeInterval(600)
        let generation = loginGeneration, directory = configDirectory, reader = readAuth
        guard var usable = try? await usageWork({ reader(.claudeCode, directory) != nil }),
              active, generation == loginGeneration else { return false }
        if !usable, await renew(directory, deadline: Self.signInRenewalDeadline) == .renewed {
            guard let found = try? await usageWork({ reader(.claudeCode, directory) != nil }) else { return false }
            usable = found
        }
        guard active, generation == loginGeneration else { return false }
        if usable { awaitingLoginUntil = nil }
        // The last check found no login and sent nothing, so looking again now costs no request.
        if missingLogin { polling.retry(at: currentDate()) }
        // Automatic stays with the tool it resolved; let it find Claude Code's login instead.
        if loginSource == .automatic, let pinned = polling.authSource, pinned != .claudeCode { clearSelectedLogin() }
        else { polling.save(to: defaults, key: pollingKey); tick() }
        return !usable
    }

    /// Joins the renewal under way, or starts one. Only the run that started it records the
    /// result in the renewal gate, so one run is counted once.
    private func renew(_ directory: URL, deadline: TimeInterval) async -> ClaudeLoginRenewal {
        if let renewal { return await renewal.value }
        let generation = loginGeneration, run = renewLogin
        let task = Task { (try? await usageWork { run(directory, deadline) }) ?? .failed }
        renewal = task
        let result = await task.value
        guard generation == loginGeneration else { return result }
        renewal = nil
        polling.renewalEnded(result, at: currentDate())
        return result
    }

    /// Limits cannot be read until the user signs in to Claude Code: its login is missing or can
    /// no longer be renewed, and the Claude app has saved nothing recent to show instead.
    var needsClaudeCodeLogin: Bool {
        let current = reading().map { $0.source == .desktop && currentDate().timeIntervalSince($0.at) <= ClaudeDesktopUsage.freshness } ?? false
        switch loginSource {
        case .opencode, .pi: return false
        case .claudeDesktop: return !current
        case .automatic, .claudeCode: return missingLogin && !current
        }
    }

    enum ReadingSource { case account, desktop }
    struct Reading {
        let usage: Usage
        let source: ReadingSource
        let at: Date
    }

    /// The reading on display: the selected login's, the Claude app's, or under Automatic the
    /// newer of the two. A saved reading stays until its window renews, for a day at most, and
    /// its age is shown beside it. Renewed windows are unknown, not an invented zero.
    func reading(now: Date? = nil) -> Reading? {
        let now = now ?? currentDate()
        let saved = desktop.flatMap { reading in
            reading.usage(at: now).map { Reading(usage: withAccountRenewals($0, reading: reading, now: now), source: .desktop, at: reading.observedAt) }
        }
        if loginSource == .claudeDesktop { return saved }
        var account: Reading?
        if var usage, let at = lastGoodAt, now.timeIntervalSince(at) <= 86_400 {
            usage.limits = usage.limits.filter { $0.resetsAt.map { $0 > now } ?? (now.timeIntervalSince(at) <= 3600) }
            if !usage.limits.isEmpty || usage.credits != nil { account = Reading(usage: usage, source: .account, at: at) }
        }
        guard loginSource == .automatic, let saved else { return account }
        guard let account, account.at >= saved.at else { return saved }
        return account
    }

    func displayUsage(now: Date? = nil) -> Usage? { reading(now: now)?.usage }

    /// The Claude app's file has no renewal times. The same account's last endpoint reading
    /// does, and they still hold while that window has not renewed.
    private func withAccountRenewals(_ usage: Usage, reading: ClaudeDesktopReading, now: Date) -> Usage {
        guard let organization = reading.organization, !organization.isEmpty,
              polling.authIdentity?.hasSuffix("|\(organization)") == true, let known = self.usage else { return usage }
        var usage = usage
        usage.limits = usage.limits.map { limit in
            guard limit.resetsAt == nil, let renewal = known.limits.first(where: { $0.id == limit.id })?.resetsAt,
                  renewal > now else { return limit }
            return Limit(id: limit.id, label: limit.label, pct: limit.pct, resetsAt: renewal, window: limit.window)
        }
        return usage
    }

    private func fetch() {
        guard !inFlight, polling.begin(at: currentDate()) else { return }
        inFlight = true
        // Save the request gate before starting, so quitting/relaunching cannot bypass it.
        polling.save(to: defaults, key: pollingKey)
        let generation = loginGeneration
        // One of several accounts reads only its own Claude Code login: OpenCode and Pi name no account.
        let source = account != nil ? .claudeCode : loginSource == .automatic ? polling.authSource ?? .automatic : loginSource
        let directory = configDirectory, reader = readAuth
        request = Task {
            defer { if generation == loginGeneration { polling.save(to: defaults, key: pollingKey); inFlight = false } }
            do {
                // Pin Automatic to its resolved tool after a successful read. A temporary
                // Keychain failure must not silently select someone else's OpenCode/Pi login.
                var auth = try await usageWork { reader(source, directory) }
                guard active, !Task.isCancelled, generation == loginGeneration else { return }
                // A login that ran out is Claude Code's to renew. Ask it to, rarely, and look again.
                if auth == nil, source == .automatic || source == .claudeCode, !awaitingLogin,
                   polling.beginRenewal(at: currentDate()) {
                    polling.save(to: defaults, key: pollingKey)
                    let renewal = await renew(directory, deadline: Self.renewalDeadline)
                    guard active, !Task.isCancelled, generation == loginGeneration else { return }
                    // Unlike a Keychain item caught mid-rewrite, this login is known to be over.
                    if renewal != .unavailable { cachedToken = nil }
                    if renewal == .renewed {
                        auth = try await usageWork { reader(source, directory) }
                        guard active, !Task.isCancelled, generation == loginGeneration else { return }
                    }
                }
                if let auth {
                    // An unchanged token is the same login. A profile beside it that names
                    // another account was rewritten by another session sharing the folder, such
                    // as the Claude app's Claude Code, and says nothing about this login: its
                    // reading and its name stay. A new token comes with the account it names.
                    let sameLogin = cachedToken == auth.token
                    if !auth.hasAccountMetadata, !sameLogin {
                        // These tools don't report account IDs. A replaced access token could
                        // mean either refresh or account switch: don't reuse its old limits,
                        // including across launches where there is no cached token to compare.
                        polling.clearReading()
                    }
                    if !sameLogin || polling.authIdentity == auth.identity {
                        polling.selectIdentity(auth)
                        usage = polling.usage; lastGoodAt = polling.lastGoodAt
                        authLabel = auth.label
                        authPlan = auth.plan
                    }
                    cachedToken = auth.token
                    // Which folders are one account was decided by the account this profile
                    // named then; a new login of another account has it decided again.
                    if account != nil, !sameLogin, auth.organization != knownProfileOrganization {
                        knownProfileOrganization = auth.organization
                        onOrganizationChange?()
                    }
                }
                guard let token = cachedToken else { throw FetchError.noToken }
                let fresh = try await fetchLimits(token)
                guard active, !Task.isCancelled, generation == loginGeneration else { return }
                polling.succeeded(fresh, at: currentDate())
                usage = fresh
                lastGoodAt = polling.lastGoodAt
                lastError = nil; missingLogin = false; awaitingLoginUntil = nil
            } catch {
                guard active, !Task.isCancelled else { return }
                guard generation == loginGeneration else {
                    // Throttling belongs to the global gate, even after selecting a new login.
                    if let failure = error as? FetchError, failure.isTransient {
                        polling.failed(failure, at: currentDate())
                    }
                    return
                }
                if case FetchError.http(401, _, _) = error { cachedToken = nil }
                lastError = error.localizedDescription
                polling.failed(error, at: currentDate())
                if case FetchError.noToken = error {
                    missingLogin = true
                    // Nothing was sent, so the request cadence learned from throttling does not apply.
                    polling.retry(at: currentDate().addingTimeInterval(awaitingLogin ? 10 : 60))
                } else { missingLogin = false }
            }
        }
    }

    /// The plan the reading on display belongs to.
    var plan: String? { reading()?.source == .desktop ? desktop?.plan : authPlan }

    /// Nil while the reading on display is current.
    var warning: String? {
        guard let shown = reading() else { return lastError != nil || loginSource == .claudeDesktop ? status : nil }
        switch shown.source {
        case .desktop: return currentDate().timeIntervalSince(shown.at) > ClaudeDesktopUsage.freshness ? status : nil
        case .account: return lastError == nil ? nil : status
        }
    }

    /// The Claude app checks its limits only while its menu-bar icon is on, and pauses a day after
    /// that icon was last opened, which nothing outside it can keep going. A login Frog can check
    /// with is the dependable source.
    private let signInHint = "The Claude app saves its limits only while its menu-bar icon is on and was opened recently. Sign in to Claude Code and Frog checks them itself."

    var status: String {
        if checkingLogin { return "Checking Claude Code’s login…" }
        if let shown = reading(), shown.source == .desktop {
            let fresh = currentDate().timeIntervalSince(shown.at) <= ClaudeDesktopUsage.freshness
            return "Saved by the Claude app at \(dayClockForStatus(shown.at))."
                + (fresh ? "" : needsClaudeCodeLogin ? " \(signInHint)" : lastError.map { " Couldn’t refresh from your account: \($0)." } ?? "")
        }
        if loginSource == .claudeDesktop { return "No current reading from the Claude app. \(signInHint)" }
        // Someone who only uses the Claude app has no Claude Code login to check with.
        if missingLogin, !inFlight, loginSource == .automatic || loginSource == .claudeCode {
            return "Claude Code is not signed in on this Mac, or its login can no longer be renewed. Sign in to Claude Code and Frog checks your limits itself."
                + (lastGoodAt.map { " Last account check: \(dayClockForStatus($0))." } ?? "")
        }
        var s: String
        if inFlight { s = "Refreshing…" }
        else if lastError == "rate limited" {
            s = "Anthropic’s usage endpoint is throttling checks (HTTP 429). This is not your session or weekly limit."
            if let at = lastGoodAt { s += displayUsage() == nil ? " Last successful check: \(resetClock(at)); current limits unknown." : " Showing saved limits from \(resetClock(at))." }
        }
        else if let e = lastError, let at = lastGoodAt { s = "Couldn't refresh: \(e). Last successful check: \(resetClock(at))." }
        else if let e = lastError { s = "Couldn't load usage: \(e)." }
        else if let at = lastGoodAt, displayUsage() == nil { s = "Current limits are unknown. Last successful check: \(resetClock(at))." }
        else if let at = lastGoodAt { s = "Updated \(dayClockForStatus(at))" }
        else { s = "Loading…" }
        if lastError != nil, !inFlight {
            if let at = polling.lastAttemptAt { s += " Last attempt: \(dayClockForStatus(at))." }
            s += " Next automatic check: \(resetClock(nextFetchAt))."
        }
        else if usage == nil, !inFlight, currentDate() < nextFetchAt { s += " Waiting for the saved request cooldown until \(resetClock(nextFetchAt))." }
        return s
    }

    private func dayClockForStatus(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? clock(date) : resetClock(date)
    }
}
