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
                IconMenu(title: "Clipboard actions") {
                    Button("Clear history", systemImage: "trash", role: .destructive) { store.clear() }
                        .disabled(store.entries.isEmpty)
                }
            }
            FrogSection {
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
        FrogSection("Copied", accessory: {
            if !all.isEmpty { Text(all.count == 1 ? "1 item" : "\(all.count) items").font(FrogType.caption).foregroundStyle(FrogStyle.muted) }
        }) {
            if all.isEmpty {
                FrogEmptyState(symbol: "clipboard", title: "Nothing copied yet", message: "Text you copy shows here.") { EmptyView() }
            } else {
                VStack(spacing: 10) {
                    SearchBox(placeholder: "Search copied text", text: $search)
                    if found.isEmpty {
                        Text("No matches").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(found.prefix(Self.shown)) { entry in ClipboardPageRow(entry: entry, store: store) }
                        }
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

private struct ClipboardPageRow: View {
    let entry: ClipboardHistoryEntry
    let store: ClipboardHistoryStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.formatting.isEmpty ? "text.alignleft" : "doc.richtext")
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).frame(width: 18).accessibilityHidden(true)
            Text(entry.preview).font(FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.timestamp, style: .time).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            CopyAction { store.copy(entry) }
            IconAction(title: "Remove", symbol: "xmark") { store.delete(id: entry.id) }
        }
        .padding(.leading, 8).padding(.trailing, 2).frame(minHeight: 32).frogHoverRow()
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { store.copy(entry) }
            Button("Copy as plain text") { store.copy(entry, plainText: true) }
            Button("Remove", systemImage: "trash", role: .destructive) { store.delete(id: entry.id) }
        }
    }
}
