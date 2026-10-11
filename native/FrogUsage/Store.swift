// Polling state. Same schedule as before: every minute, doubling up to 10 minutes after a 429
// or 5xx, never faster than the server's Retry-After, and menu opens cannot bypass it.
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
    var configDirectory: URL { ClaudePaths.directory(defaults: defaults) }

    private let defaults: UserDefaults
    private var polling: ClaudePollingState
    var nextFetchAt: Date { polling.nextFetchAt }
    /// Claude Code rewrites the Keychain item when it refreshes the token. A read that lands in
    /// that window finds nothing, so remember the last token we saw and fall back to it.
    private var cachedToken: String?
    private var loginGeneration = 0
    private let readAuth: @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth?
    private let fetchLimits: @Sendable (String) async throws -> Usage
    private let readDesktop: @Sendable (URL) -> ClaudeDesktopReading?
    private let currentDate: @Sendable () -> Date
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var desktopRead: Task<Void, Never>?
    /// The last check found no login at all, as opposed to a request that failed.
    private var missingLogin = false
    private var active = false

    init(defaults: UserDefaults = UsagePreferences.defaults, startPolling: Bool = false,
         readAuth: @escaping @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth? = { readClaudeAuth(source: $0, directory: $1) },
         fetchLimits: @escaping @Sendable (String) async throws -> Usage = { try await fetchUsage(token: $0) },
         readDesktop: @escaping @Sendable (URL) -> ClaudeDesktopReading? = { _ in nil },
         currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.readAuth = readAuth
        self.fetchLimits = fetchLimits
        self.readDesktop = readDesktop
        self.currentDate = currentDate
        loginSource = defaults.string(forKey: "claudeLoginSource").flatMap(ClaudeLoginSource.init(rawValue:)) ?? .automatic
        polling = ClaudePollingState.load(from: defaults)
        usage = polling.usage
        lastGoodAt = polling.lastGoodAt
        lastError = polling.lastFailure
        authLabel = polling.authLabel
        if startPolling { start() }
    }

    func start() {
        guard !active else { return }; active = true
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        active = false; loginGeneration += 1
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        desktopRead?.cancel(); desktopRead = nil
        inFlight = false; cachedToken = nil
    }

    /// Fetch if the schedule says so. The timer, panel opens and the Refresh button all go
    /// through here, so none of them can exceed the current cadence. The Claude app's saved
    /// reading is a small local file and is reread every time.
    func tick() {
        guard active else { return }
        refreshDesktop()
        if loginSource != .claudeDesktop, currentDate() >= nextFetchAt { fetch() }
    }

    private func refreshDesktop() {
        guard desktopRead == nil else { return }
        let generation = loginGeneration, directory = configDirectory, reader = readDesktop
        desktopRead = Task {
            let reading = try? await usageWork { reader(directory) }
            guard !Task.isCancelled, generation == loginGeneration else { return }
            desktopRead = nil
            if reading != desktop { desktop = reading }
        }
    }

    func setLoginSource(_ source: ClaudeLoginSource) {
        guard source != loginSource else { return }
        loginSource = source
        defaults.set(source.rawValue, forKey: "claudeLoginSource")
        clearSelectedLogin()
    }

    func setConfigDirectory(_ directory: URL) {
        defaults.set(directory.standardizedFileURL.path, forKey: ClaudePaths.directoryPreference)
        loginSource = .claudeCode
        defaults.set(loginSource.rawValue, forKey: "claudeLoginSource")
        clearSelectedLogin()
    }

    private func clearSelectedLogin() {
        loginGeneration += 1
        request?.cancel(); request = nil; inFlight = false
        desktopRead?.cancel(); desktopRead = nil
        cachedToken = nil
        polling.clearReading()
        usage = nil; lastGoodAt = nil; lastError = nil; authLabel = nil; authPlan = nil; missingLogin = false
        polling.save(to: defaults)
        tick()
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
        polling.save(to: defaults)
        let generation = loginGeneration
        let source = loginSource == .automatic ? polling.authSource ?? .automatic : loginSource
        let directory = configDirectory, reader = readAuth
        request = Task {
            defer { if generation == loginGeneration { polling.save(to: defaults); inFlight = false } }
            do {
                // Pin Automatic to its resolved tool after a successful read. A temporary
                // Keychain failure must not silently select someone else's OpenCode/Pi login.
                let auth = try await usageWork { reader(source, directory) }
                guard active, !Task.isCancelled, generation == loginGeneration else { return }
                if let auth {
                    if !auth.hasAccountMetadata, cachedToken != auth.token {
                        // These tools don't report account IDs. A replaced access token could
                        // mean either refresh or account switch: don't reuse its old limits,
                        // including across launches where there is no cached token to compare.
                        polling.clearReading()
                    }
                    polling.selectIdentity(auth)
                    usage = polling.usage; lastGoodAt = polling.lastGoodAt
                    authLabel = auth.label
                    authPlan = auth.plan
                    cachedToken = auth.token
                }
                guard let token = cachedToken else { throw FetchError.noToken }
                let fresh = try await fetchLimits(token)
                guard active, !Task.isCancelled, generation == loginGeneration else { return }
                polling.succeeded(fresh, at: currentDate())
                usage = fresh
                lastGoodAt = polling.lastGoodAt
                lastError = nil; missingLogin = false
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
                if case FetchError.noToken = error { missingLogin = true } else { missingLogin = false }
                lastError = error.localizedDescription
                polling.failed(error, at: currentDate())
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

    /// What keeps the Claude app's readings coming, said as precisely as its settings allow.
    private var menuBarHint: String {
        desktop?.menuBarIcon == false
            ? "The Claude app’s menu bar icon is off, so it saves your limits only now and then. Turn the icon on in the Claude app’s settings to keep them current."
            : "Claude saves its limits every few minutes while its menu bar icon is on; turn the icon on in the Claude app’s settings."
    }

    var status: String {
        if let shown = reading(), shown.source == .desktop {
            let fresh = currentDate().timeIntervalSince(shown.at) <= ClaudeDesktopUsage.freshness
            return "Saved by the Claude app at \(dayClockForStatus(shown.at))." + (fresh ? "" : " \(menuBarHint)")
        }
        if loginSource == .claudeDesktop { return "No current reading from the Claude app. \(menuBarHint)" }
        // Someone who only uses the Claude app has no Claude Code login to check with.
        if missingLogin, !inFlight, desktop != nil {
            return "Claude Code is not signed in on this Mac, so Frog shows the limits the Claude app saves. \(menuBarHint)"
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
