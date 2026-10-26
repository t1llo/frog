# Hacker News

An example Frog plugin. It lists the top 20 stories on [Hacker News](https://news.ycombinator.com) with their site, points, comments and age. Click a story to open it in your browser, or its comment count to open the discussion. It is not affiliated with Hacker News or Y Combinator.

The last list is saved and shown at once when the page opens; a new one is fetched when it is more than five minutes old, or when you click **Refresh**.

## Permissions

- `network`, with the host `hacker-news.firebaseio.com`: to read the public [Hacker News API](https://github.com/HackerNews/API). Frog lets `frog.fetch` reach that host and no other.
- `links`: to open a story or its discussion in your browser.

## Files

- `plugin.json`: the manifest, with the permissions and the one host.
- `index.html`: the page, styled with Frog's `/_frog/frog.css`.
- `app.js`: `frog.fetch` with at most six requests at a time, `frog.openURL`, and `frog.storage` for the last list. Text from the network is set with `textContent` only, and only `http` and `https` links are opened.

Install it from this folder with `frog plugins install plugins/hacker-news`, then approve it in Frog → Plugins. See [docs/plugins.md](../../docs/plugins.md) for the plugin contract.
