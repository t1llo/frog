import SwiftUI

enum ClipboardHistoryLayout {
    static let width: CGFloat = 480
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 60
    static let emptyHeight: CGFloat = 112
    static let inset: CGFloat = 6

    static func size(entryCount: Int) -> CGSize {
        let contentHeight = entryCount == 0 ? emptyHeight : CGFloat(min(5, entryCount)) * rowHeight
        return CGSize(width: width, height: headerHeight + footerHeight + inset * 2 + 2 + contentHeight)
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var history: ClipboardHistoryStore
    @ObservedObject var state: ClipboardHistoryPanelState
    let paste: (ClipboardHistoryEntry, Bool) -> Void
    let close: () -> Void
    let clear: () -> Void

    var body: some View {
        let size = ClipboardHistoryLayout.size(entryCount: history.entries.count)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "clipboard", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard history").font(.system(size: 14, weight: .semibold))
                    Text("Last five copied text items").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
                Spacer()
                Text("\(history.entries.count)/5").font(.system(size: 10, design: .monospaced)).foregroundStyle(FrogStyle.muted)
                IconAction(title: "Clear clipboard history", symbol: "trash", destructive: true, action: clear)
                    .disabled(history.entries.isEmpty)
                IconAction(title: "Close", symbol: "xmark", action: close)
            }.padding(12).frame(height: ClipboardHistoryLayout.headerHeight)
            Divider().opacity(0.5)

            VStack(spacing: 0) {
                if history.entries.isEmpty {
                    VStack(spacing: 6) {
                        Text("No copied text yet").font(.system(size: 12, weight: .medium))
                        Text("Copy text in any app to add it here.").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    }.frame(maxWidth: .infinity).frame(height: ClipboardHistoryLayout.emptyHeight)
                } else {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry, index: index)
                    }
                }
            }.padding(ClipboardHistoryLayout.inset)
            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 14) {
                    Text("↑↓ Select")
                    Text("↩ Paste")
                    Text("⇧↩ Plain text")
                    Spacer(minLength: 0)
                    Text("esc Close")
                }.font(.system(size: 10))
                Label("Memory only · Marked-sensitive text starts hidden", systemImage: "lock.shield")
                    .font(.system(size: 9))
            }.foregroundStyle(FrogStyle.muted).padding(.horizontal, 14).frame(height: ClipboardHistoryLayout.footerHeight)
        }.frame(width: size.width, height: size.height)
            .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
            .environment(\.locale, L10n.locale)
    }

    private func entryRow(_ entry: ClipboardHistoryEntry, index: Int) -> some View {
        let selected = state.selectedIndex == index
        let hidden = entry.isSensitive && !state.revealedIDs.contains(entry.id)
        return HStack(spacing: 10) {
            Image(systemName: entry.isSensitive ? "lock" : "doc.text")
                .font(.system(size: 12)).foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayPreview(revealed: !hidden)).font(.system(size: 12)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .time)
                    if entry.isSensitive { Text("·"); Text(hidden ? "Space to reveal" : "Click to hide") }
                    else if !entry.formatting.isEmpty { Text("·"); Text("Formatted text") }
                }.font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { select(entry, index: index) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(entry.isSensitive ? (hidden ? "Reveal sensitive text" : "Hide sensitive text") : "Select copied text")
                .accessibilityValue(hidden ? "Hidden" : entry.preview)
                .accessibilityAction { select(entry, index: index) }
                .help(entry.isSensitive ? (hidden ? "Click to reveal" : "Click to hide") : "Select item, then press Return to paste")
            IconAction(title: "Paste with formatting", symbol: "return", bordered: true) { paste(entry, false) }
            IconAction(title: "Paste without formatting", symbol: "textformat", bordered: true) { paste(entry, true) }
        }.padding(.horizontal, 10).frame(height: ClipboardHistoryLayout.rowHeight)
            .background(selected ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ entry: ClipboardHistoryEntry, index: Int) {
        state.selectedIndex = index
        if entry.isSensitive { state.toggleReveal(entry.id) }
    }
}
