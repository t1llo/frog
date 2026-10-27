# Design rules

Frog looks quiet and consistent: Raycast's dense, keyboard-first popups and Linear's and Notion's calm pages. Every value comes from [DesignSystem.swift](../native/FrogApp/Views/DesignSystem.swift) and [CompactControls.swift](../native/FrogApp/Views/CompactControls.swift). A view never invents its own button, radius, height or text size. `StyleTokenScanTests` checks the rules that code can check.

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
- `IconAction` for icon-only actions: a plain icon that highlights on hover, like the "…" menus beside it. `bordered: true` only in a popup header, beside compact segments.
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

## Surfaces and colour

- Cards: `FrogCard`, or `frogTableSurface()` for lists that draw their own rows. Blocks inside a card use the inset fill with `controlRadius` and no border.
- Popups: `frogPanel()`, rows `MenuActionRow` or `MenuRowStyle`, footer `PanelFooter`.
- `selection` marks what is chosen; `hover` what the pointer is over; `accent` shows state and focus, not decoration.
- `muted` for secondary text; `good`, `warning` and `critical` for status.
