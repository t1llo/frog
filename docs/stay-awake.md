# Stay awake

Stay awake keeps the Mac, and by default its screen, awake. Switch it on in Frog's popup, on the **Stay awake** page, from the command bar, or with `frog awake on`. It starts off and never switches itself on at launch.

## A session needs no setup

A session holds the same power assertions as `caffeinate -d -i`: the Mac does not go to idle sleep, and with **Keep the screen on** (the default) the display stays on, so the screen does not dim or lock while you are away. `pmset -g assertions` lists them under Frog. Nothing on the Mac is changed, so there is no permission to set up, and the assertions end with the session, when Frog quits, and when Frog stops in any other way.

A session lasts **until turned off** (the default), **1 hour**, **3 hours**, or **until a time** you pick. The popup offers the same choices while Stay awake is off and shows when the session ends while it is on. Changing the duration during a session counts it again from now. A timed session ends on its own, also when the Mac slept in between.

## With the lid closed

macOS ignores the assertions once the lid is closed. **Stay awake with the lid closed** is a separate switch on the page: while it is on, a session also turns on the system-wide `pmset disablesleep` setting and turns it off when the session ends. That setting needs a one-time permission, set up in Terminal; without it, a session still keeps the Mac awake with the lid open and the page says that lid-closed mode needs setup. Lock the Mac yourself before closing its lid.

### One-time setup

Choose **Set up…** under **Lid closed**. The bundled [Terminal guide](../native/FrogApp/Resources/StayAwakeSetup.command) first explains what it will change, then walks through:

1. Reviewing the exact two power commands.
2. Adding a rule for your current Mac account using `sudo visudo -f /etc/sudoers.d/frog-awake`.
3. Validating the configuration and both effective passwordless command permissions without changing the sleep setting.

Enter your administrator password directly into Terminal's `sudo` prompt. Frog never receives or stores it. The rule grants only these exact commands:

```text
YOUR_SHORT_USERNAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Frog runs them with `sudo -n`, without a shell or password prompt. The effective permissions decide, not the wording of the rule: a rule that `sudo` accepts in another form passes, and so does a Mac on which another rule already allows both commands. Frog checks the permissions again when the guide ends and shows **Ready**; **Check** reads them again at any time. While the guide is open, choose **Cancel** to stop waiting for it. Cached administrator authentication does not count as configured access.

### Reset

Choose **Reset…** next to **Ready**. Frog first restores sleep; if that fails, it keeps the permission and reports the error. The guide asks you to confirm before emptying the dedicated file with:

```sh
sudo /usr/bin/tee /etc/sudoers.d/frog-awake < /dev/null
```

It validates sudoers afterwards and leaves the empty file in place. The main sudoers file is not edited.

### How the setting is handled

- Frog reads back the real setting after every change, and checks the battery about once a minute while it owns the setting: below 20% on battery it restores sleep and says so. Nothing is read while lid-closed mode is off and no session of Frog's has the setting on.
- A small machine-local session marker in Application Support lets the next launch restore sleep if Frog was interrupted while the setting was on. Until Frog starts again, it can be restored by hand with `sudo /usr/bin/pmset -a disablesleep 0`. A second copy of Frog that starts while the first one runs leaves its setting alone.
- If restoring sleep fails at quit, Frog reports the error and stays open so you can retry.

## Settings

`[stay-awake]` in `config.toml`:

| Key | Default | Meaning |
| --- | --- | --- |
| `duration` | `until-off` | `until-off`, `1h`, `3h` or `until-time` |
| `until` | `18:00` | When `until-time` ends, as `HH:MM` |
| `keep-screen-on` | `true` | Keep the display on too |
| `lid-closed` | `false` | Also stay awake with the lid closed; needs the setup above |
| `menu-bar-item` | `false` | A cup in the menu bar while a session runs |
| `menu-bar-style` | `ring` | `icon`, `ring` (drains as a timed session runs out) or `time` |

The table is written once from the previous settings the first time this version starts.

## Actions

| Action | What it does |
| --- | --- |
| `stay-awake.toggle` | Switches a session on with the page's duration, or off |
| `stay-awake.on [--for 90\|1h\|3h\|until 17:30]` | Starts a session; `--for` takes minutes, hours or a time and leaves the page's duration alone |
| `stay-awake.off` | Ends the session |
| `stay-awake.status` | Whether a session runs, until when, and whether lid-closed mode is active |

`frog awake on|off|status` are short names for the same actions. The automated tests use fake power services and never change sudoers, the sleep setting or real assertions.
