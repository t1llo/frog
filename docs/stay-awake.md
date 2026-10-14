# Stay awake

Frog's menu-bar popup has a **Stay awake** switch. It starts off and never automatically enables on launch. It uses the system-wide `pmset disablesleep` setting, including lid-closed sleep; ordinary idle-sleep assertions do not provide the same behavior.

Choose 30 minutes, one hour, four hours (the default), or until Frog quits before enabling it. Frog restores sleep when its session expires, when it quits normally, or when an unplugged battery drops below 20%. Battery and timer checks run approximately once a minute. The menu-bar coffee symbol indicates that the system setting is on.

## One-time permission setup

Choose **Set up access…** in Frog's popup or **Settings → Stay awake**. The bundled [Terminal guide](../native/FrogApp/Resources/StayAwakeSetup.command) first explains what it will change, then walks through:

1. Reviewing the exact two power commands.
2. Adding a rule for your current Mac account using `sudo visudo -f /etc/sudoers.d/frog-awake`.
3. Validating the configuration and both effective passwordless command permissions without changing the sleep setting.

The guide summarizes the result and its dedicated Terminal window closes automatically on success. Errors stay visible for review. The effective permissions decide, not the wording of the rule: a rule that `sudo` accepts in another form, for example with the two commands on separate lines, passes, and so does a Mac on which another rule already allows both commands. The guide then says that its own line is not in the file. Frog immediately checks the actual permissions again, displays **Ready to use** in Settings, and hides **Set up access…** from the popup when both commands are available. **Check access** refreshes that status at any time. Once access is ready, opening the popup or returning to Frog does not check it again; Frog checks it when the Stay awake page opens and before it switches Stay awake on. Cached administrator authentication does not count as configured access.

Frog waits for the guide for as long as it takes. While it is open, Stay awake cannot be switched on; a session that is already on can still be switched off. If the guide's process ends without a result, for example because it was killed, Frog reports that setup did not finish. If both commands are allowed by then, because the rule was saved first, Frog says that too and Stay awake can be used. If the guide never reports back at all, choose **Cancel** in **Settings → Stay awake** to stop waiting, then close the guide's Terminal window if one is still open.

Enter your administrator password directly into Terminal's `sudo` prompt. Frog never receives or stores it. The rule grants only these exact commands:

```text
YOUR_SHORT_USERNAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Frog then executes those commands using `sudo -n`, without a shell or password prompt. Starting a session without permission leaves the switch off and shows the setup action.

## Reset access

Choose **Settings → Stay awake → Reset access…**. Frog first restores sleep; if that fails, it keeps the current permission and reports the error. A running session therefore ends even if you then cancel in Terminal, and Settings says that sleep was restored. The Terminal guide explains the reset and asks you to confirm before emptying the dedicated file with:

```sh
sudo /usr/bin/tee /etc/sudoers.d/frog-awake < /dev/null
```

It validates sudoers afterward and leaves the empty file in place. The main sudoers file is not edited. Settings returns to **Setup needed** unless another system policy independently allows both commands; availability always reflects the effective policy. Run setup again to restore access.

## Session behavior

- Lock the Mac separately before closing its lid. This switch controls sleep, not screen locking.
- Frog reads back the real setting after every change. Failed reads show an unverified state and retain the session marker for cleanup. If another app already enabled it, the popup shows **On outside Frog**; Frog will not claim that session or disable it when quitting. You can explicitly switch it off.
- A small machine-local session marker in Application Support lets the next launch restore sleep if an owned session was interrupted. A crash or forced termination cannot run normal quit cleanup; until Frog restarts, the system setting can remain enabled. It can also be restored manually with `sudo /usr/bin/pmset -a disablesleep 0`. The marker names the Frog process that started the session. A second copy of Frog that starts while that process still runs, for example a development build beside the installed app, leaves the session alone and shows it as **On outside Frog**.
- If restoring sleep fails during normal quit, Frog reports the error and remains open so you can restore access and retry.

Lid behavior must be checked on the target Mac after setup. The automated tests use isolated power-service fixtures and do not modify sudoers, battery settings, or system sleep.
