import AppKit
import SwiftUI
import FrogCore

/// A floating panel that never activates Frog. Shown with orderFrontRegardless(); clicking it makes it key
/// (when allowed) without activating the app, so the frontmost app keeps its focused field.
final class FrogFloatingPanel: NSPanel {
    let allowsKey: Bool

    init(size: CGSize, allowsKey: Bool, movable: Bool = false) {
        self.allowsKey = allowsKey
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovableByWindowBackground = movable
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Moves the panel to `frame` and shows it without making it key or activating Frog.
    func show(at frame: CGRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    /// The displays' visible frames, in the form `PanelPlacement` takes.
    func screensForPlacement() -> [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }
}

/// Accepts the first click while another app stays active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSEvent {
    /// The modifiers `PanelKeyMap` decides on; Caps Lock, Fn and the keypad flag are left out.
    var panelModifiers: PanelModifiers {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: PanelModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
