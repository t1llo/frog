# Design rules

Frog looks quiet and consistent: Raycast's dense, keyboard-first popups and Linear's and Notion's calm pages. Every value comes from [DesignSystem.swift](../native/FrogApp/Views/DesignSystem.swift), [CompactControls.swift](../native/FrogApp/Views/CompactControls.swift), [Motion.swift](../native/FrogApp/Views/Motion.swift) and the v2 components in [Views/Design](../native/FrogApp/Views/Design). A view never invents its own button, dropdown, radius, height, text size, material or animation. `StyleTokenScanTests` checks the rules that code can check.

[DesignGallery](../native/FrogApp/Views/Design/DesignGallery.swift) shows every component. After changing one, draw it and look: `FROG_PAGE_SHOTS=<folder> swift test --filter 'FrogAppTests.PageShotsTests/testDesignGallery'` writes `design-gallery-light.png` and `design-gallery-dark.png`.

## Less text

- A page has a title and at most one line of subtitle. A section has a caption and at most one sentence of footer.
- A row has a title (a noun: "Shortcut", "Model") and at most one short caption. Longer explanations go in `.help()`.
- Say a thing once: not in the subtitle, the caption and a footer.

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
- Pages: `FrogPage` (padding `pagePadding` 24, sections `sectionSpacing` 24 apart, a column at most `pageWidth` 720 wide; `FrogStyle.wideWidth` 1080 for dashboards and tables) with a `FrogPageHeader` (title, optional one-line subtitle, actions on the trailing side).
- A section is `FrogSection("Caption", footer:)`: a caption, one card, an optional one-sentence footer. Inside it every setting is a `FrogRow("Title", caption:) { control }`, at least `rowHeight` (38) tall; rows are set apart by their height, never by lines. A sentence that belongs to no row is a `FrogRowNote`; other content (previews, button rows) goes in a `VStack(spacing: 10).padding(.vertical, 10)`.
- `FrogRow(…, icon: { PluginIconTile(…) })` puts a feature's icon before the title.
- v1 names, for pages not moved yet: `PageScroll` and `PageHeader` now draw `FrogPage` (wide) and `FrogPageHeader`; `SettingsSection` with `CompactRow` (card padding 14, rows 10 apart) still works. Move a page to `FrogSection` and `FrogRow` all at once, never one section of it.
- Inside a card, a sub-group starts with a `SectionCaption`.
- List rows are 1–2 apart, highlighted with `frogRowHighlight(hovering:selected:)`, or `frogHoverRow(selected:)` when the row tracks its own hover.
- Spacing comes from the `FrogStyle.space2`…`space16` scale (2, 4, 6, 8, 10, 12, 16), never an odd value such as 7 or 9: 2 between a title and its caption, 4 inside a label, 6–8 between controls in a row, 10 between blocks inside a card, 12 between a row's icon, text and control, 16 between groups in a popup.
- One content edge per surface, so text lines up from the header to the footer:
  - Cards, section cards, popup headers, popup bodies and `PanelFooter` start content `cardPadding` (14) from the edge.
  - A popup list is inset `listInset` (6) and its rows padded `rowPadding` (8): 6 + 8 = 14, the same edge. A search or query line above the rows gives its icon the rows' icon width and gap, so the query starts where the titles do.
  - Sheets and setup use `sheetPadding` (20) on every side, header, body and buttons alike; the onboarding window uses `pagePadding` (24) like a page.
  - A ghost button that starts a line (a back link, Skip setup) puts its text on the content edge with `.padding(.leading, -10)`; only its hover fill reaches past it.
- `FrogPageHeader`'s title is a control tall, so it sits at the same height on every page whatever the subtitle or actions; actions are 8 apart. Icon actions in a page header are plain (`IconAction`, `IconMenu(bordered: false)`).
- The sidebar's brand, captions, row icons and the setup card share one edge (16) and one text edge (44).

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

- **Every single choice is a `FrogDropdown`.** Never `Picker`, a `Menu` used as a picker, `CompactMenu` or a hand-made popover list. It is generic over a `Hashable` value: `FrogDropdown(selection: $value, options: values, title: { $0.title }, symbol: { … })`, or `selected:`/`choose:` when the choice is saved through an action. For an optional choice make the value optional and offer `nil` ("System default", "No model").
  - Sections and rich rows: `sections: [FrogDropdownSection("Downloaded", values: …)]` with `item: { FrogDropdownItem(title, detail:, symbol:, badge:, disabled:) }`.
  - Long lists (models, apps, microphones, languages; anything over about 8): `searchPrompt: "Find a model"` turns on the search field on the same list. Search matches title and detail.
  - `compact: true` in popups and panel headers; `width:` for the button (220 by default); `.buttonTitle { … }` when the button should say less than the row; `.disabled(…)` greys it.
  - The list opens on the chosen row. Arrow keys move, Return chooses, Escape closes; the highlight never animates.
- Choices of two to four, and switching between parts of a page (Providers, Installed tools): `CompactSegments`.
- `IconMenu` is for actions behind an icon (Rename, Delete, Add an app), not for choosing a value.
- On/off settings: `Toggle` with the switch style.
- Picking items from a list (files to remove, models to offer, agents to set up): `.toggleStyle(.frogCheckbox)`. Never the system checkbox.
- Numbers from a short list: `FrogDropdown` rather than a `Stepper`.
- Text: `LabeledField` or `frogControlSurface()`. No `.roundedBorder`.
- Search: `SearchBox`. Filters that narrow a list (All, Text, Audio): `FilterTag`.
- Shortcuts: `ShortcutBadge` and `KeyCap`, in the sans font.
- Empty lists and pages: `FrogEmptyState`, with the action that fills it in its trailing slot, unless the page header already has that action.

## Surfaces and colour

- Cards: `FrogCard`, or `frogTableSurface()` for lists that draw their own rows. Blocks inside a card use the inset fill with `controlRadius` and no border.
- Popups: `frogPanel()`, rows `MenuActionRow` or `MenuRowStyle`, footer `PanelFooter`.
- Backgrounds: `frogSurface(.window | .sidebar | .popover | .hud)`, the one place that picks a material. Never `NSVisualEffectView`, `.background(.ultraThinMaterial)` or `glassEffect` in a view.
  - Opaque (transparency 0, the default, or Reduce Transparency / Increase Contrast): a plain fill, nothing blurs.
  - Translucent on macOS 26: one Liquid Glass surface for sidebars and floating panels; before 26, the kind's `NSVisualEffectView` material. Windows keep the material: glass is for chrome, not content.
  - `.popover` adds only the tint, because the popover brings its own material.
  - One surface per popup, on its root; rows get a plain highlight, never glass.
- Feature and plugin icons: `PluginIconTile(symbol:tint:size:)`, a white symbol on a tile filled with the feature's colour, `.sidebar` 20, `.list` 28, `.header` 40. Neutral, decorative symbols stay `SymbolTile`.
- `selection` marks what is chosen; `hover` what the pointer is over; `accent` shows state and focus, not decoration.
- `muted` for secondary text; `good`, `warning` and `critical` for status.

## Motion

Frog moves little: a press answers, a hover leaves softly, a choice slides, and occasional things arrive and leave. Everything else is an instant cut.

| Token | Value | Use |
| --- | --- | --- |
| `press` | strong ease-out, 0.14 s | `FrogButtonStyle`: scale 0.97 and the `pressed` fill on the down event; no scale under Reduce Motion or on keyboard surfaces |
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
- Never animate selection moved by arrow keys or Tab (dropdown lists set `frogKeyboardSurface` for this), page switches (sidebar and ⌘1–5), or text that streams in.
- No bounce anywhere: nothing in Frog is thrown or flicked. No ease-in: it starts slow where the eye is watching.
- Reduce Motion: no scale and no sliding; segments, setup steps, the error banner and the checkbox mark cross-fade instead.
- Copy actions use `CopyAction`: its symbol turns into a checkmark for `confirmation`.
- An animation names a token from `Motion.swift`: `withAnimation(FrogMotion.reveal)`, never `.easeOut(duration:)`, a bare `withAnimation` or a literal `NSAnimationContext` duration. `StyleTokenScanTests` checks it.
