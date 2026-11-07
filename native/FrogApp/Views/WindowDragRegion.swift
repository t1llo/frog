import AppKit
import SwiftUI

/// An explicit drag surface for headings, separate from adjacent interactive controls.
struct WindowDragRegion: NSViewRepresentable {
    var onDragEnd: () -> Void = {}
    /// The same moment, given the window that moved: the floating panels hand it to `PanelFamilyPlacer.finishDrag`.
    var onWindowDragEnd: ((NSWindow) -> Void)? = nil
    func makeNSView(context: Context) -> DragView { let view = DragView(); update(view); return view }
    func updateNSView(_ nsView: DragView, context: Context) { update(nsView) }
    private func update(_ view: DragView) { view.onDragEnd = onDragEnd; view.onWindowDragEnd = onWindowDragEnd }

    final class DragView: NSView {
        var onDragEnd: () -> Void = {}
        var onWindowDragEnd: ((NSWindow) -> Void)?
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let origin = window?.frame.origin
            window?.performDrag(with: event)
            if window?.frame.origin != origin { dragEnded() }
        }
        /// What follows a drag that moved the window; `mouseDown` calls it once AppKit's drag loop returns.
        func dragEnded() {
            onDragEnd()
            if let window { onWindowDragEnd?(window) }
        }
    }
}

extension View {
    /// Makes this part of a keyboard panel (its search line, its footer) a handle that drags the panel family, and
    /// remembers where it was left.
    func panelFamilyDragHandle(_ placement: PanelFamilyPlacer) -> some View {
        background(WindowDragRegion(onWindowDragEnd: { [weak placement] in placement?.finishDrag($0) }).accessibilityHidden(true))
    }
}
