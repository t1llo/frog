import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var history: ClipboardHistoryStore
    @ObservedObject var state: ClipboardHistoryPanelState
    let paste: (ClipboardHistoryEntry, Bool) -> Void
    let close: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clipboard history").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Clear", action: clear).disabled(history.entries.isEmpty)
                IconAction(title: "Close", symbol: "xmark", action: close)
            }
            Text("Last five text items · kept only while Frog is running")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            if history.entries.isEmpty {
                FrogEmptyState(symbol: "clipboard", title: "No copied text yet", message: "Copy text in any app to add it here. Password-manager marked items are excluded.")
                Spacer()
            } else {
                ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Text(entry.preview).font(.system(size: 12)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Paste") { paste(entry, false) }.help("Paste with original text formatting")
                        Button { paste(entry, true) } label: { Image(systemName: "textformat") }
                            .accessibilityLabel("Paste without formatting").help("Paste without formatting")
                    }.padding(10).frame(maxWidth: .infinity, minHeight: 48)
                        .background(index == state.selectedIndex ? FrogStyle.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle()).onTapGesture { state.selectedIndex = index }
                }
                Spacer(minLength: 0)
            }
            Text("↑↓ Select · Return Paste · Shift–Return Plain text · Esc Close")
                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
        }.padding(18).frame(width: 500, height: 410).foregroundStyle(FrogStyle.ink)
            .buttonStyle(FrogButtonStyle()).controlSize(.small)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FrogStyle.border.opacity(0.6)))
            .environment(\.locale, L10n.locale)
    }
}
