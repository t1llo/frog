import SwiftUI
import FrogCore

/// A capsule of rule buttons next to a selection. Past four rules the last slot is More, which lists the rest
/// below the row instead of opening a menu, so Frog never becomes active.
struct SelectionBubbleView: View {
    let visible: [BubbleItem]
    let more: [BubbleItem]
    let expanded: Bool
    let select: (BubbleItem) -> Void
    let expand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                ForEach(visible) { button($0) }
                if !more.isEmpty && !expanded {
                    Button(action: expand) {
                        label(L10n.text("More"), symbol: "ellipsis")
                    }
                    .buttonStyle(BubbleButtonStyle())
                    .help(L10n.text("More rules"))
                    .accessibilityLabel(L10n.text("More rules"))
                }
            }
            if expanded {
                Divider().padding(.horizontal, 4)
                ForEach(more) { button($0).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .padding(3)
        .frogPanel(corner: expanded ? FrogStyle.cardRadius + 4 : 15)
        .fixedSize()
    }

    private func button(_ item: BubbleItem) -> some View {
        Button { select(item) } label: {
            label(item.title, symbol: item.symbol)
        }
        .buttonStyle(BubbleButtonStyle())
        .help(item.title)
        .accessibilityLabel(item.answers && item.title == "Explain" ? L10n.text("Explain selection") : item.title)
    }

    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(title).font(FrogType.label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
    }
}

private struct BubbleButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .background(configuration.isPressed ? FrogStyle.accent.opacity(0.22) : FrogStyle.ink.opacity(0.06), in: Capsule())
    }
}
