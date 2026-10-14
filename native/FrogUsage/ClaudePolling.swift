import Foundation

/// Only displayable usage and scheduling state are saved. OAuth credentials stay in memory.
struct ClaudePollingState: Codable {
    static let defaultsKey = "claudePollingState.v1"
    var usage: Usage?
    var lastGoodAt: Date?
    private(set) var interval: TimeInterval = 60
    private(set) var nextFetchAt = Date.distantPast
    private(set) var lastFailure: String?
    private(set) var lastAttemptAt: Date?
    private(set) var authIdentity: String?
    private(set) var authSource: ClaudeLoginSource?
    private(set) var authLabel: String?
    /// Optional so state saved by earlier versions still loads.
    private(set) var nextRenewalAt: Date?
    private(set) var renewalInterval: TimeInterval?
    static let renewalFloor: TimeInterval = 1800
    /// When throttling last slowed the poll, or when it last eased; nil at the usual pace.
    private(set) var slowedAt: Date?
    /// Server errors in a row. They delay the next attempt without changing the pace.
    private(set) var outages: Int?
    /// How long throttling has to stay away before the poll takes one step back towards a minute.
    static let quietPeriod: TimeInterval = 3600

    mutating func begin(at now: Date) -> Bool {
        guard now >= nextFetchAt else { return false }
        nextFetchAt = now.addingTimeInterval(interval)
        lastAttemptAt = now
        return true
    }

    /// The last attempt found no login and sent nothing, so looking again sooner costs no request.
    mutating func retry(at date: Date) { nextFetchAt = min(nextFetchAt, date) }

    /// Asking Claude Code to renew its login launches it and costs one small request: do it
    /// rarely, and ever more rarely while it keeps failing.
    mutating func beginRenewal(at now: Date) -> Bool {
        guard now >= nextRenewalAt ?? .distantPast else { return false }
        nextRenewalAt = now.addingTimeInterval(renewalInterval ?? Self.renewalFloor)
        return true
    }

    mutating func renewalEnded(_ result: ClaudeLoginRenewal, at now: Date) {
        switch result {
        case .renewed: renewalInterval = nil; nextRenewalAt = now.addingTimeInterval(Self.renewalFloor)
        // Nothing to renew is a cheap local finding; a login may lapse soon after.
        case .unavailable: nextRenewalAt = now.addingTimeInterval(300)
        case .failed:
            let interval = min((renewalInterval ?? Self.renewalFloor) * 2, 8 * 3600)
            renewalInterval = interval; nextRenewalAt = now.addingTimeInterval(interval)
        }
    }

    mutating func clearReading() {
        usage = nil; lastGoodAt = nil; lastFailure = nil
        authIdentity = nil; authSource = nil; authLabel = nil
        // A profile change must not erase the global request gate or learned backoff.
    }

    mutating func selectIdentity(_ auth: ClaudeAuth) {
        if authIdentity != auth.identity { clearReading() }
        authIdentity = auth.identity
        authSource = auth.source
        authLabel = auth.label
    }

    mutating func succeeded(_ usage: Usage, at now: Date) {
        self.usage = usage
        lastGoodAt = now
        lastFailure = nil
        // A working login makes earlier renewal failures history.
        renewalInterval = nil; nextRenewalAt = nil
        outages = nil
        ease(at: now)
    }

    /// The slower pace learned from throttling is kept while the throttling is recent, so one
    /// good answer does not send the poll straight back into it, and halves for every quiet
    /// hour after that, also hours in which nothing was asked or Frog was not running. State
    /// from a version that kept it for good says nothing about when it was learned and counts
    /// as long ago.
    private mutating func ease(at now: Date) {
        guard interval > 60 else { slowedAt = nil; return }
        let quiet = now.timeIntervalSince(slowedAt ?? .distantPast)
        // A time ahead of the clock means the clock was set back: the hour starts over.
        if quiet < 0 { slowedAt = now; return }
        let hours = (quiet / Self.quietPeriod).rounded(.down)
        guard hours >= 1 else { return }
        // Four steps bring even ten minutes back to one.
        interval = max(60, interval / pow(2, min(hours, 4)))
        // The part of an hour since the last whole one counts towards the next step.
        slowedAt = interval > 60 ? slowedAt?.addingTimeInterval(hours * Self.quietPeriod) : nil
    }

    mutating func failed(_ error: Error, at now: Date) {
        guard let error = error as? FetchError, error.isTransient else {
            lastFailure = "couldn't refresh the last reading"
            return
        }
        let wait: TimeInterval
        if case .http(429, _, _) = error {
            interval = min(interval * 2, 600)
            slowedAt = now
            outages = nil
            wait = interval
            lastFailure = "rate limited"
        } else {
            // An outage is not an answer about how often to ask: wait longer while it lasts,
            // and go on at the pace from before once the service is back.
            let count = min((outages ?? 0) + 1, 4)
            outages = count
            wait = min(interval * pow(2, Double(count)), 600)
            lastFailure = "service temporarily unavailable"
        }
        nextFetchAt = max(nextFetchAt, now.addingTimeInterval(max(wait, error.retryAfter ?? 0)))
    }

    static func load(from defaults: UserDefaults, now: Date = Date()) -> ClaudePollingState {
        guard let data = defaults.data(forKey: defaultsKey),
              var state = try? JSONDecoder().decode(Self.self, from: data),
              state.interval.isFinite, (60...600).contains(state.interval) else { return Self() }
        // Frog may have been closed for longer than the throttling is worth remembering.
        state.ease(at: now)
        return state
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
