# Design rules

Frog looks quiet and consistent: Raycast's dense, keyboard-first popups and Linear's and Notion's calm pages. Every value comes from [DesignSystem.swift](../native/FrogApp/Views/DesignSystem.swift), [CompactControls.swift](../native/FrogApp/Views/CompactControls.swift) and [Motion.swift](../native/FrogApp/Views/Motion.swift). A view never invents its own button, radius, height, text size or animation. `StyleTokenScanTests` checks the rules that code can check.

## No lines

- No `Divider()`, no `NSMenuItem.separator()`, and no thin `Rectangle` between rows, above footers or beside sidebars.
- Separate content with space, a heading, or a surface: a card, or an inset fill.
- Exceptions: the user's own content (Markdown rules and quote bars), chart axes and gridlines, progress tracks, and the drop indicator while dragging.

## Radii

| Token | Value | Use |
| --- | --- | --- |
| `smallRadius` | 4 | Key caps, badges, colour swatches, the thumb of a segmented control |
| `controlRadius` | 6 | Buttons, fields, dropdowns, segmented controls, rows and their highlight, menu rows, symbol tiles, blocks inside a card or popup |
| `cardRadius` | 10 | Cards, settings groups, lists, previews, banners |
| `panelRadius` | 12 | Popups and floating panels (`frogPanel()`) |
| `pillRadius` | 18 | 36-point status pills (`frogPanel(pill: true)`) |

Circles and capsules are fine for dots, avatars, toggles and progress bars. No other numbers.

## Sizes and spacing

- Controls are `controlHeight` (28) tall; in popups, panel headers and dense rows `compactHeight` (24).
- Pages: `PageScroll` (padding 20, sections 20 apart) with a `PageHeader`.
- A section is `SettingsSection`: a heading, then one card with padding 14 and rows 10 apart.
- Inside a card, a sub-group starts with a `SectionCaption`.
- List rows are 1–2 apart, highlighted with `frogRowHighlight(hovering:selected:)`, or `frogHoverRow(selected:)` when the row tracks its own hover.

## Type

Use `FrogType` for text. A literal size is only for an SF Symbol's size.

| Token | Use |
| --- | --- |
| `title` 19 semibold | Page titles |
| `section` 13 semibold | Section headings, popup titles, empty-state titles |
| `lead` 13 | Page subtitles, empty-state messages |
| `body` 12 | Row titles, list items, field text, dropdown values, menu rows |
| `bodyMedium` 12 medium | Buttons, titles of cards and settings |
| `small` 11 | Row descriptions, secondary lines, compact controls |
| `label` 11 medium | `SectionCaption`, compact buttons, key caps |
| `caption` 10 | Timestamps, paths, counts, badges, footnotes |
| `mono` 11 | Code, file contents and identifiers only. Not shortcuts |

## Buttons

`FrogButtonStyle` is the only button. The main window sets the secondary kind for every button in it.

- `.buttonStyle(.frog(.primary))`: the one main action of a page, sheet or card.
- Secondary (default): every other action.
- `.frog(.ghost)`: text actions beside content, such as Reset, Skip or Set up myself.
- `.frog(.destructive)`: removes or deletes something.
- `compact: true` in popups, panel headers and dense rows.
- `IconAction` for icon-only actions: a plain icon that highlights on hover. `bordered: true` only in a popup header, beside compact segments.
- `IconMenu` for a menu behind an icon ("…" by default): drawn exactly like the `IconAction` beside it. Never `.menuStyle(.borderlessButton)`, which drops Frog's surface and hover.
- `.buttonStyle(.plain)` only for rows, tiles and cards that draw their own hover with `frogRowHighlight`.
- Never `.bordered`, `.borderedProminent`, `.borderless` or `.link`.

## Controls

- Dropdowns: `CompactMenu` (or `CompactDropdownLabel` for a custom popover). Mark the current option with `.compactChoice(selected:)`; it shows a checkmark.
- Choices of two to four, and switching between parts of a page (Providers, Installed tools): `CompactSegments`.
- On/off settings: `Toggle` with the switch style.
- Picking items from a list (files to remove, models to offer, agents to set up): `.toggleStyle(.frogCheckbox)`. Never the system checkbox.
- Numbers from a short list: `CompactMenu` rather than a `Stepper`.
- Text: `LabeledField` or `frogControlSurface()`. No `.roundedBorder`.
- Search: `SearchBox`. Filters that narrow a list (All, Text, Audio): `FilterTag`.
- Shortcuts: `ShortcutBadge` and `KeyCap`, in the sans font.
- Empty lists and pages: `FrogEmptyState`, with the action that fills it in its trailing slot, unless the page header already has that action.

## Surfaces and colour

- Cards: `FrogCard`, or `frogTableSurface()` for lists that draw their own rows. Blocks inside a card use the inset fill with `controlRadius` and no border.
- Popups: `frogPanel()`, rows `MenuActionRow` or `MenuRowStyle`, footer `PanelFooter`.
- `selection` marks what is chosen; `hover` what the pointer is over; `accent` shows state and focus, not decoration.
- `muted` for secondary text; `good`, `warning` and `critical` for status.

## Motion

Frog moves little: a press answers, a hover leaves softly, a choice slides, and occasional things arrive and leave. Everything else is an instant cut.

| Token | Value | Use |
| --- | --- | --- |
| `press` | spring, response 0.2, no bounce | `FrogButtonStyle`: scale 0.97 and the `pressed` fill on the down event |
| `hoverOut` | ease 0.15 s | A hover fill leaving (`frogRowHighlight`, control surfaces, buttons). Hover in is instant |
| `slide` | spring, response 0.28, no bounce | The thumb of `CompactSegments` |
| `reveal` | strong ease-out (0.23, 1, 0.32, 1), 0.2 s | Occasional arrivals: the error banner, a copy confirmation, scrolling to a section |
| `exit` | strong ease-out, 0.15 s | The same leaving, faster than it came |
| `check` | strong ease-out, 0.15 s | `FrogCheckbox`: the mark grows in from 0.8 as the box fills |
| `step` | spring, response 0.35, no bounce | Steps of the setup assistant: in 16 points from the side they lie on |
| `fadeOut` | strong ease-out, 0.2 s | Status pills and status item popups fading out (`NSWindow.fadeOut()`) |
| `resize` | ease-in-out, 0.22 s | The dictation pill growing with its text; it changes shape on screen |
| `confirmation` | 1.5 s | How long `CopyAction` shows its checkmark |

- Never animate the command bar, clipboard history, window switcher or layout picker: opening, closing, typing, arrow keys. Their roots set `.environment(\.frogKeyboardSurface, true)`, which turns off hover fades and press motion inside them.
- Never animate selection moved by arrow keys or Tab, page switches (sidebar and ⌘1–5), or text that streams in.
- No bounce anywhere: nothing in Frog is thrown or flicked. No ease-in: it starts slow where the eye is watching.
- Reduce Motion: no scale and no sliding; segments, setup steps, the error banner and the checkbox mark cross-fade instead.
- Copy actions use `CopyAction`: its symbol turns into a checkmark for `confirmation`.
- An animation names a token from `Motion.swift`: `withAnimation(FrogMotion.reveal)`, never `.easeOut(duration:)`, a bare `withAnimation` or a literal `NSAnimationContext` duration. `StyleTokenScanTests` checks it.
