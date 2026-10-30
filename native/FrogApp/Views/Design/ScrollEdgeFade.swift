import SwiftUI

extension View {
    /// Fades the bottom edge of a scroll view, so a row cut off by it reads as "more below" rather than as clipped.
    /// Apply to the `ScrollView`, and give its content at least `height` of bottom padding so the last row clears
    /// the fade once scrolled to the end. No state and no geometry reads: it costs nothing while scrolling.
    func bottomScrollFade(height: CGFloat = 20) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: height)
            }
        }
    }
}
