import AppKit
import SwiftUI

/// MenuBarExtra can retain its first window size after conditional rows disappear.
/// Measure the fixed-size menu itself and resize its native window in the same layout pass.
struct MenuWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuSizeView { MenuSizeView() }
    func updateNSView(_ view: MenuSizeView, context: Context) { view.scheduleResize() }

    final class MenuSizeView: NSView {
        private var scheduled = false
        private var resizing = false
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleResize() }
        // A size change from layout resizes the window at once, in the same pass, so the new content (a tab
        // switched in the Frog menu) and the window's new height reach the screen in one frame; resizing a run loop
        // later showed one frame of the new content in the old window, a visible jump.
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); resizeNow() }
        override func layout() { super.layout(); resizeNow() }

        /// For updates from SwiftUI, which can come before the view has its new size.
        func scheduleResize() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.resizeNow()
            }
        }

        private func resizeNow() {
            guard !resizing, let window, bounds.width > 0, bounds.height > 0 else { return }
            let size = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
            let current = window.contentRect(forFrameRect: window.frame).size
            guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
            resizing = true
            defer { resizing = false }
            // AppKit's setContentSize keeps the bottom edge; menus must stay
            // anchored beneath their status item when conditional rows change.
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: false)
            window.invalidateShadow()
        }
    }
}
