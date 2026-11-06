import SwiftUI

enum ClipboardHistoryLayout {
    static let width: CGFloat = 520
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 36
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
        case .code: "chevron.left.forwardslash.chevron.right"
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
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted).frame(width: 18)
                TextField("Search clipboard", text: $state.query).textFieldStyle(.plain).font(FrogType.row)
                    .focused($searching)
                IconAction(title: "Close", symbol: "xmark", action: close)
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .frogControlSurface(height: 36, radius: FrogStyle.controlRadius)
            .padding(.horizontal, ClipboardHistoryLayout.inset).frame(height: ClipboardHistoryLayout.headerHeight)

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

    /// What Return, Shift-Return and Command-C do, each beside its keys.
    private func footer(count: Int) -> some View {
        HStack(spacing: 14) {
            Text(count == 1 ? "1 item" : "\(count) items").font(FrogType.label).foregroundStyle(FrogStyle.muted)
            Spacer(minLength: 0)
            hint("Paste", keys: ["↩"])
            hint("Plain text", keys: ["⇧", "↩"])
            hint("Copy", keys: ["⌘", "C"])
        }
        .padding(.horizontal, 14).frame(height: ClipboardHistoryLayout.footerHeight)
        // Rex's sheet footer: the panel's own colour under a thin line.
        .frame(maxWidth: .infinity).overlay(alignment: .top) { Rectangle().fill(FrogStyle.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func hint(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text(title)).font(FrogType.label).foregroundStyle(FrogStyle.ink)
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap($0) } }
        }.fixedSize()
    }

    private func row(_ entry: ClipboardHistoryEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            let kind = entry.kind
            PluginIconTile(symbol: kind.symbol, tint: kind.tint.color, size: .sidebar).help(L10n.text(kind.title))
            Text(entry.preview).font(FrogType.row).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            RecentTimestampText(date: entry.timestamp, shownAt: state.openedAt).font(FrogType.small).foregroundStyle(FrogStyle.muted).monospacedDigit()
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
