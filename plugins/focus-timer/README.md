# Focus timer

An example Frog plugin. A Pomodoro-style timer: choose 25 or 50 minutes or your own length, start, pause or reset, and Frog notifies you when the session ends. It counts the sessions you finish each day.

Two command bar rows work without opening the page:

- **Start a focus session** starts the timer with the length you chose last and confirms it with a notification.
- **Stop the focus timer** stops it.

The timer keeps the time a session ends at rather than counting ticks, so it stays right while Frog runs the page in the background. The session is saved, so a page Frog reloads picks it up where it was.

## Permissions

- `notifications`: to tell you when a session ends, and to confirm the command bar rows, which run without showing the page.

## Files

- `plugin.json`: the manifest, with the permission and the two commands with `"show": false`.
- `index.html`: the page, styled with Frog's `/_frog/frog.css`.
- `app.js`: the timer, `frog.notify`, `frog.storage` for the session and today's count, and `frog.close()` once a command's work is done.

Install it from this folder with `frog plugins install plugins/focus-timer`, then approve it in Frog → Plugins. See [docs/plugins.md](../../docs/plugins.md) for the plugin contract.
