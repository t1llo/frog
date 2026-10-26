# Word counter

An example Frog plugin. It counts the words, characters, sentences and paragraphs of the text you type or paste, and estimates how long it takes to read at 230 words a minute. The text stays in the box until you clear it.

The command bar row **Count words on the clipboard** opens the page with the clipboard's text already counted.

## Permissions

- `clipboard-read`: for **Use clipboard** and the command bar row. Frog never gives a plugin text that a password manager marked as concealed.

Counting happens in the page; nothing leaves your Mac.

## Files

- `plugin.json`: the manifest, with the permission and the command.
- `index.html`: the page, styled with Frog's `/_frog/frog.css`.
- `app.js`: counting with `Intl.Segmenter`, `frog.clipboard.readText()`, and `frog.storage` for the last text.

Install it from this folder with `frog plugins install plugins/word-counter`, then approve it in Frog → Plugins. See [docs/plugins.md](../../docs/plugins.md) for the plugin contract.
