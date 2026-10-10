// Data layer: read Claude Code's OAuth token, call the usage endpoint `/usage` uses, parse it.
import Foundation
import CryptoKit
import Darwin

enum ClaudeLoginSource: String, CaseIterable, Identifiable, Codable {
    case automatic = "Automatic", claudeCode = "Claude Code", opencode = "OpenCode", pi = "Pi"
    var id: String { rawValue }
}

struct ClaudeAuth {
    let token: String
    let source: ClaudeLoginSource
    /// Non-secret identity metadata only. Never save the token or a token-derived identifier.
    let identity: String
    let label: String
    var hasAccountMetadata = false
    var plan: String?
}

enum ClaudePaths {
    static let directoryPreference = "claudeConfigDirectory"
    static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }
    static func directory(defaults: UserDefaults = UsagePreferences.defaults) -> URL {
        let path = defaults.string(forKey: directoryPreference)
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        guard let path, !path.isEmpty else { return defaultDirectory }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    static var transcriptRoots: [URL] {
        transcriptRoots(home: FileManager.default.homeDirectoryForCurrentUser, configured: directory())
    }
    static func transcriptRoots(home: URL, configured: URL) -> [URL] {
        let directories = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude"), configured]
        var seen = Set<String>()
        return directories.map { $0.appendingPathComponent("projects").standardizedFileURL }
            .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }
}

var piAgentDirectory: URL {
    let path = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
    if let path, !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
}

/// A custom CLI profile has its own Keychain service, not the personal profile's item.
func claudeKeychainServices(directory: URL) -> [String] {
    let path = directory.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    let suffix = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    let hashed = "Claude Code-credentials-\(suffix)"
    return directory.standardizedFileURL == ClaudePaths.defaultDirectory.standardizedFileURL
        ? ["Claude Code-credentials", hashed] : [hashed]
}

struct Limit: Identifiable, Codable {
    let id: String
    let label: String
    let pct: Double
    let resetsAt: Date?
    /// Length of the rolling window, used for the even-pace marker. Nil hides the marker.
    let window: TimeInterval?
}
struct Credits: Codable { let usedCents: Double; let limitCents: Double? }
struct Usage: Codable { var limits: [Limit] = []; var credits: Credits? }

/// JSON numeric fields can be integral or fractional, but booleans are not counts.
func usageNumber(_ any: Any?) -> Double? {
    guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.doubleValue
}

enum FetchError: LocalizedError {
    case noToken
    case http(Int, retryAfter: TimeInterval?, message: String?)
    case badJSON
    var errorDescription: String? {
        switch self {
        case .noToken: return "selected tool has no usable Claude OAuth login; sign in there, or select another saved login. Claude Desktop has a separate login"
        case .http(401, _, _): return "selected Claude login expired; renew it in the tool that owns it"
        case .http(429, _, _): return "rate limited"
        case .http(let code, _, let m): return "HTTP \(code)" + (m.map { " (\($0))" } ?? "")
        case .badJSON: return "unexpected response"
        }
    }
    var isTransient: Bool {
        if case .http(let code, _, _) = self { return code == 429 || code >= 500 }
        return false
    }
    var retryAfter: TimeInterval? {
        if case .http(_, let r, _) = self { return r }
        return nil
    }
}

/// Reads the token through `/usr/bin/security` instead of SecItemCopyMatching.
///
/// Claude Code writes its "Claude Code-credentials" item with the `security` tool, so that tool
/// is on the item's access list. It rewrites the item every time it refreshes the token, which
/// resets the list and throws away any "Always Allow" granted to this app. Asking `security`
/// to read it avoids both the first prompt and the prompt that used to come back after every
/// token refresh. Blocking; call it off the main thread.
private func readKeychainCredentials(service: String) -> [String: Any]? {
    guard !Task.isCancelled else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let descriptor = out.fileHandleForReading.fileDescriptor
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        if Task.isCancelled || ContinuousClock.now >= deadline || data.count > 1_048_576 {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            return nil
        }
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        else if !p.isRunning { break }
        else { usleep(10_000) }
    }
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any]
    else { return nil }
    return oauth
}

private func credentialJSON(_ url: URL) -> [String: Any]? {
    guard !Task.isCancelled else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Blocking, read-only. Call off the main thread. Explicit selections never fall through to
/// a different tool/account; an HTTP 429 must not cause account switching or extra requests.
func readClaudeAuth(source: ClaudeLoginSource, directory: URL) -> ClaudeAuth? {
    let candidates: [ClaudeLoginSource] = source == .automatic ? [.claudeCode, .opencode, .pi] : [source]
    for candidate in candidates {
        guard !Task.isCancelled else { return nil }
        if candidate == .claudeCode {
            var token: String?
            for service in claudeKeychainServices(directory: directory) {
                if let oauth = readKeychainCredentials(service: service), let access = claudeOAuthToken(oauth) {
                    token = access; break
                }
            }
            // Claude Code also writes this fallback when Keychain is unavailable. Do not modify it.
            if token == nil, let oauth = credentialJSON(directory.appendingPathComponent(".credentials.json"))?["claudeAiOauth"] as? [String: Any] {
                token = claudeOAuthToken(oauth)
            }
            guard let token else { continue }
            let config = directory.standardizedFileURL == ClaudePaths.defaultDirectory.standardizedFileURL
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
                : directory.appendingPathComponent(".claude.json")
            let account = credentialJSON(config)?["oauthAccount"] as? [String: Any] ?? [:]
            let accountID = account["accountUuid"] as? String ?? ""
            let orgID = account["organizationUuid"] as? String ?? ""
            let details = [account["emailAddress"] as? String, account["organizationName"] as? String].compactMap { $0 }
            let label = (["Claude Code (\(directory.lastPathComponent))"] + details).joined(separator: " · ")
            return ClaudeAuth(token: token, source: candidate, identity: "claudeCode|\(directory.path)|\(accountID)|\(orgID)",
                              label: label, hasAccountMetadata: !accountID.isEmpty && !orgID.isEmpty,
                              plan: claudePlanName(account))
        }
        let directory = candidate == .pi ? piAgentDirectory : openCodeDataDirectory
        guard let oauth = credentialJSON(directory.appendingPathComponent("auth.json"))?["anthropic"] as? [String: Any],
              oauth["type"] as? String == "oauth", let token = claudeOAuthToken(oauth, openCode: true) else { continue }
        return ClaudeAuth(token: token, source: candidate, identity: "\(candidate.rawValue)|\(directory.path)",
                          label: "\(candidate.rawValue) saved Claude login (account identity not reported)")
    }
    return nil
}

/// Profile metadata only; never infer a subscription from token volume or quota percentages.
func claudePlanName(_ account: [String: Any]) -> String? {
    let type = (account["organizationType"] as? String ?? "").lowercased()
    let tier = ((account["organizationRateLimitTier"] as? String) ?? (account["userRateLimitTier"] as? String) ?? "").lowercased()
    if type.contains("enterprise") { return "Enterprise" }
    if type.contains("team") { return "Team" }
    if tier.contains("max_20x") { return "Max 20×" }
    if tier.contains("max_5x") { return "Max 5×" }
    if type.contains("max") || tier.contains("max") { return "Max" }
    if type.contains("pro") || tier.contains("pro") { return "Pro" }
    return nil
}

var openCodeDataDirectory: URL {
    let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    return base.appendingPathComponent("opencode")
}

func claudeOAuthToken(_ json: [String: Any], openCode: Bool = false, now: Date = Date()) -> String? {
    // Both tools store expiry in milliseconds. Never consume their refresh tokens.
    if let expiry = json[openCode ? "expires" : "expiresAt"] as? Double,
       (!expiry.isFinite || Date(timeIntervalSince1970: expiry / 1000) <= now) { return nil }
    guard let token = json[openCode ? "access" : "accessToken"] as? String, !token.isEmpty else { return nil }
    return token
}

func fetchUsage(token: String) async throws -> Usage {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 10
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Frog/1.0", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as? HTTPURLResponse
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let code = http?.statusCode, code != 200 {
        let retry = retryAfterDelay(http?.value(forHTTPHeaderField: "Retry-After"))
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        throw FetchError.http(code, retryAfter: retry, message: message)
    }
    guard let json else { throw FetchError.badJSON }
    let usage = parse(json)
    guard !usage.limits.isEmpty || usage.credits != nil else { throw FetchError.badJSON }
    return usage
}

/// Retry-After may be a delay in seconds or an HTTP date. Honor either form, including
/// cooldowns longer than the poller's normal maximum interval.
func retryAfterDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if let seconds = Double(value) { return seconds.isFinite && seconds >= 0 ? seconds : nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
}

func parse(_ json: [String: Any]) -> Usage {
    var usage = Usage()
    let week: TimeInterval = 7 * 86_400
    var keys: [(String, String, TimeInterval)] = [
        ("five_hour", "Session", 5 * 3600),
        ("seven_day", "Week", week),
        ("seven_day_sonnet", "Week · Sonnet", week),
        ("seven_day_opus", "Week · Opus", week),
    ]
    let known = Set(keys.map { $0.0 })
    for key in json.keys.sorted() where !known.contains(key) && (key.hasPrefix("seven_day_") || key.hasPrefix("five_hour_")) {
        let weekly = key.hasPrefix("seven_day_")
        let name = String(key.dropFirst(10)).replacingOccurrences(of: "_", with: " ").capitalized
        keys.append((key, "\(weekly ? "Week" : "Session") · \(name)", weekly ? week : 5 * 3600))
    }
    for (key, label, window) in keys {
        guard let d = json[key] as? [String: Any], let pct = usageNumber(d["utilization"]),
              pct.isFinite, pct >= 0 else { continue }
        usage.limits.append(Limit(id: key, label: label, pct: pct, resetsAt: isoDate(d["resets_at"]), window: window))
    }
    if let e = json["extra_usage"] as? [String: Any], e["is_enabled"] as? Bool == true,
       let used = e["used_credits"] as? Double {
        usage.credits = Credits(usedCents: used, limitCents: e["monthly_limit"] as? Double)
    }
    return usage
}

func isoDate(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// MARK: - Formatting

/// "2h 14m", "3d 4h", "12m".
func remaining(to date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let mins = max(0, Int(date.timeIntervalSince(now) / 60))
    let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// "in 2h 14m", "in 3d 4h", "in 12m".
func countdown(to date: Date?, now: Date = Date()) -> String {
    date == nil ? "" : "in " + remaining(to: date, now: now)
}

/// "3:40pm", "Thu 9am", "Oct 4".
func resetClock(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    let time = Calendar.current.component(.minute, from: date) == 0 ? "ha" : "h:mma"
    if Calendar.current.isDateInToday(date) { f.dateFormat = time }
    else if date.timeIntervalSinceNow < 6 * 86_400 { f.dateFormat = "EEE \(time)" }
    else { f.dateFormat = "MMM d" }
    return f.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
}

func firstOfNextMonth() -> String {
    var c = Calendar.current.dateComponents([.year, .month], from: Date())
    c.month! += 1; c.day = 1
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d"
    return f.string(from: Calendar.current.date(from: c)!)
}

func clock(_ d: Date) -> String {
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return f.string(from: d)
}

func money(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }
