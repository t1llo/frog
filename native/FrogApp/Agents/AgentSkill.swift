import Foundation

/// The Agent Skills file Frog installs, so Claude Code, Codex and other agents know when and how
/// to use the `frog` command. It names the command groups but leaves the commands to `frog help`,
/// so an older install keeps working when the app gains commands.
enum AgentSkill {
    /// The skill's name, which is also the name of its folder.
    static let name = "frog"
    /// Raise it whenever `text` changes, so Settings offers Update to installs of an older one.
    static let version = 5
    /// The frontmatter key that marks a skill Frog wrote, with its version.
    static let marker = "frog-skill-version"

    static let text = """
    ---
    name: frog
    description: Control the user's Mac and the Frog menu-bar app with the `frog` command. Use when the user asks to arrange, move, resize or focus windows or apply a window layout; open or list apps; list or run their Frog scripts; read, add or append to notes; use the clipboard history; run a writing rule on text; keep the Mac awake; check CPU, GPU or memory load or their Claude and Codex usage limits; open, check or configure Frog and its features; or build, install, test and share a Frog plugin, a feature of their own in Frog, such as when they want Frog to do something it cannot yet.
    metadata:
      \(marker): "\(version)"
    ---

    # Frog

    The `frog` command talks to Frog, the menu-bar app running on this Mac. The running app is the reference for what it can do:

    - `frog help` lists every command by group: Frog, Windows, Scripts, Notes, Clipboard, Writing rules, Stay awake, System monitor, LLM usage, Plugins.
    - `frog help <command>` explains one command, with its options and examples.
    - A group marked "(off)" belongs to a Frog feature that is switched off. Ask the user before turning it on with `frog features enable <feature>`.

    ## Running commands

    - Add `--json` whenever you read the answer; the plain output is for people.
    - Pass long or multi-line text on standard input with `--stdin`: `printf '%s' "$text" | frog <command> --stdin`.
    - Relative paths are read from the folder `frog` runs in.
    - When `frog` is not on PATH, run `/Applications/Frog.app/Contents/Helpers/frog`.
    - When Frog is not running, `frog` starts it in the background and waits for it.
    - Window commands need Frog to have Accessibility; `frog status` shows whether it has. Only the user can allow it, in System Settings.

    ## Exit codes

    - `0`: done.
    - `1`: the command failed; standard error says why.
    - `2`: wrong command or arguments. Read `frog help <command>` and try again.
    - `69`: Frog cannot be reached, usually because agent access is off. Tell the user to turn it on in Frog → Settings → Agents; nothing you run can turn it on.

    ## Scripts

    Frog scripts are the user's own shell commands and run with their permissions. Run the script the user asked for, by name, with `frog run scripts.run --title <name>`; `frog run scripts.list` lists them when it is unclear which one they mean.

    ## Plugins

    A plugin adds a whole feature of the user's own to Frog, as complete as the built-in ones: a page in its sidebar, a menu-bar item with a popup, global shortcuts, actions for the command bar and `frog run`, settings with secrets in the Keychain, and work in the background that hears when the Mac wakes, locks or changes app. With the permissions the user approves it can read and replace the selection, use folders the user picks, run Frog's own actions such as moving windows, and ask the user's AI model. It is built from HTML, CSS and JavaScript that run in a sandbox, styled with Frog's own tokens and components. When the user asks for one, even in one sentence, or for something Frog cannot do yet:

    - Run `frog plugin guide` first and follow it; it is the reference for the Frog that is running.
    - Plan the whole feature: its page, actions, and which of menu bar, shortcut, background and settings it needs. `frog actions` lists Frog's own actions it can run.
    - Start it with `frog plugin new <folder> --with menubar,hotkey,background,settings` (only the parts it needs), check it with `frog plugin validate` and fix every hint, install it with `frog plugin install`, and look at it with `frog plugin snapshot` (and `--popup`) and `frog plugin logs` until it does what the user asked.
    - Ask for the fewest permissions. Never put keys or tokens in its files: declare a `secret` setting the user fills in.
    - `frog plugin publish` prints the directory entry to submit when the user wants to share it.
    - The user approves a plugin's first install, and any update that asks for more access, in Frog's window. You cannot approve it; tell them it is waiting.
    - Remove a plugin only when the user asks.

    """

    /// The version in a skill file Frog wrote, or nil for a file Frog did not write.
    static func installedVersion(of text: String) -> Int? {
        guard text.hasPrefix("---") else { return nil }
        let frontmatter = text.dropFirst(3).components(separatedBy: "\n---").first ?? ""
        for line in frontmatter.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(marker + ":") else { continue }
            let value = trimmed.dropFirst(marker.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return Int(value)
        }
        return nil
    }
}
