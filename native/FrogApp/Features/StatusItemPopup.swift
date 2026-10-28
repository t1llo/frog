import AppKit
import SwiftUI

/// A popup beneath one of Frog's status items: borderless like Frog's own menu-bar popup, no
/// popover arrow. A click anywhere else, Frog becoming inactive or another Frog popup opening
/// closes it.
@MainActor final class StatusItemPopup {
    /// Told to Frog's other popups as it opens, so they close.
    let name: String
    private(set) var panel: NSPanel?
    private var localClick: Any?
    private var outsideClick: Any?
    private var deactivation: NSObjectProtocol?
    private var otherPopup: NSObjectProtocol?
    var isShown: Bool { panel?.isVisible == true }

    init(name: String) { self.name = name }

    func show(_ host: NSView, relativeTo anchor: NSView) {
        close()
        // Frog's own menu-bar popup closes itself when this one opens, and the reverse.
        NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: name)
        let size = host.fittingSize
        let panel = StatusPopupPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = host
        panel.setFrameOrigin(Self.origin(size: size, anchor: anchor))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak anchor] event in
            guard let self, let panel = self.panel else { return event }
            // The popup and the menus it opens are inside; everything else in Frog dismisses it.
            var window = event.window
            while let current = window { if current === panel { return event }; window = current.parent }
            // Let the status button's own action toggle once, rather than close/reopen.
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
            self.close()
            return event
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let name = name
        otherPopup = NotificationCenter.default.addObserver(forName: .frogMenuPopupWillOpen, object: nil, queue: .main) { [weak self] note in
            let other = note.object as? String != name
            MainActor.assumeIsolated { if other { self?.close() } }
        }
    }

    func close() {
        if let localClick { NSEvent.removeMonitor(localClick) }; localClick = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }; outsideClick = nil
        for observer in [deactivation, otherPopup].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        deactivation = nil; otherPopup = nil
        guard let panel else { return }
        self.panel = nil
        // It fades like Frog's own menu-bar popup; clicks meanwhile reach whatever is beneath it.
        panel.ignoresMouseEvents = true
        // Popup content is created when opened; releasing it ends its visible refresh.
        panel.fadeOut { panel.contentView = nil }
    }

    /// Directly beneath the status item and left-aligned with it, like a MenuBarExtra window,
    /// kept inside the item's display.
    private static func origin(size: NSSize, anchor: NSView) -> NSPoint {
        let button = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero
        var origin = NSPoint(x: button.minX, y: button.minY - 5 - size.height)
        if let visible = (anchor.window?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, origin.y)
        }
        return origin
    }
}

/// A borderless panel takes no key focus by default; the popup's controls and Escape need it.
private final class StatusPopupPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
