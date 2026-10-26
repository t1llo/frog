# Agents

The `frog` command lets you and your AI agents use Frog from a terminal: arrange windows, open apps, run your scripts, read and add notes, use the clipboard history, run writing rules, keep the Mac awake, read the system monitor and Mr. Usage, and switch Frog's features on and off. A skill tells Claude Code, Codex, Gemini CLI, pi and OpenCode when and how to use it.

## Turn it on

Open **Settings → Agents** and switch on **Let AI agents use Frog**. It is off by default; while it is off, `frog` answers that agent access is off and does nothing. The setup assistant's **AI agents** step offers the same: nothing changes until you press its **Turn on and install** button, and **Not now** moves on with agents left off. In the configuration file the setting is `agents.access` (see [configuration](configuration.md#agents)).

## Install the command

**Settings → Agents → Command line tool → Install** links `~/.local/bin/frog` to the tool inside Frog.app (`Frog.app/Contents/Helpers/frog`), so it follows Frog's updates. **Relink** appears when the link leads to another copy of Frog, for example a build you ran before moving Frog to Applications. Frog never replaces or removes a `~/.local/bin/frog` it did not make; Settings shows it in Finder instead.

`~/.local/bin` must be on your shell's `PATH`. When none of your shell's startup files mentions it, Settings shows the line to add, for zsh in `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Frog only reads those files to decide whether to show the hint; it never runs or changes them. Without the link, run the tool by its full path: `/Applications/Frog.app/Contents/Helpers/frog`.

## Install the skill

The skill is a `SKILL.md` in the [Agent Skills](https://agentskills.io) format, named `frog`. Settings installs it in two folders, which together reach every supported agent once:

| Folder | Read by |
| --- | --- |
| `~/.claude/skills/frog` | [Claude Code](https://code.claude.com/docs/en/skills) |
| `~/.agents/skills/frog` | [Codex](https://developers.openai.com/codex/skills), [Gemini CLI](https://geminicli.com/docs/cli/skills/), [pi](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md), [OpenCode](https://opencode.ai/docs/skills/) |

OpenCode also reads `~/.claude/skills`; when both are installed it sees the same skill twice and uses one of them. Settings has one row per folder. To show which agents are on this Mac, Frog looks for their settings (such as `~/.codex` or `~/.claude.json`) and their commands: a row whose agents it did not find says **Not found**, and the setup assistant ticks only the rows it found. You can still install a skill for an agent you set up later.

**Update** appears when a newer Frog brings a newer skill. **Remove** deletes only the `SKILL.md` Frog wrote, then the `frog` folder if nothing else is left in it. A `frog` skill Frog did not write, or a link in place of the `frog` folder or its `SKILL.md`, is never replaced or removed.

## Use it

```sh
frog status                      # version, permissions and features
frog help                        # every command, by group
frog help windows layout         # one command, with its options
frog windows list --json
frog features enable scripts
pbpaste | frog notes add "Title" --stdin
```

`frog help` is the reference: the running app answers it, so it always lists exactly the commands that version of Frog has. The groups are Frog (status, version, features, open), Windows (windows and apps), Scripts, Notes, Clipboard, Writing rules, Stay awake, System monitor and Mr. Usage. A group marked "(off)" belongs to a feature that is switched off; `frog features enable <feature>` turns it on.

- `--json` prints machine-readable output.
- `--stdin` passes standard input as the command's text.
- Relative paths are read from the folder you run `frog` in.
- When Frog is not running, `frog` starts it in the background and waits for it.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Done. |
| 1 | The command failed; standard error says why. |
| 2 | Unknown command or wrong arguments. |
| 69 | Frog cannot be reached: agent access is off, or Frog could not be started. |

## Security

- Agent access is off until you turn it on, and turning it off closes the socket at once.
- `frog` talks to Frog through a Unix socket in Frog's data folder, `~/Library/Application Support/Frog/agent.sock`, that only your user account can open. Nothing listens on the network.
- While access is on, any program running as your user can use every `frog` command, the same as anything that can already run commands in your shell. That includes running your saved scripts, which run your own shell commands with your permissions, reading your notes and clipboard history, and changing Frog's settings. Turn access off when you do not want agents to have this.
- Window commands use the Accessibility permission Frog already has; `frog` asks for nothing new.
- Nothing is sent anywhere. The skill and the link are files in your home folder, and Settings removes them again.
