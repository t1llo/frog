import AppKit
import SwiftUI

/// An explicit drag surface for headings, separate from adjacent interactive controls.
struct WindowDragRegion: NSViewRepresentable {
    var onDragEnd: () -> Void = {}
    func makeNSView(context: Context) -> DragView { let view = DragView(); view.onDragEnd = onDragEnd; return view }
    func updateNSView(_ nsView: DragView, context: Context) { nsView.onDragEnd = onDragEnd }

    final class DragView: NSView {
        var onDragEnd: () -> Void = {}
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let origin = window?.frame.origin
            window?.performDrag(with: event)
            if window?.frame.origin != origin { onDragEnd() }
        }
    }
}
