import AppKit
import SwiftUI

/// MenuBarExtra can retain its first window size after conditional rows disappear.
/// Measure the fixed-size menu itself, then resize its native window on the next turn.
struct MenuWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuSizeView { MenuSizeView() }
    func updateNSView(_ view: MenuSizeView, context: Context) { view.scheduleResize() }

    final class MenuSizeView: NSView {
        private var scheduled = false
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleResize() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); scheduleResize() }
        override func layout() { super.layout(); scheduleResize() }

        func scheduleResize() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, self.bounds.width > 0, self.bounds.height > 0 else { return }
                let size = NSSize(width: ceil(self.bounds.width), height: ceil(self.bounds.height))
                let current = window.contentRect(forFrameRect: window.frame).size
                guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
                // AppKit's setContentSize keeps the bottom edge; menus must stay
                // anchored beneath their status item when conditional rows change.
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true)
                window.invalidateShadow()
            }
        }
    }
}
