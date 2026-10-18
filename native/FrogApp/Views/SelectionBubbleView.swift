import SwiftUI
import FrogCore

/// Where the pointer is over the bubble, in the bubble's own coordinates. The bubble's panel never becomes key and
/// Frog stays inactive, so its AppKit container reports the pointer instead of SwiftUI's hover.
@MainActor final class BubblePointer: ObservableObject {
    @Published var location: CGPoint?
}

/// The bubble next to a selection. Collapsed it is a bar of the first rules; More turns it into the full list,
/// grouped into rules that answer and rules that replace the selection, each with its shortcut, in the style of
/// Frog's menus and the command bar's rows. Nothing in it activates Frog.
struct SelectionBubbleView: View {
    let visible: [BubbleItem]
    let more: [BubbleItem]
    let expanded: Bool
    @ObservedObject var pointer: BubblePointer
    /// The list's size once measured. Nil while it is measured; a height below the list's own makes it scroll.
    var listSize: CGSize? = nil
    var listScrolls = false
    let select: (BubbleItem) -> Void
    let expand: () -> Void

    static let space = "selectionBubble"
    /// The bar is a slim strip; the list has the corners of Frog's menus.
    static let barCorner: CGFloat = 10
    /// The list is as wide as its longest row within these bounds.
    static let listWidths: ClosedRange<CGFloat> = 248...320
    static let rowHeight: CGFloat = 30

    var body: some View {
        Group {
            if expanded { list } else { bar }
        }
        .coordinateSpace(name: Self.space)
        .fixedSize()
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                if index > 0, visible[index - 1].answers != item.answers { separator }
                Button { select(item) } label: { barLabel(item) }
                    .buttonStyle(BubbleButtonStyle(pointer: pointer))
                    .help(Self.help(item))
                    .accessibilityLabel(Self.accessibilityTitle(item))
            }
            if !more.isEmpty {
                separator
                Button(action: expand) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(FrogStyle.muted)
                        .frame(width: 24, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(BubbleButtonStyle(pointer: pointer))
                .help(L10n.text("More rules"))
                .accessibilityLabel(L10n.text("More rules"))
            }
        }
        .padding(4)
        .frogPanel(corner: Self.barCorner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Selection bubble"))
    }

    private var separator: some View {
        Rectangle().fill(FrogStyle.border.opacity(0.7)).frame(width: 1, height: 16).padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private func barLabel(_ item: BubbleItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.answers ? FrogStyle.accent : FrogStyle.muted)
            Text(item.title).font(FrogType.label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }

    // MARK: List

    private var list: some View {
        Group {
            if listScrolls, let listSize {
                ScrollView { listContent.minimalScrollbars() }.frame(height: listSize.height)
            } else {
                listContent
            }
        }
        .frame(width: listSize?.width)
        .frogPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Selection bubble"))
    }

    private var listContent: some View {
        let all = visible + more
        let answers = all.filter(\.answers), writing = all.filter { !$0.answers }
        return VStack(alignment: .leading, spacing: 1) {
            if !answers.isEmpty { section("Answer", answers) }
            if !writing.isEmpty {
                if !answers.isEmpty { Divider().padding(.horizontal, 8).padding(.vertical, 4) }
                section("Replace selection", writing)
            }
        }
        .padding(5)
    }

    private func section(_ title: String, _ items: [BubbleItem]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionCaption(text: title).padding(.horizontal, 5).padding(.top, 4).padding(.bottom, 3)
            ForEach(items) { item in
                Button { select(item) } label: { listRow(item) }
                    .buttonStyle(BubbleButtonStyle(pointer: pointer))
                    .help(Self.help(item))
                    .accessibilityLabel(Self.accessibilityTitle(item))
                    .accessibilityValue(item.hotkey.map(HotkeyManager.display) ?? "")
            }
        }
    }

    private func listRow(_ item: BubbleItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.answers ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 22, height: 22)
                .background(item.answers ? FrogStyle.accentSoft : FrogStyle.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            Text(item.title).font(FrogType.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            if let hotkey = item.hotkey {
                Text(HotkeyManager.display(hotkey)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 5)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }

    // MARK: Text

    private static func accessibilityTitle(_ item: BubbleItem) -> String {
        item.answers && item.title == "Explain" ? L10n.text("Explain selection") : item.title
    }

    private static func help(_ item: BubbleItem) -> String {
        let shortcut = item.hotkey.map { " (\(HotkeyManager.display($0)))" } ?? ""
        return item.title + shortcut
    }
}

/// A highlight under the pointer and while pressed, as rows in Frog's menus and command bar have.
private struct BubbleButtonStyle: ButtonStyle {
    @ObservedObject var pointer: BubblePointer

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .background {
                GeometryReader { proxy in
                    let hovered = pointer.location.map { proxy.frame(in: .named(SelectionBubbleView.space)).contains($0) } ?? false
                    RoundedRectangle(cornerRadius: FrogStyle.cardRadius)
                        .fill(configuration.isPressed || hovered ? FrogStyle.selection : .clear)
                }
            }
    }
}
