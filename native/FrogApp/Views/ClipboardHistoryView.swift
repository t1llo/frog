import SwiftUI

enum ClipboardHistoryLayout {
    static let width: CGFloat = 480
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 40
    static let emptyHeight: CGFloat = 76
    static let inset: CGFloat = 6
    static let visibleRows = 8

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

struct ClipboardHistoryView: View {
    @ObservedObject var history: ClipboardHistoryStore
    @ObservedObject var state: ClipboardHistoryPanelState
    let paste: (ClipboardHistoryEntry, Bool) -> Void
    let copy: (ClipboardHistoryEntry) -> Void
    let close: () -> Void
    let clear: () -> Void
    let resize: (Int) -> Void
    @State private var hovered: UUID?

    var body: some View {
        let entries = state.visibleEntries(in: history.entries)
        let selected = entries.indices.contains(state.selectedIndex) ? entries[state.selectedIndex] : nil
        let size = ClipboardHistoryLayout.size(entryCount: entries.count)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted).frame(width: 20)
                TextField("Search clipboard…", text: $state.query).textFieldStyle(.plain).font(FrogType.lead)
                Menu {
                    Button("Clear clipboard history", role: .destructive, action: clear).disabled(history.entries.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Clipboard actions")
                IconAction(title: "Close", symbol: "xmark", action: close)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: ClipboardHistoryLayout.headerHeight)

            VStack(spacing: 0) {
                if entries.isEmpty {
                    VStack(spacing: 6) {
                        Text(state.query.isEmpty ? "No copied text yet" : "No matching items").font(FrogType.bodyMedium)
                        Text(state.query.isEmpty ? "Copy text in any app to add it here." : "Try another search.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    }.frame(maxWidth: .infinity).frame(height: ClipboardHistoryLayout.emptyHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    entryRow(entry, index: index).id(entry.id)
                                }
                            }.minimalScrollbars()
                        }.frame(height: CGFloat(min(ClipboardHistoryLayout.visibleRows, entries.count)) * ClipboardHistoryLayout.rowHeight)
                            .onChange(of: state.selectedIndex) { _, index in
                                if entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
                            }
                    }
                }
            }.padding(ClipboardHistoryLayout.inset)

            // The footer of every Frog panel: on the inset fill, each action named beside its keys.
            HStack(spacing: 2) {
                Text("\(history.entries.count) items").foregroundStyle(FrogStyle.muted)
                Spacer(minLength: 0)
                Button { if let selected { copy(selected) } } label: { hint("Copy", keys: ["⌘", "C"]) }
                    .buttonStyle(.frog(.ghost, compact: true)).disabled(selected == nil).accessibilityLabel("⌘C Copy")
                hint("Paste", keys: ["↩"]).padding(.horizontal, 8)
                    .accessibilityElement(children: .ignore).accessibilityLabel("↩ Paste")
                Button { if let selected { paste(selected, true) } } label: { hint("Plain", keys: ["⇧", "↩"]) }
                    .buttonStyle(.frog(.ghost, compact: true)).disabled(selected == nil).accessibilityLabel("⇧↩ Plain")
            }.font(FrogType.label)
                .padding(.leading, 14).padding(.trailing, 4).frame(height: ClipboardHistoryLayout.footerHeight)
                .frame(maxWidth: .infinity).background(FrogStyle.inset)
        }.frame(width: size.width, height: size.height)
            .frogPanel()
            .environment(\.locale, L10n.locale).environment(\.frogKeyboardSurface, true)
            .onChange(of: entries.count, initial: true) { _, count in resize(count) }
    }

    /// "Copy ⌘C": what a key does, then its keys as caps, as in `PanelFooter`.
    private func hint(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text(title)).foregroundStyle(FrogStyle.ink)
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap($0) } }
        }
    }

    private func entryRow(_ entry: ClipboardHistoryEntry, index: Int) -> some View {
        let selected = state.selectedIndex == index
        let hidden = entry.isSensitive && !state.revealedIDs.contains(entry.id)
        return HStack(spacing: 12) {
            Image(systemName: entry.isSensitive ? "lock" : "doc.text")
                .font(.system(size: 12)).foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayPreview(revealed: !hidden)).font(FrogType.body).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .time)
                    if entry.isSensitive { Text("·"); Text(hidden ? "Space to reveal" : "Click to hide") }
                    else if !entry.formatting.isEmpty { Text("·"); Text("Formatted text") }
                }.font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { select(entry, index: index) }
                // Alongside the single click, so selecting never waits for a possible second one.
                .simultaneousGesture(TapGesture(count: 2).onEnded { paste(entry, false) })
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(entry.isSensitive ? (hidden ? "Reveal sensitive text" : "Hide sensitive text") : "Select copied text")
                .accessibilityValue(hidden ? "Hidden" : entry.preview)
                .accessibilityAction { select(entry, index: index) }
                .help(entry.isSensitive ? (hidden ? "Click to reveal" : "Click to hide") : "Double-click to paste, or select and press Return")
            IconAction(title: "Paste with formatting", symbol: "return") { paste(entry, false) }
                .opacity(selected ? 1 : 0).allowsHitTesting(selected).accessibilityHidden(!selected)
        }.padding(.horizontal, 8).frame(height: ClipboardHistoryLayout.rowHeight)
            .frogRowHighlight(hovering: hovered == entry.id, selected: selected)
            .onHover { inside in
                if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ entry: ClipboardHistoryEntry, index: Int) {
        state.selectedIndex = index
        if entry.isSensitive { state.toggleReveal(entry.id) }
    }
}
