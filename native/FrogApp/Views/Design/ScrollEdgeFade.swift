import SwiftUI

extension View {
    /// Fades the bottom edge of a scroll view, so a row cut off by it reads as "more below" rather than as clipped.
    /// Apply to the `ScrollView`. Its content keeps `height` clear of the fade: the last row once scrolled to the end,
    /// and a row scrolled into view with `ScrollViewProxy`. No state and no geometry reads: it costs nothing while
    /// scrolling.
    func bottomScrollFade(height: CGFloat = 20) -> some View {
        contentMargins(.bottom, height, for: .scrollContent).mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: height)
            }
        }
    }
}

extension View {
    /// Fades the top edge of a scroll view, so a row scrolled up under a field above it (the sidebar's search) slips
    /// away softly instead of being cut through. Its content starts `height` down, clear of the fade, so nothing is
    /// faded until it is scrolled. Combines with `bottomScrollFade()`. No state and no geometry reads.
    func topScrollFade(height: CGFloat = 12) -> some View {
        contentMargins(.top, height, for: .scrollContent).mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: height)
                Rectangle()
            }
        }
    }
}
