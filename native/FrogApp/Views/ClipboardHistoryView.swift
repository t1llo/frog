import SwiftUI

enum ClipboardHistoryLayout {
    static let width: CGFloat = 520
    /// The search field (36) a panel inset from the top; the list's own inset keeps the same gap under it.
    static let headerHeight: CGFloat = FrogStyle.panelInset + 36
    static let footerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 40
    static let emptyHeight: CGFloat = 64
    static let inset: CGFloat = FrogStyle.panelInset
    static let visibleRows = 9

    /// The row at this distance from the top of the list's content, if there is one there.
    static func row(at offsetFromTop: CGFloat, count: Int) -> Int? {
        guard offsetFromTop >= 0, offsetFromTop.isFinite else { return nil }
        let index = Int(offsetFromTop / rowHeight)
        return index < count ? index : nil
    }

    static func size(entryCount: Int) -> CGSize {
        let contentHeight = entryCount == 0 ? emptyHeight : CGFloat(min(visibleRows, entryCount)) * rowHeight
        return CGSize(width: width, height: headerHeight + footerHeight + inset * 2 + contentHeight)
    }

    /// The free area of the display with keyboard focus (`main`), where the field it pastes into
    /// is, else of the display under the pointer. Nil leaves the placement to `NSWindow.center()`.
    static func visibleFrame(main: CGRect?, screens: [(frame: CGRect, visibleFrame: CGRect)], pointer: CGPoint) -> CGRect? {
        main ?? screens.first { $0.frame.contains(pointer) }?.visibleFrame
    }

    /// Where `NSWindow.center()` puts a window, but on the screen given: across the middle,
    /// three quarters of the way up the free height.
    static func origin(size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(.down),
                y: (visibleFrame.minY + (visibleFrame.height - size.height) * 3 / 4).rounded(.down))
    }
}

/// What a copied text looks like, so a list can tell a link from code or a sentence at a glance. Each
/// `ClipboardHistoryEntry` works its kind out once, from its full text.
enum ClipboardContentKind: Equatable, Sendable {
    case link, email, path, color, number, code, richText, text

    init(_ text: String, formatted: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let single = !trimmed.contains("\n")
        let lower = trimmed.lowercased()
        if single, !trimmed.contains(" "), lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { self = .link }
        else if single, !trimmed.contains(" "), Self.emailPattern.matches(trimmed) { self = .email }
        else if single, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"), trimmed.count < 400 { self = .path }
        else if single, Self.colorPattern.matches(trimmed) { self = .color }
        else if single, !trimmed.isEmpty, Self.numberPattern.matches(trimmed) { self = .number }
        else if Self.looksLikeCode(trimmed) { self = .code }
        else { self = formatted ? .richText : .text }
    }

    private static let emailPattern = try! NSRegularExpression(pattern: #"^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$"#)
    private static let colorPattern = try! NSRegularExpression(pattern: #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"^[-+]?[0-9][0-9.,\s]*%?$"#)

    /// Shell commands and source code: punctuation prose rarely has, or a command line's first word.
    private static func looksLikeCode(_ text: String) -> Bool {
        let commands = ["git ", "brew ", "npm ", "cd ", "swift ", "sudo ", "ls ", "curl ", "make ", "python", "pip ", "docker ", "ssh ", "./", "$ "]
        if commands.contains(where: { text.hasPrefix($0) }) { return true }
        let marks = ["{", "}", "();", "=>", "->", "==", "!=", "&&", "||", "</", "/>", "func ", "let ", "const ", "def ", "import ", "return "]
        return marks.filter { text.contains($0) }.count >= 2
    }

    var symbol: String {
        switch self {
        case .link: "link"
        case .email: "envelope"
        case .path: "folder"
        case .color: "paintpalette"
        case .number: "number"
        // Not the angle brackets or bare braces, which are OpenCode's and Codex's marks.
        case .code: "ellipsis.curlybraces"
        case .richText: "doc.richtext"
        case .text: "text.alignleft"
        }
    }

    var tint: PluginTint {
        switch self {
        case .link: .blue
        case .email: .teal
        case .path: .indigo
        case .color: .pink
        case .number: .gray
        case .code: .purple
        case .richText: .indigo
        case .text: .orange
        }
    }

    var title: String {
        switch self {
        case .link: "Link"
        case .email: "Email address"
        case .path: "Path"
        case .color: "Colour"
        case .number: "Number"
        case .code: "Code"
        case .richText: "Formatted text"
        case .text: "Text"
        }
    }
}

private extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// The clipboard history panel: a search that has the cursor, the items it matches, and the keys. Nothing in
/// it animates; it is opened by keyboard many times a day.
struct ClipboardHistoryView: View {
    let state: ClipboardHistoryPanelState
    let paste: (ClipboardHistoryEntry, Bool) -> Void
    let copy: (ClipboardHistoryEntry) -> Void
    let close: () -> Void
    let resize: () -> Void
    /// The pointer moving over a row; the controller decides whether that selects it.
    var hover: (UUID) -> Void = { _ in }
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var state = state
        let entries = state.visible
        VStack(spacing: 0) {
            // Borderless, as the command bar's: the magnifier in the rows' icon column, the query where their text starts.
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(FrogStyle.muted).frame(width: 20)
                // The field's own placeholder is nearly as dark as typed text; this one is lighter.
                TextField("", text: $state.query).textFieldStyle(.plain).font(FrogType.query)
                    .focused($searching).accessibilityLabel(L10n.text("Search clipboard"))
                    .background(alignment: .leading) {
                        if state.query.isEmpty {
                            Text(L10n.text("Search clipboard")).font(FrogType.query).foregroundStyle(FrogStyle.placeholder)
                                .lineLimit(1).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                // Clears the search once there is one; Escape closes the panel.
                if !state.query.isEmpty {
                    IconAction(title: "Clear search", symbol: "xmark.circle.fill") { state.query = ""; searching = true }
                }
            }.frame(height: 36)
            .padding(.leading, 10).padding(.trailing, 4)
            .padding(.horizontal, ClipboardHistoryLayout.inset).padding(.top, ClipboardHistoryLayout.inset)
            .frame(height: ClipboardHistoryLayout.headerHeight)

            Group {
                if entries.isEmpty {
                    Text(state.query.isEmpty ? "Copied text shows here" : "No matches")
                        .font(FrogType.row).foregroundStyle(FrogStyle.muted)
                        .frame(maxWidth: .infinity).frame(height: ClipboardHistoryLayout.emptyHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, selected: index == state.selectedIndex).id(entry.id)
                                }
                            }.minimalScrollbars()
                        }
                        .frame(height: CGFloat(min(ClipboardHistoryLayout.visibleRows, entries.count)) * ClipboardHistoryLayout.rowHeight)
                        .onChange(of: state.selectedIndex) { _, index in
                            // A row the pointer chose is already where the pointer is.
                            if !state.selectionFromPointer, entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
                        }
                    }
                }
            }.padding(ClipboardHistoryLayout.inset)

            footer(count: state.total)
        }
        .frame(width: ClipboardHistoryLayout.width, height: ClipboardHistoryLayout.size(entryCount: entries.count).height)
        .frogPanel()
        .environment(\.locale, L10n.locale).environment(\.frogKeyboardSurface, true)
        .onChange(of: entries.count) { _, _ in resize() }
        .onAppear { searching = true }
        .onChange(of: state.focusRequest) { _, _ in searching = true }
    }

    /// What Return and Shift-Return do, each beside its keys, and Close for the pointer and VoiceOver. ⌘C copies
    /// as everywhere on the Mac, so it needs no hint of its own: four crowded the band.
    private func footer(count: Int) -> some View {
        FrogFooter {
            // The surface and its icon first, like every launcher's footer, then the count.
            Image(systemName: ClipboardPlugin.info.symbol).font(FrogType.label)
            Text(verbatim: L10n.text(ClipboardPlugin.info.name) + " · "
                 + (count == 1 ? L10n.text("1 item") : String(format: L10n.text("%d items"), count))).monospacedDigit()
        } actions: {
            FrogFooterHint("Paste", keys: "↩")
            FrogFooterHint("Plain text", keys: "⇧↩")
            FrogFooterHint("Close", keys: "esc", action: close)
        }
    }

    private func row(_ entry: ClipboardHistoryEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            let kind = entry.kind
            PluginIconTile(symbol: kind.symbol, tint: kind.tint.color, size: .sidebar).help(L10n.text(kind.title))
            // One type voice down the list, as on the Clipboard page: the tile says what kind of item it is, so code
            // is not set in mono.
            Text(entry.preview).font(FrogType.row).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            RecentTimestampText(date: entry.timestamp, shownAt: state.openedAt).font(FrogType.small).foregroundStyle(FrogStyle.muted).monospacedDigit()
                .padding(.leading, FrogStyle.space6)
                .help(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
        }
        .padding(.horizontal, 10).frame(height: ClipboardHistoryLayout.rowHeight)
        // The pointer moves the selection, so the selection is the only highlight: a second, hover highlight
        // looked the same and was not the row Return pastes.
        .frogRowHighlight(hovering: false, selected: selected)
        .onContinuousHover { phase in if case .active = phase { hover(entry.id) } }
        // By the item, not by its place, which a copy arriving meanwhile changes.
        .onTapGesture { state.select(id: entry.id) }
        // Alongside the single click, so selecting never waits for a possible second one.
        .simultaneousGesture(TapGesture(count: 2).onEnded { paste(entry, false) })
        .help("Double-click to paste")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(entry.preview)
        .accessibilityAction { paste(entry, false) }
        .accessibilityAction(named: "Copy") { copy(entry) }
    }
}
