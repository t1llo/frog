// Data layer: read Claude Code's OAuth token, call the usage endpoint `/usage` uses, parse it.
import Foundation
import CryptoKit
import Darwin

enum ClaudeLoginSource: String, CaseIterable, Identifiable, Codable {
    case automatic = "Automatic", claudeCode = "Claude Code", claudeDesktop = "Claude Desktop", opencode = "OpenCode", pi = "Pi"
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
    /// The organization the profile beside the login names; non-secret, held in memory only.
    var organization: String?
}

enum ClaudePaths {
    static let directoryPreference = "claudeConfigDirectory"
    static var defaultDirectory: URL { defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser) }
    static func defaultDirectory(home: URL) -> URL { home.appendingPathComponent(".claude") }
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

struct Limit: Identifiable, Codable, Equatable {
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
        case .noToken: return "no current Claude login in the selected tool; sign in there to renew it"
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
    guard let result = usageProcess(URL(fileURLWithPath: "/usr/bin/security"),
                                    arguments: ["find-generic-password", "-s", service, "-w"], timeout: 5),
          result.status == 0,
          let text = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
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
    // Claude Desktop keeps its login to itself; its saved readings are read separately.
    let candidates: [ClaudeLoginSource] = source == .automatic ? [.claudeCode, .opencode, .pi] : [source]
    for candidate in candidates where candidate != .claudeDesktop {
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
            let account = claudeProfile(directory: directory)
            let accountID = account["accountUuid"] as? String ?? ""
            let orgID = account["organizationUuid"] as? String ?? ""
            let details = [account["emailAddress"] as? String, account["organizationName"] as? String].compactMap { $0 }
            let label = (["Claude Code (\(directory.lastPathComponent))"] + details).joined(separator: " · ")
            return ClaudeAuth(token: token, source: candidate, identity: "claudeCode|\(directory.path)|\(accountID)|\(orgID)",
                              label: label, hasAccountMetadata: !accountID.isEmpty && !orgID.isEmpty,
                              plan: claudePlanName(account), organization: orgID.isEmpty ? nil : orgID)
        }
        let directory = candidate == .pi ? piAgentDirectory : openCodeDataDirectory()
        guard let oauth = credentialJSON(directory.appendingPathComponent("auth.json"))?["anthropic"] as? [String: Any],
              oauth["type"] as? String == "oauth", let token = claudeOAuthToken(oauth, openCode: true) else { continue }
        return ClaudeAuth(token: token, source: candidate, identity: "\(candidate.rawValue)|\(directory.path)",
                          label: "\(candidate.rawValue) saved Claude login (account identity not reported)")
    }
    return nil
}

/// Claude Code holds a login for this profile whose access token has run out, and the means to
/// renew it. Only the presence of its renewal token is checked: renewing stays Claude Code's job.
/// Blocking, read-only.
func claudeCodeLoginLapsed(directory: URL, now: Date = Date()) -> Bool {
    var logins = claudeKeychainServices(directory: directory).compactMap(readKeychainCredentials)
    if let oauth = credentialJSON(directory.appendingPathComponent(".credentials.json"))?["claudeAiOauth"] as? [String: Any] {
        logins.append(oauth)
    }
    return claudeCodeLoginLapsed(logins, now: now)
}

func claudeCodeLoginLapsed(_ logins: [[String: Any]], now: Date) -> Bool {
    !logins.contains { claudeOAuthToken($0, now: now) != nil }
        && logins.contains { ($0["refreshToken"] as? String)?.isEmpty == false }
}

/// The account profile Claude Code caches beside its settings: names, plan tier and ids, no tokens.
func claudeProfile(directory: URL) -> [String: Any] {
    claudeProfile(at: claudeProfileURL(directory: directory))
}

func claudeProfile(at url: URL) -> [String: Any] {
    credentialJSON(url)?["oauthAccount"] as? [String: Any] ?? [:]
}

/// The default folder keeps its profile in the home folder, any other one inside itself.
func claudeProfileURL(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    directory.standardizedFileURL == ClaudePaths.defaultDirectory(home: home).standardizedFileURL
        ? home.appendingPathComponent(".claude.json")
        : directory.appendingPathComponent(".claude.json")
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

/// A relative `XDG_DATA_HOME` names a place in whatever folder Frog happens to run in, so only
/// an absolute one is followed, as when Frog starts OpenCode itself.
func openCodeDataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    let base = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        ?? home.appendingPathComponent(".local/share")
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

/// An ISO 8601 time with or without fractional seconds. The formatters are shared by every log
/// reader and never changed once made, so any thread may use them.
func isoDate(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    return isoFractionalSeconds.date(from: s) ?? isoWholeSeconds.date(from: s)
}

private let isoFractionalSeconds = isoFormatter([.withInternetDateTime, .withFractionalSeconds])
private let isoWholeSeconds = isoFormatter([.withInternetDateTime])

private func isoFormatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = options
    return f
}

// MARK: - Formatting

/// "15:40" today, "Thu 09:00" within six days before or after, "4 Oct" further away, each
/// written the way the person's locale and clock setting write it.
func resetClock(_ date: Date?, now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
    guard let date else { return "" }
    if Calendar.current.isDate(date, inSameDayAs: now) { return clock(date, locale: locale) }
    let style = Date.FormatStyle(locale: locale)
    if abs(date.timeIntervalSince(now)) < 6 * 86_400 { return date.formatted(style.weekday(.abbreviated).hour().minute()) }
    return date.formatted(style.month(.abbreviated).day())
}

/// The time of day as `resetClock` writes it, so one sentence never mixes two clock formats.
func clock(_ d: Date, locale: Locale = .autoupdatingCurrent) -> String {
    d.formatted(Date.FormatStyle(locale: locale).hour().minute())
}

func money(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }
