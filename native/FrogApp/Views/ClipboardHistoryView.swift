import SwiftUI

enum ClipboardHistoryLayout {
    static let width: CGFloat = 520
    static let headerHeight: CGFloat = 48
    static let footerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 34
    static let emptyHeight: CGFloat = 64
    static let inset: CGFloat = 6
    static let visibleRows = 9

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

/// The clipboard history panel: a search that has the cursor, the items it matches, and the keys. Nothing in
/// it animates; it is opened by keyboard many times a day.
struct ClipboardHistoryView: View {
    let state: ClipboardHistoryPanelState
    let paste: (ClipboardHistoryEntry, Bool) -> Void
    let copy: (ClipboardHistoryEntry) -> Void
    let close: () -> Void
    let resize: () -> Void
    @FocusState private var searching: Bool
    @State private var hovered: UUID?

    var body: some View {
        @Bindable var state = state
        let entries = state.visible
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted).frame(width: 18)
                TextField("Search clipboard", text: $state.query).textFieldStyle(.plain).font(FrogType.lead)
                    .focused($searching)
                IconAction(title: "Close", symbol: "xmark", action: close)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: ClipboardHistoryLayout.headerHeight)

            Group {
                if entries.isEmpty {
                    Text(state.query.isEmpty ? "Copied text shows here" : "No matches")
                        .font(FrogType.body).foregroundStyle(FrogStyle.muted)
                        .frame(maxWidth: .infinity).frame(height: ClipboardHistoryLayout.emptyHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, index: index, selected: index == state.selectedIndex).id(entry.id)
                                }
                            }.minimalScrollbars()
                        }
                        .frame(height: CGFloat(min(ClipboardHistoryLayout.visibleRows, entries.count)) * ClipboardHistoryLayout.rowHeight)
                        .onChange(of: state.selectedIndex) { _, index in
                            if entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
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
        .frame(maxWidth: .infinity).background(FrogStyle.inset)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text(title)).font(FrogType.label).foregroundStyle(FrogStyle.ink)
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap($0) } }
        }.fixedSize()
    }

    private func row(_ entry: ClipboardHistoryEntry, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.formatting.isEmpty ? "text.alignleft" : "doc.richtext")
                .font(.system(size: 12)).foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 18).accessibilityHidden(true)
            Text(entry.preview).font(FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.timestamp, style: .time).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        }
        .padding(.horizontal, 8).frame(height: ClipboardHistoryLayout.rowHeight)
        .frogRowHighlight(hovering: hovered == entry.id, selected: selected)
        .onHover { inside in
            if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
        }
        .onTapGesture { state.selectedIndex = index }
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
