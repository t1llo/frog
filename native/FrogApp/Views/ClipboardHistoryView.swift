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
                FrogEmptyState(symbol: "clipboard", title: "No copied text yet", message: "Copied text and transcription results appear here. Previews stay hidden until revealed.")
                Spacer()
            } else {
                ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Text(entry.displayPreview(revealed: state.revealedIDs.contains(entry.id)))
                            .font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.selectedIndex = index
                                state.toggleReveal(entry.id)
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                state.selectedIndex = index
                                state.toggleReveal(entry.id)
                            }
                            .accessibilityLabel(state.revealedIDs.contains(entry.id) ? "Hide copied text" : "Reveal copied text")
                            .accessibilityValue(state.revealedIDs.contains(entry.id) ? entry.preview : "Hidden")
                            .help(state.revealedIDs.contains(entry.id) ? "Click to hide" : "Click to reveal")
                        Button("Paste") { paste(entry, false) }.help("Paste with original text formatting")
                        Button { paste(entry, true) } label: { Image(systemName: "textformat") }
                            .accessibilityLabel("Paste without formatting").help("Paste without formatting")
                    }.padding(10).frame(maxWidth: .infinity, minHeight: 48)
                        .background(index == state.selectedIndex ? FrogStyle.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                Spacer(minLength: 0)
            }
            Text("↑↓ Select · Space Reveal · ↩ Paste · ⇧↩ Plain · Esc Close")
                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
        }.padding(18).frame(width: 500, height: 410).foregroundStyle(FrogStyle.ink)
            .buttonStyle(FrogButtonStyle()).controlSize(.small)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FrogStyle.border.opacity(0.6)))
            .environment(\.locale, L10n.locale)
            .onChange(of: history.entries.map(\.id)) { _, ids in
                state.revealedIDs.formIntersection(ids)
                state.selectedIndex = max(0, min(state.selectedIndex, ids.count - 1))
            }
    }
}
