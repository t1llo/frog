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
    /// The list is as wide as its longest row within these bounds.
    static let listWidths: ClosedRange<CGFloat> = 248...320
    static let rowHeight: CGFloat = FrogStyle.controlHeight

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
                if index > 0, visible[index - 1].answers != item.answers { groupGap }
                Button { select(item) } label: { barLabel(item) }
                    .buttonStyle(BubbleButtonStyle(pointer: pointer))
                    .help(Self.help(item))
                    .accessibilityLabel(Self.accessibilityTitle(item))
            }
            if !more.isEmpty {
                groupGap
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
        .frogPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Selection bubble"))
    }

    /// Rules that answer and rules that replace the selection are set apart by a little more space, not a line.
    private var groupGap: some View {
        Color.clear.frame(width: 6, height: 1).accessibilityHidden(true)
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
        return VStack(alignment: .leading, spacing: 8) {
            if !answers.isEmpty { section("Answer", answers) }
            if !writing.isEmpty { section("Replace selection", writing) }
        }
        .padding(6)
    }

    private func section(_ title: String, _ items: [BubbleItem]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionCaption(text: title).padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 3)
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
        HStack(spacing: FrogStyle.space8) {
            Image(systemName: item.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.answers ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 22, height: 22)
                .background(item.answers ? FrogStyle.accentSoft : FrogStyle.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            Text(item.title).font(FrogType.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            if let hotkey = item.hotkey {
                Text(HotkeyManager.display(hotkey)).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
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

/// The hover fill under the pointer and while pressed, as rows in Frog's menus and command bar have
/// (`frogRowHighlight`), from the pointer the bubble's container reports.
private struct BubbleButtonStyle: ButtonStyle {
    @ObservedObject var pointer: BubblePointer

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .background {
                GeometryReader { proxy in
                    let hovered = pointer.location.map { proxy.frame(in: .named(SelectionBubbleView.space)).contains($0) } ?? false
                    RoundedRectangle(cornerRadius: FrogStyle.controlRadius)
                        .fill(configuration.isPressed || hovered ? FrogStyle.hover : .clear)
                }
            }
    }
}
