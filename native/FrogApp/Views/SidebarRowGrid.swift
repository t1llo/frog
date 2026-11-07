import SwiftUI

/// Where the sidebar list's rows sit, so its scroll comes to rest only on a row's top edge and never leaves half a
/// row under the search field, as a Mac sidebar never shows a sliver of a row at rest.
///
/// The rows report their frames in the list's own coordinates once per layout (not while scrolling), and the list
/// reports how far it is scrolled into a plain property: nothing here is observed, so scrolling redraws no view.
final class SidebarRowGrid: @unchecked Sendable {
    /// The coordinate space of the list's content.
    static let content = "sidebar-list-content"
    /// The coordinate space of the scroll view.
    static let viewport = "sidebar-list-viewport"

    /// Each row's frame in the list's content, by the ID it scrolls to.
    var rows: [AnyHashable: CGRect] = [:]
    /// How far the list is scrolled.
    var offset: CGFloat = 0
    /// The height of the scroll view.
    var viewportHeight: CGFloat = 0
    /// The height of the fade at the list's bottom edge, which a revealed row stays clear of.
    var bottomFade: CGFloat = 0
    /// The height of the fade at the list's top edge, under the search field, where the list's top row rests.
    var topFade: CGFloat = 0
    /// The header of each row's group, by the row's ID.
    var groups: [AnyHashable: AnyHashable] = [:]

    /// The offsets the list may rest at: each row's top edge, from the first.
    var stops: [CGFloat] {
        var tops = rows.values.map { ($0.minY * 2).rounded() / 2 }
        tops.append(0)
        return Set(tops).sorted()
    }

    /// The stop nearest `y`, at most `limit` (the end of the list).
    func snapped(_ y: CGFloat, limit: CGFloat) -> CGFloat {
        let stops = stops.filter { $0 <= limit + 0.5 }
        return stops.min { abs($0 - y) < abs($1 - y) } ?? 0
    }

    /// How much space below the list's last row lets its end be a stop too, so scrolled to the end the top row is
    /// whole as well. `scrollable` is the list's scroll range without that space.
    func endSpace(scrollable: CGFloat) -> CGFloat {
        guard scrollable > 0.5, let stop = stops.first(where: { $0 >= scrollable - 0.5 }) else { return 0 }
        return max(0, stop - scrollable)
    }

    /// The row to scroll to the top to show `id` clear of both edges with the least scrolling, or nil when it is in
    /// view already (or not in the list, as a pinned row). The row's group header comes into view with it whenever
    /// both fit, so the open page never shows under a group it does not belong to.
    func revealTarget(_ id: AnyHashable) -> AnyHashable? {
        guard let frame = rows[id], viewportHeight > 0 else { return nil }
        let visible = viewportHeight - topFade - bottomFade
        // The top of what must show: the group's header when the header and the row fit together.
        let header = groups[id].flatMap { rows[$0] }
        let top = header.map { frame.maxY - $0.minY <= visible + 0.5 ? $0.minY : frame.minY } ?? frame.minY
        let stop: CGFloat
        if top < offset - 0.5 {
            stop = top
        } else if frame.maxY > offset + visible + 0.5 {
            stop = min(stops.first { $0 >= frame.maxY - visible - 0.5 } ?? frame.minY, top)
        } else {
            return nil
        }
        return rows.min { abs($0.value.minY - stop) < abs($1.value.minY - stop) }?.key
    }
}

/// Lets a scroll of the sidebar list come to rest only on a row's top edge (`SidebarRowGrid.stops`).
struct SidebarRowSnap: ScrollTargetBehavior {
    let grid: SidebarRowGrid

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let limit = max(0, context.contentSize.height - context.containerSize.height)
        target.rect.origin.y = grid.snapped(target.rect.minY, limit: limit)
    }
}

extension View {
    /// Reports this sidebar row's frame to `grid`, under the ID the list scrolls to, and shows the row only while it
    /// is whole above the list's bottom fade. `group` is the ID of the header the row sits under, which comes into
    /// view with it.
    /// `keepsWith` is the height under the row that must fit with it: a group header passes its first row's, so a
    /// header never shows alone at the list's bottom edge.
    func sidebarGridRow(_ id: AnyHashable, in grid: SidebarRowGrid, group: AnyHashable? = nil, keepsWith: CGFloat = 0) -> some View {
        modifier(SidebarGridRow(id: id, grid: grid, group: group, keepsWith: keepsWith))
    }
}

/// The top edge is kept whole by the scroll resting on row tops just under the top fade, and a row scrolled up into
/// that fade fades out; the bottom edge, which falls wherever the window's height puts it, by hiding a row that would
/// show cut there. So the list starts and ends on a row boundary at rest and never shows half a row, and a row
/// scrolled into view fades in once all of it fits.
private struct SidebarGridRow: ViewModifier {
    let id: AnyHashable
    let grid: SidebarRowGrid
    let group: AnyHashable?
    let keepsWith: CGFloat
    @Environment(\.sidebarVisibleBottom) private var visibleBottom
    @Environment(\.sidebarVisibleTop) private var visibleTop
    @State private var whole = true

    func body(content: Content) -> some View {
        content
            .opacity(whole ? 1 : 0).allowsHitTesting(whole).accessibilityHidden(!whole)
            .animation(FrogMotion.reveal, value: whole)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarRowGrid.content)) } action: {
                grid.rows[id] = $0
                grid.groups[id] = group
            }
            .onGeometryChange(for: Bool.self) { [visibleTop, visibleBottom, keepsWith] proxy in
                let frame = proxy.frame(in: .named(SidebarRowGrid.viewport))
                return visibleBottom <= 0 || (frame.minY >= visibleTop - 0.5 && frame.maxY + keepsWith <= visibleBottom + 0.5)
            } action: { fits in
                if fits != whole { whole = fits }
            }
            .onDisappear { grid.rows[id] = nil; grid.groups[id] = nil }
    }
}

private struct SidebarVisibleBottomKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct SidebarVisibleTopKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// Where the sidebar list's rows start showing whole: under its top fade. A row scrolled up into the fade
    /// fades out as it goes, so none rests there cut under the search field.
    var sidebarVisibleTop: CGFloat {
        get { self[SidebarVisibleTopKey.self] }
        set { self[SidebarVisibleTopKey.self] = newValue }
    }
    /// Where the sidebar list's rows stop showing whole: the scroll view's height less its bottom fade; 0 before
    /// the list is laid out, which shows every row.
    var sidebarVisibleBottom: CGFloat {
        get { self[SidebarVisibleBottomKey.self] }
        set { self[SidebarVisibleBottomKey.self] = newValue }
    }
}
