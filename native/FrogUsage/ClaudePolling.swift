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

    mutating func begin(at now: Date) -> Bool {
        guard now >= nextFetchAt else { return false }
        nextFetchAt = now.addingTimeInterval(interval)
        lastAttemptAt = now
        return true
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
        // Success deliberately keeps the slower interval learned from previous throttling.
    }

    mutating func failed(_ error: Error, at now: Date) {
        if let error = error as? FetchError, error.isTransient {
            interval = min(interval * 2, 600)
            nextFetchAt = max(nextFetchAt, now.addingTimeInterval(max(interval, error.retryAfter ?? 0)))
            if case .http(429, _, _) = error { lastFailure = "rate limited" }
            else { lastFailure = "service temporarily unavailable" }
        } else {
            lastFailure = "couldn't refresh the last reading"
        }
    }

    static func load(from defaults: UserDefaults) -> ClaudePollingState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(Self.self, from: data),
              state.interval.isFinite, (60...600).contains(state.interval) else { return Self() }
        return state
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
