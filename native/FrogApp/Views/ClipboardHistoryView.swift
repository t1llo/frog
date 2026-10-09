import SwiftUI

enum ClipboardHistoryLayout {
    static let width: CGFloat = 480
    static let headerHeight: CGFloat = 74
    static let footerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 40
    static let emptyHeight: CGFloat = 76
    static let inset: CGFloat = 6
    static let visibleRows = 8

    static func size(entryCount: Int) -> CGSize {
        let contentHeight = entryCount == 0 ? emptyHeight : CGFloat(min(visibleRows, entryCount)) * rowHeight
        return CGSize(width: width, height: headerHeight + footerHeight + inset * 2 + 2 + contentHeight)
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

    var body: some View {
        let entries = state.visibleEntries(in: history.entries)
        let size = ClipboardHistoryLayout.size(entryCount: entries.count)
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "clipboard").foregroundStyle(FrogStyle.muted)
                    Text("Clipboard history").font(.system(size: 12, weight: .semibold))
                    Text("\(history.entries.count)/\(ClipboardHistoryStore.capacity)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(FrogStyle.muted)
                    Spacer()
                    IconAction(title: "Clear clipboard history", symbol: "trash", destructive: true, action: clear)
                        .disabled(history.entries.isEmpty)
                    IconAction(title: "Close", symbol: "xmark", action: close)
                }
                SearchBox(placeholder: "Search copied text", text: $state.query)
            }.padding(.horizontal, 12).frame(height: ClipboardHistoryLayout.headerHeight)
            Divider().opacity(0.5)

            VStack(spacing: 0) {
                if entries.isEmpty {
                    VStack(spacing: 6) {
                        Text(state.query.isEmpty ? "No copied text yet" : "No matching items").font(.system(size: 12, weight: .medium))
                        Text(state.query.isEmpty ? "Copy text in any app to add it here." : "Try another search.").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
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
            Divider().opacity(0.5)

            HStack(spacing: 12) {
                Text("↑↓ Select")
                Text("⌘C Copy")
                Text("↩ Paste")
                Text("⇧↩ Plain")
                Spacer(minLength: 0)
                Text("Memory only")
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                .padding(.horizontal, 12).frame(height: ClipboardHistoryLayout.footerHeight)
        }.frame(width: size.width, height: size.height)
            .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
            .environment(\.locale, L10n.locale)
            .onChange(of: entries.count, initial: true) { _, count in resize(count) }
    }

    private func entryRow(_ entry: ClipboardHistoryEntry, index: Int) -> some View {
        let selected = state.selectedIndex == index
        let hidden = entry.isSensitive && !state.revealedIDs.contains(entry.id)
        return HStack(spacing: 10) {
            Image(systemName: entry.isSensitive ? "lock" : "doc.text")
                .font(.system(size: 12)).foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayPreview(revealed: !hidden)).font(.system(size: 12)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .time)
                    if entry.isSensitive { Text("·"); Text(hidden ? "Space to reveal" : "Click to hide") }
                    else if !entry.formatting.isEmpty { Text("·"); Text("Formatted text") }
                }.font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { select(entry, index: index) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(entry.isSensitive ? (hidden ? "Reveal sensitive text" : "Hide sensitive text") : "Select copied text")
                .accessibilityValue(hidden ? "Hidden" : entry.preview)
                .accessibilityAction { select(entry, index: index) }
                .help(entry.isSensitive ? (hidden ? "Click to reveal" : "Click to hide") : "Select item, then press Return to paste")
            IconAction(title: "Copy item", symbol: "doc.on.doc", bordered: true) { copy(entry) }
            IconAction(title: "Paste with formatting", symbol: "return", bordered: true) { paste(entry, false) }
            IconAction(title: "Paste without formatting", symbol: "textformat", bordered: true) { paste(entry, true) }
        }.padding(.horizontal, 10).frame(height: ClipboardHistoryLayout.rowHeight)
            .background(selected ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ entry: ClipboardHistoryEntry, index: Int) {
        state.selectedIndex = index
        if entry.isSensitive { state.toggleReveal(entry.id) }
    }
}
