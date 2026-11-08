# Feature request: Explain the selection

Status: idea, not scheduled. Requested 2026-10-14.

## Summary

Select a word, a sentence or a paragraph in any app and have Frog explain it. A small
panel opens next to the selection, answers with the model you chose in Frog, and the
question and answer can be kept in History or sent to a note (for example in Obsidian).

There are two ways in:

- **Selection bubble (always on, optional):** after you select text, a small button appears
  next to it with *Explain* and the user's writing rules (*Rewrite*, *Translate*, …).
- **Shortcut:** select text and press the Explain shortcut. This opens the panel directly,
  with no bubble.

## Why

Frog's Writing rules already work on a selection, but they *replace* it. Often you only want
to understand something without changing it: a term in a paper, a line of code, a sentence in
a foreign language, an error message. Today that means copying it, switching to a chat app,
pasting and asking. Explain keeps you where you are.

## Behaviour

### Selection bubble

- Off by default. Switched on in Features → Explain, with an app exclusion list.
- Appears once a selection has settled (mouse-up or Shift-arrow selection, about 300 ms with
  no change), near the end of the selection. It is a non-activating panel: it never takes
  focus from the app you're in, and typing or clicking elsewhere dismisses it.
- Shows *Explain* first, then the enabled Writing rules. Choosing a rule runs it exactly like
  its shortcut (replace the selection, copy the result).
- Reads the selection through Accessibility only. It never sends a Copy command to detect a
  selection, and it never touches the clipboard.
- Never appears in password fields or while an app holds secure keyboard entry, in excluded
  apps, or for selections that are empty, only whitespace, or longer than a limit (for example
  4,000 characters).
- Nothing leaves the Mac until you choose an action.

### Explain shortcut

- A configurable global shortcut (no default, so it can't collide with existing shortcuts).
- Uses the same selection capture as Writing rules, including the compatibility Copy with
  clipboard restore for apps without Accessibility text.

### Answer panel

- A small floating panel next to the selection, or next to the pointer when the selection's
  position is unknown, kept on the same display. It does not take focus until you click it.
- Streams the answer as it arrives, in the user's language unless the selection asks
  otherwise.
- Adapts to what was selected:
  - a single word or a short phrase: a definition plus its meaning *in this context*;
  - a sentence or a paragraph: a plain-language explanation;
  - code: what it does;
  - an error message: what it means and the likely fix.
- Sends context: the surrounding sentence or paragraph when Accessibility can read it, and the
  app's name. This lets "bank" be explained correctly in "river bank".
- Actions:
  - **Copy**.
  - **Ask a follow-up:** a single input line that continues the same conversation.
  - **Save to note.**
  - **Pin:** keep the panel open while you work.
  - **Close:** Escape, or clicking elsewhere.
- Shows errors and the processing state the way Frog already does. A provider failure
  explains itself in the panel; it does not fail silently.

### Model

- By default it uses the default provider and model from setup. Settings can choose a
  separate model for Explain, local or cloud, the same way a rule chooses one.
- The instructions are editable, with a sensible default prompt and a short reply length by
  default.
- Local models: same loading, idle and memory-pressure behaviour as Writing.

### History

- When History is enabled, each answered explanation is recorded as its own entry type
  (*Explain*), with:
  - the selection and its context;
  - the answer and any follow-ups;
  - the app, the provider and model, and the time.
- History stays off by default and follows the existing limits (200 entries, 30 days). A
  History filter shows only explanations.

### Save to note (Obsidian and other Markdown apps)

- Settings → Explain → *Notes*: choose a folder (for example an Obsidian vault or a subfolder
  of it), then a mode:
  - **One note per explanation:** a file named after the selection, with front matter
    (`source`, `app`, `model`, `date`, `tags: [frog, explain]`).
  - **Append to one note:** a fixed file, or a daily note with a date pattern such as
    `Daily/YYYY-MM-DD.md`, adding a section per explanation.
- Writes plain Markdown files directly, so it works with Obsidian, Logseq, iA Writer and
  others. No plugin is needed.
- Optionally open the note afterwards (`obsidian://open?path=…` when the folder is inside an
  Obsidian vault, otherwise the default app).
- Also available on an Explain entry in History.

## Privacy

- The bubble only reads the selection locally. Text is sent to a provider only after you
  choose Explain or a rule, and only to the model that is configured.
- Never in secure fields, never in excluded apps. The selection is kept in memory only
  unless History or a note is used.
- Document it in `docs/privacy.md`: what is sent (the selection plus the surrounding
  context and the app name), and when.

## Acceptance criteria

1. With the bubble on, selecting text in Safari, Notes, Mail, Xcode and a Terminal shows the
   bubble within about 0.5 s. It doesn't show in a password field, in an excluded app, or
   while secure input is active.
2. The bubble and the answer panel never change the frontmost app or the focused field.
   Escape and clicking elsewhere close them.
3. The Explain shortcut works without the bubble, including in an app that needs
   compatibility capture, and the clipboard is restored afterwards.
4. The answer streams from the configured model (cloud, Ollama or LM Studio, Frog-local)
   and names that model in the panel.
5. A follow-up keeps the earlier question and answer as context.
6. With History on, an Explain entry appears with the selection, answer, app and model. With
   History off, nothing is stored.
7. Save to note creates or appends valid Markdown in the chosen folder, and opens it in
   Obsidian when asked.
8. Windowless tests cover the decision logic:
   - when the bubble may appear (secure input, exclusions, length, empty);
   - panel placement on multiple displays;
   - prompt assembly with context;
   - note file naming and appending (including a daily note that doesn't exist yet);
   - history recording.

## Open questions

- Should the bubble also offer *Translate* and *Summarize* as built-in actions, or only the
  user's own rules?
- Should the bubble trigger on double-click word selection too, or only on drag and keyboard
  selection? (Double-click is the most common way to select one word, but it's also noisy.)
- A history entry vs. a note: should saving to a note also be possible with History off?
  (Suggested: yes, saving is an explicit action.)
- Should a pinned panel follow the selection, or stay where it is?
- Should the answer support images in the selection (screenshots, PDFs) later, through a
  vision model?

## Fits into Frog

- **Selection capture:** reuse the Writing feature's selection service and its secure-input
  checks.
- **Models:** reuse provider and model resolution, including Frog-local models.
- **Panel:** reuse the non-activating popup style shared by the dictation popup and the
  processing pill.
- **History:** reuse the store, with a new entry kind.
- **Features:** a new card, *Explain*, with the bubble switch, the shortcut, the model,
  instructions, exclusions and notes folder.
