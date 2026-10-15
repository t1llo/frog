import AppKit
import SwiftUI

/// Shows on screen where a window would go: a tinted, outlined area that clicks pass through.
/// Never key and never activates Frog. Created once and reused.
@MainActor
final class WindowPreviewPanel {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the area, given in Accessibility's top-left-origin coordinates. With `below`, the
    /// area stays under that window, such as the panel that chose it.
    func show(accessibilityFrame: CGRect, below window: NSWindow? = nil) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = Self.cocoaRect(accessibilityFrame, primaryTop: primaryTop)
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(frame, display: true)
        if let window, window.isVisible { panel.order(.below, relativeTo: window.windowNumber) }
        else { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    /// An Accessibility rectangle (origin top left of the primary display) in Cocoa's
    /// coordinates (origin bottom left), given the top edge of the primary display.
    static func cocoaRect(_ accessibilityRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: accessibilityRect.minX, y: primaryTop - accessibilityRect.maxY,
               width: accessibilityRect.width, height: accessibilityRect.height)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: WindowPreviewShape())
        return panel
    }
}

/// The accent at 30 % with a 2 pt accent border.
private struct WindowPreviewShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(FrogStyle.accent.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(FrogStyle.accent, lineWidth: 2))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
