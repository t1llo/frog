import SwiftUI

/// Clipboard history in the panel family's frame: the family's width and height, the list on the leading side and the
/// selected item's preview beside it, as Raycast sets its clipboard.
enum ClipboardHistoryLayout {
    static let width = FloatingPanelLayout.width
    static let height = FloatingPanelLayout.height
    static let rowHeight: CGFloat = 40
    static let inset: CGFloat = FrogStyle.panelInset
    /// The list column, its leading inset included: two fifths of the panel, which leaves the preview the rest.
    static let listWidth: CGFloat = 272
    /// The list's own height, between the search line and the footer.
    static let listHeight: CGFloat = height - FloatingPanelLayout.chromeHeight
    /// Where the first row starts, from the panel's top.
    static let listTop: CGFloat = FloatingPanelLayout.headerHeight + FrogStyle.space2
    static let visibleRows = Int(listHeight / rowHeight)

    /// The row at this distance from the top of the list's content, if there is one there.
    static func row(at offsetFromTop: CGFloat, count: Int) -> Int? {
        guard offsetFromTop >= 0, offsetFromTop.isFinite else { return nil }
        let index = Int(offsetFromTop / rowHeight)
        return index < count ? index : nil
    }

    /// One size whatever the count, so the preview keeps its room and the panel never jumps as items come and go.
    static func size(entryCount: Int = 0) -> CGSize { CGSize(width: width, height: height) }
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

/// The clipboard history panel: a search that has the cursor, the items it matches, the selected item in full beside
/// them, and the keys. Nothing in it animates; it is opened by keyboard many times a day.
struct ClipboardHistoryView: View {
    let state: ClipboardHistoryPanelState
    let paste: (ClipboardHistoryEntry, Bool) -> Void
    let copy: (ClipboardHistoryEntry) -> Void
    let close: () -> Void
    let resize: () -> Void
    /// The pointer moving over a row; the controller decides whether that selects it.
    var hover: (UUID) -> Void = { _ in }
    var placement = PanelFamilyPlacer()
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var state = state
        let entries = state.visible
        VStack(spacing: 0) {
            // Borderless, as the command bar's: the magnifier in the rows' icon column, the query where their text starts.
            FloatingPanelSearchLine(placement: placement, iconColumn: 20) {
                // The field's own placeholder is nearly as dark as typed text; this one is lighter.
                TextField("", text: $state.query).textFieldStyle(.plain).font(FrogType.query)
                    .focused($searching).accessibilityLabel(L10n.text("Search clipboard"))
                    .background(alignment: .leading) {
                        if state.query.isEmpty {
                            Text(L10n.text("Search clipboard")).font(FrogType.query).foregroundStyle(FrogStyle.placeholder)
                                .lineLimit(1).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            } trailing: {
                // Clears the search once there is one; Escape closes the panel.
                if !state.query.isEmpty {
                    IconAction(title: "Clear search", symbol: "xmark.circle.fill") { state.query = ""; searching = true }
                }
            }

            if entries.isEmpty {
                Text(state.query.isEmpty ? "Copied text shows here" : "No matches")
                    .font(FrogType.row).foregroundStyle(FrogStyle.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: ClipboardHistoryLayout.inset) {
                    list(entries)
                    if let selected = state.selected {
                        ClipboardPreview(entry: selected, shownAt: state.openedAt)
                    }
                }
                .padding(.horizontal, ClipboardHistoryLayout.inset)
                .padding(.top, FrogStyle.space2).padding(.bottom, ClipboardHistoryLayout.inset)
                .frame(maxHeight: .infinity, alignment: .top)
            }

            footer(count: state.total).panelFamilyDragHandle(placement)
        }
        .frame(width: ClipboardHistoryLayout.width, height: ClipboardHistoryLayout.height)
        .frogPanel()
        .environment(\.locale, L10n.locale).environment(\.frogKeyboardSurface, true)
        .onChange(of: entries.count) { _, _ in resize() }
        .onAppear { searching = true }
        .onChange(of: state.focusRequest) { _, _ in searching = true }
    }

    private func list(_ entries: [ClipboardHistoryEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, selected: index == state.selectedIndex).id(entry.id)
                    }
                }.minimalScrollbars()
            }
            // `.never`, not `.hidden`: with "Show scroll bars: Always" macOS shows a hidden indicator anyway.
            .scrollIndicators(.never)
            .bottomScrollFade(height: ClipboardHistoryLayout.rowHeight)
            .frame(width: ClipboardHistoryLayout.listWidth - ClipboardHistoryLayout.inset, height: ClipboardHistoryLayout.listHeight)
            .onChange(of: state.selectedIndex) { _, index in
                // A row the pointer chose is already where the pointer is.
                if !state.selectionFromPointer, entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
            }
        }
    }

    /// What Return and Shift-Return do, each beside its keys, and Close for the pointer and VoiceOver. ⌘C copies
    /// as everywhere on the Mac, so it needs no hint of its own: four crowded the band.
    private func footer(count: Int) -> some View {
        FrogFooter {
            // The surface and its icon first, like every launcher's footer, then the count.
            // Part of the footer's drag handle, like the band around it.
            Image(systemName: ClipboardPlugin.info.symbol).font(FrogType.label).allowsHitTesting(false)
            Text(verbatim: L10n.text(ClipboardPlugin.info.name) + " · "
                 + (count == 1 ? L10n.text("1 item") : String(format: L10n.text("%d items"), count))).monospacedDigit()
                .allowsHitTesting(false)
        } actions: {
            FrogFooterHint("Paste", keys: "↩")
            FrogFooterHint("Plain text", keys: "⇧↩")
            FrogFooterHint("Close", keys: "esc", action: close)
        }
    }

    /// The kind's tile and the first line; when it was copied is in the preview beside the list.
    private func row(_ entry: ClipboardHistoryEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            let kind = entry.kind
            PluginIconTile(symbol: kind.symbol, tint: kind.tint.color, size: .sidebar).help(L10n.text(kind.title))
            // One type voice down the list, as on the Clipboard page: the tile says what kind of item it is, so code
            // is not set in mono.
            Text(entry.preview).font(FrogType.row).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// The selected item in full, so a long text, a link or code can be checked before it is pasted: the text on a card
/// beside the list, scrolling when it is long, and under it what it is and when it was copied.
struct ClipboardPreview: View {
    let entry: ClipboardHistoryEntry
    var shownAt: Date = .distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: FrogStyle.space10) {
                    if entry.kind == .color, let color = Self.color(entry.text) {
                        RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous).fill(color)
                            .frame(height: 56)
                    }
                    Text(verbatim: entry.text).font(FrogType.row).foregroundStyle(FrogStyle.ink)
                        .lineSpacing(FrogStyle.space2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(FrogStyle.cardPadding)
            }
            .scrollIndicators(.never)
            .bottomScrollFade(height: ClipboardHistoryLayout.rowHeight)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: FrogStyle.space4) {
                info("Type", L10n.text(entry.kind.title))
                info("Characters", entry.text.count.formatted())
                info(Self.lines(entry.text) > 1 ? "Lines" : "Words",
                     (Self.lines(entry.text) > 1 ? Self.lines(entry.text) : Self.words(entry.text)).formatted())
                HStack {
                    Text(L10n.text("Copied")).foregroundStyle(FrogStyle.muted)
                    Spacer(minLength: FrogStyle.space8)
                    RecentTimestampText(date: entry.timestamp, shownAt: shownAt).foregroundStyle(FrogStyle.ink)
                }
            }
            .font(FrogType.small).padding(.horizontal, FrogStyle.cardPadding).padding(.vertical, FrogStyle.space10)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frogTableSurface()
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack {
            Text(L10n.text(title)).foregroundStyle(FrogStyle.muted)
            Spacer(minLength: FrogStyle.space8)
            Text(verbatim: value).foregroundStyle(FrogStyle.ink).monospacedDigit().lineLimit(1)
        }
    }

    static func lines(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).count
    }
    static func words(_ text: String) -> Int { text.split { $0.isWhitespace || $0.isNewline }.count }

    /// A copied `#rgb`, `#rrggbb` or `#rrggbbaa`, as a swatch.
    static func color(_ text: String) -> Color? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let alpha = hex.count == 8 ? Double(value & 0xFF) / 255 : 1
        let rgb = hex.count == 8 ? value >> 8 : value
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: alpha)
    }
}
