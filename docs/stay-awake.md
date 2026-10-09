# Stay awake

Frog's menu-bar popup has a **Stay awake** switch. It starts off and never automatically enables on launch. It uses the system-wide `pmset disablesleep` setting, including lid-closed sleep; ordinary idle-sleep assertions do not provide the same behavior.

Choose 30 minutes, one hour, four hours (the default), or until Frog quits before enabling it. Frog restores sleep when its session expires, when it quits normally, or when an unplugged battery drops below 20%. Battery and timer checks run approximately once a minute. The menu-bar coffee symbol indicates that the system setting is on.

## One-time permission setup

Choose **Set up access…** in Frog's popup. The bundled [Terminal guide](../native/FrogApp/Resources/StayAwakeSetup.command) walks through:

1. Reviewing the exact two power commands.
2. Adding a rule for your current Mac account using `sudo visudo -f /etc/sudoers.d/frog-awake`.
3. Validating the configuration and command permissions without changing the sleep setting.

Enter your administrator password directly into Terminal's `sudo` prompt. Frog never receives or stores it. The rule grants only these exact commands:

```text
YOUR_SHORT_USERNAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Frog then executes those commands using `sudo -n`, without a shell or password prompt. Starting a session without permission leaves the switch off and shows the setup action. To remove access, edit that same file with `visudo` and remove your rule.

## Session behavior

- Lock the Mac separately before closing its lid. This switch controls sleep, not screen locking.
- Frog reads back the real setting after every change. Failed reads show an unverified state and retain the session marker for cleanup. If another app already enabled it, the popup shows **Enabled outside Frog**; Frog will not claim that session or disable it when quitting. You can explicitly switch it off.
- A small machine-local session marker in Application Support lets the next launch restore sleep if an owned session was interrupted. A crash or forced termination cannot run normal quit cleanup; until Frog restarts, the system setting can remain enabled. It can also be restored manually with `sudo /usr/bin/pmset -a disablesleep 0`.
- If restoring sleep fails during normal quit, Frog reports the error and remains open so you can restore access and retry.

Lid behavior must be checked on the target Mac after setup. The automated tests use isolated power-service fixtures and do not modify sudoers, battery settings, or system sleep.
