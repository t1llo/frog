import Foundation

/// A local Claude Code /stats snapshot, not an account-wide API total. Its lifetime counts
/// include older sessions outside our chart horizon and may lag current transcripts.
struct ClaudeActivity {
    let totalTokens: Double
    let cacheRead: Double
    let sessions: Int?
    let activeDays: Int
    let firstSession: Date?
    let lastActive: String?
    let computedThrough: String?
    let profile: String
}

func readClaudeActivity(directory: URL) -> ClaudeActivity? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("stats-cache.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return parseClaudeActivity(json, profile: directory.lastPathComponent)
}

func parseClaudeActivity(_ json: [String: Any], profile: String) -> ClaudeActivity? {
    guard let models = json["modelUsage"] as? [String: [String: Any]], !models.isEmpty else { return nil }
    func sum(_ key: String) -> Double {
        models.values.reduce(0) { total, model in
            guard let value = usageNumber(model[key]), value.isFinite, value >= 0 else { return total }
            return total + value
        }
    }
    let read = sum("cacheReadInputTokens")
    let days = Set((json["dailyActivity"] as? [[String: Any]] ?? []).compactMap { day -> String? in
        guard (usageNumber(day["messageCount"]) ?? 0) > 0 || (usageNumber(day["sessionCount"]) ?? 0) > 0 else { return nil }
        return day["date"] as? String
    })
    return ClaudeActivity(totalTokens: sum("inputTokens") + sum("outputTokens") + read + sum("cacheCreationInputTokens"),
                          cacheRead: read, sessions: json["totalSessions"] as? Int, activeDays: days.count,
                          firstSession: isoDate(json["firstSessionDate"]), lastActive: days.max(),
                          computedThrough: json["lastComputedDate"] as? String, profile: profile)
}
