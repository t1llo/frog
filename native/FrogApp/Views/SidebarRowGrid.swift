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
    /// view already (or not in the list, as a pinned row).
    func revealTarget(_ id: AnyHashable) -> AnyHashable? {
        guard let frame = rows[id], viewportHeight > 0 else { return nil }
        let visible = viewportHeight - bottomFade
        let stop: CGFloat
        if frame.minY < offset - 0.5 {
            stop = frame.minY
        } else if frame.maxY > offset + visible + 0.5 {
            stop = stops.first { $0 >= frame.maxY - visible - 0.5 } ?? frame.minY
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
    /// Reports this sidebar row's frame to `grid`, under the ID the list scrolls to.
    func sidebarGridRow(_ id: AnyHashable, in grid: SidebarRowGrid) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarRowGrid.content)) } action: { grid.rows[id] = $0 }
            .onDisappear { grid.rows[id] = nil }
    }
}
