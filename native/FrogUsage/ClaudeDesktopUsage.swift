// Plan limits the Claude desktop app has already checked, read from its local history file.
import Foundation

/// The newest reading the Claude app saved. Percentages come from the file; renewal times are
/// only filled in when the saved history pins them down.
struct ClaudeDesktopReading: Equatable {
    let observedAt: Date
    /// Organization the app was signed in to, when the file names one. Never shown or exported.
    let organization: String?
    var limits: [Limit]
    /// Profile metadata for the same organization, when Claude Code has cached it.
    var plan: String?
    /// Whether the Claude app's menu bar icon is on. With it off the app checks its limits
    /// only when someone looks at them, so readings arrive hours apart.
    var menuBarIcon: Bool?

    /// What can still be shown at `now`. A reading says nothing about a window that renewed
    /// after it, and without a renewal time a day-old percentage is no longer a current one.
    func usage(at now: Date) -> Usage? {
        let age = now.timeIntervalSince(observedAt)
        guard age >= -300 else { return nil }
        let current = limits.filter { limit in
            if let resets = limit.resetsAt { return resets > now }
            return age < min(limit.window ?? 86_400, 86_400)
        }
        return current.isEmpty ? nil : Usage(limits: current)
    }
}

/// The Claude app saves the percentages it checks every few minutes while its menu-bar icon is
/// on. Reading that file needs no login and sends nothing. The format belongs to the app, so an
/// unknown version or field is skipped instead of guessed.
enum ClaudeDesktopUsage {
    /// The app saves a reading every 5 to 15 minutes; an older one has missed a check.
    static let freshness: TimeInterval = 30 * 60
    private static let maximumSize = 4 << 20
    private static let week: TimeInterval = 7 * 86_400
    /// File key, the matching account-endpoint id, label and window length.
    private static let windows: [(key: String, id: String, label: String, length: TimeInterval)] = [
        ("fh", "five_hour", "Session", 5 * 3600), ("sd", "seven_day", "Week", week),
        ("sn", "seven_day_sonnet", "Week · Sonnet", week), ("so", "seven_day_opus", "Week · Opus", week),
    ]

    static func historyURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// The one display preference read from the Claude app's settings file.
    static func menuBarIcon(home: URL) -> Bool? {
        let url = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let data = try? Data(contentsOf: url), data.count <= maximumSize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool
    }

    private struct Sample {
        let date: Date
        let organization: String?
        let used: [String: Double]
    }

    static func reading(from data: Data) -> ClaudeDesktopReading? {
        guard data.count <= maximumSize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = usageNumber(root["version"]), version == 1 || version == 2,
              let entries = root["samples"] as? [[String: Any]] else { return nil }
        let samples = entries.compactMap { entry -> Sample? in
            guard let milliseconds = usageNumber(entry["t"]), milliseconds.isFinite, milliseconds > 0 else { return nil }
            // Version 1 kept the percentages beside the timestamp; version 2 nests them.
            let values = version == 1 ? entry : entry["u"] as? [String: Any] ?? [:]
            var used: [String: Double] = [:]
            for window in windows {
                if let value = usageNumber(values[window.key]), value.isFinite { used[window.key] = min(100, max(0, value)) }
            }
            return Sample(date: Date(timeIntervalSince1970: milliseconds / 1000), organization: entry["org"] as? String, used: used)
        }.sorted { $0.date < $1.date }
        guard let latest = samples.last else { return nil }
        // Another account's history says nothing about this one's windows.
        let history = samples.filter { $0.organization == latest.organization }
        let limits = windows.compactMap { window -> Limit? in
            guard let used = latest.used[window.key] else { return nil }
            let resets = window.key == "fh" ? sessionReset(history, length: window.length)
                : weeklyReset(history, key: window.key, length: window.length)
            return Limit(id: window.id, label: window.label, pct: used, resetsAt: resets, window: window.length)
        }
        return limits.isEmpty ? nil : ClaudeDesktopReading(observedAt: latest.date, organization: latest.organization, limits: limits)
    }

    /// A session renews five hours after it opened. It opened between the last reading before
    /// the current run of use and the first reading inside it; only a short gap pins that down.
    private static func sessionReset(_ history: [Sample], length: TimeInterval) -> Date? {
        guard var first = history.indices.last, let used = history[first].used["fh"], used > 0 else { return nil }
        while first > 0, let before = history[first - 1].used["fh"], before > 0,
              before <= (history[first].used["fh"] ?? 0),
              history[first].date.timeIntervalSince(history[first - 1].date) < length { first -= 1 }
        guard first > 0 else { return nil }
        return moment(after: history[first - 1].date, through: history[first].date, tolerance: 30 * 60)?
            .addingTimeInterval(length)
    }

    /// A week renewed where its percentage last fell. Only a fall seen within the past week, and
    /// between two close readings, places the next renewal.
    private static func weeklyReset(_ history: [Sample], key: String, length: TimeInterval) -> Date? {
        guard let latest = history.last else { return nil }
        for index in history.indices.dropFirst().reversed() {
            guard let before = history[index - 1].used[key], let after = history[index].used[key],
                  after + 1 < before else { continue }
            guard let renewed = moment(after: history[index - 1].date, through: history[index].date, tolerance: 3600),
                  latest.date.timeIntervalSince(renewed) < length else { return nil }
            return renewed.addingTimeInterval(length)
        }
        return nil
    }

    /// Renewals tend to fall on round times: the half hour inside the gap, else its middle.
    private static func moment(after lower: Date, through upper: Date, tolerance: TimeInterval) -> Date? {
        let gap = upper.timeIntervalSince(lower)
        guard gap > 0, gap <= tolerance else { return nil }
        let round = Date(timeIntervalSince1970: (upper.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
        return round > lower ? round : lower.addingTimeInterval(gap / 2)
    }
}

/// Blocking, read-only. The plan name is profile metadata Claude Code caches; it is only attached
/// when that profile is the organization the Claude app's reading belongs to.
func readClaudeDesktop(home: URL = FileManager.default.homeDirectoryForCurrentUser, directory: URL) -> ClaudeDesktopReading? {
    guard !Task.isCancelled, let data = try? Data(contentsOf: ClaudeDesktopUsage.historyURL(home: home)),
          var reading = ClaudeDesktopUsage.reading(from: data) else { return nil }
    let account = claudeProfile(directory: directory)
    if let organization = account["organizationUuid"] as? String, organization == reading.organization {
        reading.plan = claudePlanName(account)
    }
    reading.menuBarIcon = ClaudeDesktopUsage.menuBarIcon(home: home)
    return reading
}
