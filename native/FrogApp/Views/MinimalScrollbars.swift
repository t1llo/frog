import AppKit
import SwiftUI

extension View {
    /// Apply to content inside a ScrollView so the native enclosing scroll view is targeted.
    func minimalScrollbars() -> some View { background(ScrollAppearance()) }
}

private struct ScrollAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.scheduleUpdate() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }

        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
                scroll.drawsBackground = false
                scroll.verticalScroller?.controlSize = .small
                scroll.horizontalScroller?.controlSize = .small
                scroll.scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 2)
            }
        }
    }
}
