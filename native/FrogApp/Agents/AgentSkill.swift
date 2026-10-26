import Foundation

/// The Agent Skills file Frog installs, so Claude Code, Codex and other agents know when and how
/// to use the `frog` command. It names the command groups but leaves the commands to `frog help`,
/// so an older install keeps working when the app gains commands.
enum AgentSkill {
    /// The skill's name, which is also the name of its folder.
    static let name = "frog"
    /// Raise it whenever `text` changes, so Settings offers Update to installs of an older one.
    static let version = 1
    /// The frontmatter key that marks a skill Frog wrote, with its version.
    static let marker = "frog-skill-version"

    static let text = """
    ---
    name: frog
    description: Control the user's Mac and the Frog menu-bar app with the `frog` command. Use when the user asks to arrange, move, resize or focus windows or apply a window layout; open or list apps; list or run their Frog scripts; read, search or add notes or snippets; use the clipboard history or the shelf; run a writing rule on text; keep the Mac awake; check CPU, GPU or memory load or their Claude and Codex usage limits; show a notification; or open, check or configure Frog and its features.
    metadata:
      \(marker): "\(version)"
    ---

    # Frog

    The `frog` command talks to Frog, the menu-bar app running on this Mac. The running app is the reference for what it can do:

    - `frog help` lists every command by group: Frog, Windows, Scripts, Snippets, Notes, Shelf, Clipboard, Writing rules, Stay awake, System monitor, Mr. Usage.
    - `frog help <command>` explains one command, with its options and examples.
    - A group marked "(off)" belongs to a Frog feature that is switched off. Ask the user before turning it on with `frog features enable <feature>`.

    ## Running commands

    - Add `--json` whenever you read the answer; the plain output is for people.
    - Pass long or multi-line text on standard input with `--stdin`: `printf '%s' "$text" | frog <command> --stdin`.
    - Relative paths are read from the folder `frog` runs in.
    - When `frog` is not on PATH, run `/Applications/Frog.app/Contents/Helpers/frog`.
    - When Frog is not running, `frog` starts it in the background and waits for it.

    ## Exit codes

    - `0`: done.
    - `1`: the command failed; standard error says why.
    - `2`: wrong command or arguments. Read `frog help <command>` and try again.
    - `69`: Frog cannot be reached, usually because agent access is off. Tell the user to turn it on in Frog → Settings → Agents; nothing you run can turn it on.

    ## Scripts

    Frog scripts are the user's own shell commands and run with their permissions. Run the script the user asked for, by name; `frog scripts` shows how to list them when it is unclear which one they mean.

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
