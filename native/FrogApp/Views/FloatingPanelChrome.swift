import SwiftUI
import FrogCore

/// The geometry the keyboard panels share (command bar, clipboard history, window switcher): one width, one tallest
/// height, the same search line on top and the same footer at the bottom. `PanelFamilyPlacement` places them.
enum FloatingPanelLayout {
    static let width = PanelFamilyPlacement.width
    static let height = PanelFamilyPlacement.height
    /// The borderless search line itself.
    static let searchLineHeight: CGFloat = 40
    /// The search line with the panel inset above it and a small gap under it, before the list starts.
    static let headerHeight: CGFloat = FrogStyle.panelInset + searchLineHeight + FrogStyle.space4
    static let footerHeight: CGFloat = 32
    /// What every panel spends on its frame: the search line, the list's gaps above and below, and the footer.
    static let chromeHeight: CGFloat = headerHeight + FrogStyle.space2 + FrogStyle.panelInset + footerHeight
}

/// The search line every keyboard panel opens with: the 15-point magnifier in the rows' icon column, then the query
/// in `FrogType.query`, borderless, as Raycast's. The line is a drag handle for the panel family, and once the family
/// was dragged away from its default place it ends in the button that moves it back.
struct FloatingPanelSearchLine<Field: View, Trailing: View>: View {
    @ObservedObject var placement: PanelFamilyPlacer
    /// The width of the rows' icon column and the gap after it, so the query starts where the row titles do.
    var iconColumn: CGFloat = 22
    var spacing: CGFloat = FrogStyle.space10
    @ViewBuilder var field: Field
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(FrogStyle.muted)
                .frame(width: iconColumn, height: 36)
                // The magnifier is a handle of its own: the field beside it takes the clicks on the rest of the line.
                .overlay { WindowDragRegion(onWindowDragEnd: { [weak placement] in placement?.finishDrag($0) }).help("Drag to move") }
            field
            trailing
            if placement.placed {
                IconAction(title: "Move back to the default place", symbol: "scope") { placement.resetShown() }
            }
        }
        .padding(.horizontal, FrogStyle.rowPadding).frame(height: FloatingPanelLayout.searchLineHeight)
        .padding(.horizontal, FrogStyle.panelInset).padding(.top, FrogStyle.panelInset).padding(.bottom, FrogStyle.space4)
        .panelFamilyDragHandle(placement)
    }
}

extension FloatingPanelSearchLine where Trailing == EmptyView {
    init(placement: PanelFamilyPlacer, iconColumn: CGFloat = 22, spacing: CGFloat = FrogStyle.space10, @ViewBuilder field: () -> Field) {
        self.init(placement: placement, iconColumn: iconColumn, spacing: spacing, field: field, trailing: { EmptyView() })
    }
}
