import Darwin
import Foundation

/// An AI coding agent Frog can give its skill to.
enum CodingAgent: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, gemini, pi, openCode
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .pi: "pi"
        case .openCode: "OpenCode"
        }
    }

    /// Files or folders in the home folder that the agent creates once it has run. Not `~/.claude`
    /// alone for Claude Code: installing its skill creates that folder.
    var homeMarkers: [String] {
        switch self {
        case .claudeCode: [".claude.json", ".claude/projects"]
        case .codex: [".codex"]
        case .gemini: [".gemini"]
        case .pi: [".pi"]
        case .openCode: [".config/opencode", ".local/share/opencode", ".opencode"]
        }
    }

    var command: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .pi: "pi"
        case .openCode: "opencode"
        }
    }
}

/// Puts the `frog` command and Frog's skill where the user's shell and AI agents look for them,
/// and takes away only what it put there. It works on the home folder and app bundle it is given,
/// so tests use temporary folders.
struct AgentInstaller {
    /// A folder of skills that one or more agents read.
    struct SkillFolder: Identifiable, Equatable, Sendable {
        let id: String
        /// The folder, relative to the home folder.
        let path: String
        let agents: [CodingAgent]
        var title: String { agents.map(\.title).joined(separator: ", ") }
    }

    /// Claude Code reads only its own folder. Codex, Gemini CLI, pi and OpenCode all read the
    /// shared Agent Skills folder, so one copy there serves them all. OpenCode also reads Claude
    /// Code's folder; both copies are the same skill.
    static let skillFolders = [
        SkillFolder(id: "claude", path: ".claude/skills", agents: [.claudeCode]),
        SkillFolder(id: "agents", path: ".agents/skills", agents: [.codex, .gemini, .pi, .openCode])
    ]

    enum ToolState: Equatable {
        /// This copy of Frog cannot offer the tool; the text says why.
        case unavailable(String)
        case notInstalled
        case installed
        /// The link leads to the tool in another copy of Frog, at this path.
        case otherCopy(String)
        /// Something Frog did not make is in the way. Frog leaves it alone.
        case blocked
    }

    enum SkillState: Equatable {
        case notInstalled
        case installed
        /// Frog wrote it, but an older version.
        case outdated
        /// A `frog` skill Frog did not write. Frog leaves it alone.
        case blocked
    }

    enum Failure: LocalizedError, Equatable {
        case notFrogs(String)
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .notFrogs(let path): "\(path) was not made by Frog, so Frog leaves it alone. Move it away first."
            case .unavailable(let reason): reason
            }
        }
    }

    let home: URL
    /// The Frog.app this copy of Frog runs from.
    let app: URL
    /// Where to look for an agent's command besides its home folders.
    var commandFolders: [URL]
    var fileManager: FileManager = .default

    init(home: URL, app: URL, commandFolders: [URL]? = nil) {
        self.home = home
        self.app = app
        self.commandFolders = commandFolders ?? [".local/bin", ".bun/bin", ".npm-global/bin", ".opencode/bin", ".claude/local"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The installer for the signed-in user and the running app.
    static var live: AgentInstaller {
        AgentInstaller(home: FileManager.default.homeDirectoryForCurrentUser, app: Bundle.main.bundleURL)
    }

    // MARK: The frog command

    var linkURL: URL { home.appendingPathComponent(".local/bin/frog") }
    var helperURL: URL { app.appendingPathComponent("Contents/Helpers/frog") }
    /// How the link's path reads in Settings, such as `~/.local/bin/frog`.
    var linkDisplayPath: String { "~/.local/bin/frog" }

    func toolState() -> ToolState {
        if app.path.contains("/AppTranslocation/") { return .unavailable("Move Frog to Applications first.") }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else { return .unavailable("The frog command ships with the Frog app.") }
        guard let destination = linkDestination() else {
            return exists(linkURL) ? .blocked : .notInstalled
        }
        if Self.samePath(destination, helperURL) { return .installed }
        return Self.isFrogHelper(destination) ? .otherCopy(destination.path) : .blocked
    }

    /// Links `~/.local/bin/frog` to this copy's tool, replacing a link to another copy.
    func installTool() throws {
        switch toolState() {
        case .installed: return
        case .unavailable(let reason): throw Failure.unavailable(reason)
        case .blocked: throw Failure.notFrogs(linkDisplayPath)
        case .notInstalled: try createLink()
        case .otherCopy: try replaceLink()
        }
    }

    /// Makes the link where there was nothing. Something that appeared there since makes it fail
    /// with EEXIST instead of being replaced.
    func createLink() throws {
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard symlink(helperURL.path, linkURL.path) == 0 else {
            let code = errno
            if code == EEXIST { throw Failure.notFrogs(linkDisplayPath) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// A new link takes the place of the link to another copy in one step, so `frog` is never missing.
    private func replaceLink() throws {
        let temporary = linkURL.deletingLastPathComponent().appendingPathComponent(".frog-\(UUID().uuidString)")
        guard symlink(helperURL.path, temporary.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary.path, linkURL.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw error
        }
    }

    /// Removes the link when it leads to a copy of Frog's tool.
    func removeTool() throws {
        switch toolState() {
        case .installed, .otherCopy: try fileManager.removeItem(at: linkURL)
        case .notInstalled, .unavailable: return
        case .blocked: throw Failure.notFrogs(linkDisplayPath)
        }
    }

    /// Whether a shell startup file seems to put `~/.local/bin` on PATH. The files are read as
    /// text, never run, so this can be wrong either way; Settings only uses it to show a hint.
    func shellFindsLocalBin() -> Bool {
        let files = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile",
                     ".config/fish/config.fish"]
        return files.contains { name in
            guard let text = try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8) else { return false }
            return text.contains(".local/bin")
        }
    }

    /// The line that puts `~/.local/bin` on PATH, and the file it goes in, for the user's login shell.
    static func pathLine(shell: String) -> (file: String, line: String) {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "bash": ("~/.bash_profile", #"export PATH="$HOME/.local/bin:$PATH""#)
        case "fish": ("~/.config/fish/config.fish", "fish_add_path ~/.local/bin")
        default: ("~/.zshrc", #"export PATH="$HOME/.local/bin:$PATH""#)
        }
    }

    /// The signed-in user's login shell.
    static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        return String(cString: shell)
    }

    private func linkDestination() -> URL? {
        guard let text = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else { return nil }
        return URL(fileURLWithPath: text, relativeTo: linkURL.deletingLastPathComponent()).standardizedFileURL
    }

    /// `…/Something.app/Contents/Helpers/frog`, whether that app is still there or not.
    static func isFrogHelper(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 5 else { return false }
        return Array(parts.suffix(3)) == ["Contents", "Helpers", "frog"] && parts[parts.count - 4].hasSuffix(".app")
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path == second.standardizedFileURL.path
            || first.resolvingSymlinksInPath().path == second.resolvingSymlinksInPath().path
    }

    /// Whether anything is at `url`, a broken link included.
    private func exists(_ url: URL) -> Bool { kind(url) != nil }

    /// What is at `url` itself, without following a link: `S_IFDIR`, `S_IFREG`, `S_IFLNK` and so on.
    private func kind(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    // MARK: Skills

    func skillFolderURL(_ folder: SkillFolder) -> URL {
        home.appendingPathComponent(folder.path, isDirectory: true).appendingPathComponent(AgentSkill.name, isDirectory: true)
    }
    func skillFileURL(_ folder: SkillFolder) -> URL { skillFolderURL(folder).appendingPathComponent("SKILL.md") }
    /// How the skill's folder reads in Settings, such as `~/.claude/skills/frog`.
    func displayPath(_ folder: SkillFolder) -> String { "~/\(folder.path)/\(AgentSkill.name)" }

    /// A link in place of the `frog` folder or its `SKILL.md` counts as someone else's: Frog never
    /// writes through it or removes it.
    func skillState(_ folder: SkillFolder) -> SkillState {
        guard let folderKind = kind(skillFolderURL(folder)) else { return .notInstalled }
        guard folderKind == S_IFDIR else { return .blocked }
        let file = skillFileURL(folder)
        guard let fileKind = kind(file) else { return .notInstalled }
        guard fileKind == S_IFREG, let text = try? String(contentsOf: file, encoding: .utf8), let version = AgentSkill.installedVersion(of: text) else { return .blocked }
        return version < AgentSkill.version ? .outdated : .installed
    }

    /// Writes the skill, or brings Frog's older copy up to date.
    func installSkill(_ folder: SkillFolder) throws {
        if skillState(folder) == .blocked { throw Failure.notFrogs(displayPath(folder)) }
        try fileManager.createDirectory(at: skillFolderURL(folder), withIntermediateDirectories: true)
        try Data(AgentSkill.text.utf8).write(to: skillFileURL(folder), options: .atomic)
    }

    /// Removes the skill file Frog wrote, and its folder once nothing else is left in it.
    func removeSkill(_ folder: SkillFolder) throws {
        switch skillState(folder) {
        case .notInstalled: return
        case .blocked: throw Failure.notFrogs(displayPath(folder))
        case .installed, .outdated: break
        }
        try fileManager.removeItem(at: skillFileURL(folder))
        // Removes the folder only when it is empty; anything else left in it keeps it.
        rmdir(skillFolderURL(folder).path)
    }

    // MARK: Agents on this Mac

    /// The agents that have run on this Mac or whose command is installed.
    func detectedAgents() -> Set<CodingAgent> {
        Set(CodingAgent.allCases.filter { agent in
            agent.homeMarkers.contains { exists(home.appendingPathComponent($0)) }
                || commandFolders.contains { fileManager.isExecutableFile(atPath: $0.appendingPathComponent(agent.command).path) }
        })
    }
}
