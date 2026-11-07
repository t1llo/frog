import SwiftUI
import FrogCore

/// The Clipboard page: its shortcut, how much it keeps, and what was copied.
struct ClipboardPage: View {
    let plugin: ClipboardPlugin
    @ObservedObject var store: ClipboardHistoryStore
    let state: ClipboardPageState
    @State private var search = ""

    /// The page lists this many; the search reaches the rest.
    static let shown = 100
    static let sizes = [50, 100, 200, 500, 1000]

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Clipboard", subtitle: "Kept in memory. Passwords and keys never are.") {
                IconMenu(title: "Clipboard actions", bordered: false) {
                    Button("Clear history", systemImage: "trash", role: .destructive) { store.clear() }
                        .disabled(store.entries.isEmpty)
                }
            }
            FrogSection("Shortcut & size") {
                FrogRow("Shortcut") {
                    HotkeyRecorder(hotkey: Binding(get: { state.settings.shortcut.hotkey },
                                                   set: { if let value = $0 { plugin.setShortcut(value) } }),
                                   showsClearButton: false, purpose: .clipboardHistory)
                }
                if let issue = state.shortcutIssue { FrogRowNote(text: issue, tone: FrogStyle.warning) }
                FrogRow("Keep") {
                    FrogDropdown(selected: state.settings.items, options: Self.sizes(with: state.settings.items), width: 140,
                                 title: { "\($0) items" }) { plugin.setItems($0) }
                }
            }
            copied
        }
    }

    @ViewBuilder private var copied: some View {
        let all = store.entries
        let found = ClipboardSearch.filter(all, query: search)
        FrogSection("Copied", count: all.isEmpty ? nil : all.count) {
            if all.isEmpty {
                FrogEmptyState(symbol: ClipboardPlugin.info.symbol, title: "Nothing copied yet", message: "Text you copy shows here.",
                               tint: ClipboardPlugin.info.tint)
            } else {
                VStack(spacing: 10) {
                    // The count belongs to the heading, as every counted group's does.
                    ListToolbar(placeholder: "Search copied items", search: $search)
                    if found.isEmpty {
                        Text("No matches").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(found.prefix(Self.shown)) { entry in ClipboardPageRow(entry: entry, store: store) }
                        }
                        // The list recipe: rows padded rowPadding, `listInset` from the card, so the tiles start
                        // `rowInset` in, on the field's and the headings' edge, as on every page.
                        .padding(.horizontal, FrogStyle.listInset - FrogStyle.rowInset)
                    }
                }.padding(.vertical, 10)
            }
        }
    }

    /// The sizes on offer, with a size set in config.toml that is not one of them.
    private static func sizes(with current: Int) -> [Int] {
        sizes.contains(current) ? sizes : (sizes + [current]).sorted()
    }
}

/// One copied item: its kind tile, its text and when it was copied, the time ending on the row's trailing edge. Its
/// actions (Copy, and "…" with the rest) take the time's place while the pointer is over it, so the list stays quiet
/// and the times line up down the card's edge.
private struct ClipboardPageRow: View {
    let entry: ClipboardHistoryEntry
    let store: ClipboardHistoryStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: FrogStyle.space10) {
            // The same kind tile as the clipboard history panel.
            let kind = entry.kind
            PluginIconTile(symbol: kind.symbol, tint: kind.tint.color, size: .sidebar).help(L10n.text(kind.title))
                .accessibilityLabel(L10n.text(kind.title))
            Text(entry.preview).font(kind == .code ? FrogType.body.monospaced() : FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                // As far in from the trailing edge as the tile is from the leading one.
                RecentTimestampText(date: entry.timestamp).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    .fixedSize()
                    .opacity(hovering ? 0 : 1)
                HStack(spacing: FrogStyle.space2) {
                    CopyAction { store.copy(entry) }
                    IconMenu(title: "More", bordered: false) { menu }
                }
                .frogRowAccessory()
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(!hovering)
            }
        }
        .padding(.horizontal, FrogStyle.rowPadding).frame(minHeight: 32)
        .contentShape(Rectangle())
        .frogRowHighlight(hovering: hovering)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        // The hover actions are hidden from VoiceOver until hovered, so the row itself offers every one of them.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Copy")) { store.copy(entry) }
        .accessibilityAction(named: Text("Copy as plain text")) { store.copy(entry, plainText: true) }
        .accessibilityAction(named: Text("Remove")) { store.delete(id: entry.id) }
    }

    @ViewBuilder private var menu: some View {
        Button("Copy", systemImage: "doc.on.doc") { store.copy(entry) }
        Button("Copy as plain text", systemImage: "doc.plaintext") { store.copy(entry, plainText: true) }
        Button("Remove", systemImage: "trash", role: .destructive) { store.delete(id: entry.id) }
    }
}
