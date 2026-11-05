# Focus timer

An example Frog plugin that is a whole feature: a Pomodoro-style timer in the menu bar. Start it with a shortcut from any app, see the time left beside its icon, and when a session ends take a break or focus again straight from the notification. It counts the sessions you finish each day.

- **Menu bar.** The timer's icon shows the time left while a session runs, a cup during a break and a pause sign while paused. Click it for a popup with the time, Start or Pause and Reset.
- **Shortcut.** ⌃⌥⇧F starts or pauses the timer in any app.
- **Notifications.** A finished session offers **Take a 5-minute break** and **Focus again**; a finished break offers **Start focusing**.
- **Settings.** The focus and break lengths, and whether the menu bar shows the time, in Frog → Community plugins → Focus timer → Settings. The shortcut's keys change there too.
- **Command bar and agents.** *Start or pause the focus timer*, *Start a focus session* and *Stop the focus timer*, also as `frog run community.xyz.beffa.frog.focus-timer.toggle`.

The page runs in the background from Frog's start, so the menu bar stays current with the page closed, and a session that ended while the Mac slept is counted when it wakes. The timer keeps the time a session ends at rather than counting ticks, and is saved, so it stays right whatever Frog does.

## Permissions

- `notifications`: to tell you when a session or a break ends, with buttons that start the next one.
- `menubar`: for its menu-bar item and popup.
- `hotkeys`: for the shortcut.
- `background`: to keep running with its page closed.

## Files

- `plugin.json`: the manifest, with the permissions, the menu-bar item and its popup, the settings and the three actions, one with a shortcut.
- `timer.js`: the timer's state, shared by the page and the popup through `frog.storage`, and the notification scheduled with `at` and `actions`.
- `index.html` and `app.js`: the page, which ends sessions, counts them, updates the menu bar with `frog.menubar.set`, answers the actions with `frog.action` and the notification's buttons, and hears `wake`, `storage` and `settings`.
- `popup.html` and `popup.js`: the popup, which hears the page's changes through the `storage` event.

All pages use Frog's `/_frog/frog.css`. Install it from this folder with `frog plugin install plugins/focus-timer`, then approve it in Frog → Community plugins. See [docs/plugins.md](../../docs/plugins.md) for the plugin contract.
