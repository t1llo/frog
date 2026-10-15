import AppKit
import FrogUsage

/// Starts Claude Code's own sign-in in Terminal. Frog only opens it; the login stays Claude Code's.
enum ClaudeSignIn {
    @MainActor static func start(_ usage: UsageDashboardModel) {
        Task { @MainActor in
            // A login that is current, or that Claude Code could renew, needs no sign-in at all.
            guard await usage.beginClaudeSignIn() else { return }
            open(command: usage.claudeSignInCommand)
        }
    }

    /// "Set up live readings for B…", after the view has explained it: signs Claude Code in to a
    /// new profile for an account known only from the Claude app. Without Claude Code, its page.
    @MainActor static func startLiveSetup(_ usage: UsageDashboardModel, account: String) {
        open(command: usage.liveSetupCommand(for: account))
    }

    /// What the confirmation before live readings says, for the account labelled `label`.
    static func liveSetupTitle(_ label: String) -> String { "Set up live readings for \(label)?" }
    static func liveSetupMessage(_ label: String) -> String {
        "Opens Terminal to sign in to Claude Code as \(label). Make sure your browser is signed in to \(label)’s Claude account. "
            + "Frog then checks \(label)’s limits with Anthropic every minute; when that login runs out, Claude Code renews it "
            + "with one tiny request on \(label)’s plan."
    }

    @MainActor static func open(command: String?) {
        guard let command, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal"),
              let launcher = try? launcher(command: command) else {
            // No Claude Code on this Mac yet; its page says how to get it.
            if let page = URL(string: "https://claude.com/claude-code") { NSWorkspace.shared.open(page) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.addsToRecentItems = false
        NSWorkspace.shared.open([launcher], withApplicationAt: terminal, configuration: configuration)
    }

    /// A session-only Terminal profile, as for the stay-awake guide: it runs the one command
    /// and closes its window when that succeeds, leaving the user's own profiles alone.
    static func launcher(command: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory.appendingPathComponent("Frog-claude-sign-in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile: [String: Any] = ["name": "Sign in to Claude Code", "type": "Window Settings",
            "CommandString": command, "RunCommandAsShell": false, "shellExitAction": 1,
            "rowCount": 24, "columnCount": 100]
        let file = folder.appendingPathComponent("Sign in to Claude Code.terminal")
        try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: file, options: .atomic)
        return file
    }
}
