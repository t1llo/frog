import AppKit
import SwiftUI

extension View {
    /// Apply to content inside a ScrollView so the native enclosing scroll view is targeted.
    func minimalScrollbars() -> some View { background(ScrollAppearance()) }
}

private struct ScrollAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure() }

    final class Probe: NSView {
        private weak var configured: NSScrollView?
        private var styleObservation: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { styleObservation = nil; configured = nil }
            else { configure() }
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }

        func configure() {
            guard let scroll = enclosingScrollView, scroll !== configured else { return }
            configured = scroll
            // SwiftUI can restore the system's legacy style after mounting. Keep the overlay
            // style stable synchronously, without scheduling layout work for every scroll update.
            styleObservation = scroll.observe(\.scrollerStyle) { [weak scroll] _, _ in
                MainActor.assumeIsolated {
                    if let scroll, scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                }
            }
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.verticalScroller?.controlSize = .small
            scroll.horizontalScroller?.controlSize = .small
            scroll.scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 2)
        }
    }
}
