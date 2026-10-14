import Foundation

enum ClaudeLoginRenewal: Equatable, Sendable {
    /// Nothing to renew, or no Claude Code to ask.
    case unavailable
    case renewed, failed
}

/// Renewing Claude Code's login stays Claude Code's job: Frog never uses its renewal token.
/// When the saved login has run out, Frog runs Claude Code the way its user would, with one
/// minimal request, during which Claude Code renews and saves the login itself. Nothing of the
/// answer is kept.
enum ClaudeCodeCLI {
    static let renewalArguments = ["-p", "OK", "--model", "haiku", "--tools", "", "--no-session-persistence",
                                   "--strict-mcp-config", "--safe-mode", "--system-prompt", "Reply with OK.",
                                   "--output-format", "json"]

    /// Where its installers put it, then the search path Frog was started with, then where tool
    /// managers put it, which that path lacks when Frog was started from Finder. A relative
    /// entry of the search path names a place in whatever folder Frog runs in and is skipped.
    /// The list of installed tools has to agree on whether Claude Code is there.
    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let installed = [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let searched = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/claude" }
        let managed = [".bun/bin/claude", ".npm-global/bin/claude", ".volta/bin/claude", ".asdf/shims/claude"]
            .map { home.appendingPathComponent($0).path }
        return (installed + searched + managed).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Only what Claude Code needs to find its own login and reach the network. Another
    /// session's host credentials, API keys or model overrides must not reach it.
    static func environment(_ inherited: [String: String], directory: URL) -> [String: String] {
        let kept: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS",
                                 "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]
        var result = inherited.filter { kept.contains($0.key) }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let profile = profile(directory) { result["CLAUDE_CONFIG_DIR"] = profile }
        return result
    }

    /// Blocking; call it off the main thread. Claude Code is stopped at `deadline` seconds.
    static func renewLogin(directory: URL, deadline: TimeInterval) -> ClaudeLoginRenewal {
        guard claudeCodeLoginLapsed(directory: directory), let executable = executable() else { return .unavailable }
        let result = usageProcess(executable, arguments: renewalArguments,
                                  environment: environment(ProcessInfo.processInfo.environment, directory: directory),
                                  directory: FileManager.default.temporaryDirectory, timeout: deadline)
        // A request answered some other way, such as with an API key, renewed nothing.
        return result?.status == 0 && !claudeCodeLoginLapsed(directory: directory) ? .renewed : .failed
    }

    /// The shell command for Claude Code's own interactive sign-in to this profile.
    static func signInCommand(executable: URL, directory: URL) -> String {
        let command = (profile(directory).map { ["/usr/bin/env", "CLAUDE_CONFIG_DIR=\($0)"] } ?? []) + [executable.path, "auth", "login"]
        return "exec " + command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// Nil for the personal profile, which Claude Code finds without being told.
    private static func profile(_ directory: URL) -> String? {
        directory.standardizedFileURL == ClaudePaths.defaultDirectory.standardizedFileURL ? nil : directory.standardizedFileURL.path
    }
}
