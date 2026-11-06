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
            FrogSection("Settings") {
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
            let kind = ClipboardEntryKind(entry)
            Image(systemName: kind.symbol)
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).frame(width: 18).help(L10n.text(kind.title))
                .accessibilityLabel(L10n.text(kind.title))
            Text(entry.preview).font(kind == .code ? FrogType.mono : FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(RecentTimestamp.text(entry.timestamp)).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
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

/// What a copied text looks like, for its icon: a link, code or a command, formatted text, or plain text.
enum ClipboardEntryKind: Equatable {
    case link, code, richText, text

    init(_ entry: ClipboardHistoryEntry) {
        self = Self.kind(of: entry.text, formatted: !entry.formatting.isEmpty)
    }

    static func kind(of text: String, formatted: Bool) -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "mailto", "file"].contains(scheme) { return .link }
        if looksLikeCode(trimmed) { return .code }
        return formatted ? .richText : .text
    }

    var symbol: String {
        switch self {
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .richText: "doc.richtext"
        case .text: "text.alignleft"
        }
    }

    var title: String {
        switch self { case .link: "Link"; case .code: "Code"; case .richText: "Formatted text"; case .text: "Text" }
    }

    private static let commands: Set<String> = ["git", "brew", "npm", "npx", "yarn", "pnpm", "swift", "xcodebuild", "cd", "ls",
                                                "sudo", "curl", "make", "docker", "kubectl", "ssh", "python", "python3", "pip",
                                                "cargo", "go", "frog", "open", "defaults", "chmod", "mkdir", "rm", "cp", "mv"]

    /// A shell command, or text with the punctuation of code. Prose with a stray brace stays text.
    private static func looksLikeCode(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 4_000 else { return false }
        let firstWord = text.prefix { !$0.isWhitespace }.lowercased()
        if commands.contains(firstWord), !text.contains(where: \.isNewline) || text.hasPrefix("$") { return true }
        let markers = ["{", "}", ";", "=>", "->", "()", "==", "!=", "&&", "::", "</", "/>", "func ", "def ", "let ", "const "]
        return markers.filter { text.contains($0) }.count >= 2
    }
}
