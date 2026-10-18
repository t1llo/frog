import AppKit
import SwiftUI
import FrogCore

/// The bubble next to a selection: a small panel that never becomes key and never activates Frog, so the other app
/// keeps its focused field. Clicks reach its buttons through first-mouse; a tracking area reports hovering, which
/// keeps the bubble from going away by itself, and where the pointer is, which highlights the button under it.
@MainActor final class SelectionBubbleController: SelectionBubblePresenting {
    static let gap: CGFloat = 6
    /// The full list scrolls past this height, or past the room beside the selection when that is less.
    static let listMaxHeight: CGFloat = 420
    /// Three rows and a heading: shorter than this the list is no use, so it covers part of the selection instead.
    static let listMinHeight: CGFloat = 130
    var onHover: ((Bool) -> Void)?
    var onSelect: ((BubbleItem) -> Void)?
    private var panel: FrogFloatingPanel?
    private var hosting: FirstMouseHostingView<SelectionBubbleView>?
    private var visible: [BubbleItem] = []
    private var more: [BubbleItem] = []
    private var expanded = false
    private var anchor: CGRect?
    private var pointer: CGPoint = .zero
    /// Whether the pointer is over the bubble, as last reported to `onHover`.
    private var inside = false
    /// The pointer over the bubble, for the highlight.
    let hover = BubblePointer()
    /// The panel's window number while it shows, so a screenshot can take this window alone.
    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }
    /// Where the panel is, while it shows.
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    var isVisible: Bool { panel?.isVisible == true }

    func show(visible: [BubbleItem], more: [BubbleItem], anchor: CGRect?, pointer: CGPoint) {
        self.visible = visible
        self.more = more
        self.anchor = anchor
        self.pointer = pointer
        expanded = false
        place()
    }

    /// The full list, as More opens it.
    func expand() {
        expanded = true
        place()
    }

    func hide() {
        panel?.orderOut(nil)
        expanded = false
        hover.location = nil
        inside = false
    }

    /// Measures the content and places the bubble. Expanding More places it again at its new size.
    private func place() {
        let panel = makePanel()
        var view = content()
        let natural = NSHostingView(rootView: view).fittingSize
        let frame = Self.frame(natural: natural, expanded: expanded, anchor: anchor, pointer: pointer,
                               screens: panel.screensForPlacement())
        if expanded { view = content(listSize: frame.size, scrolls: frame.height < natural.height) }
        hosting?.rootView = view
        panel.show(at: frame)
        // The panel moved or changed size under a pointer that may not have moved, so no tracking event says where
        // it is now.
        track(Self.location(of: NSEvent.mouseLocation, in: frame))
    }

    /// Below and right of the anchor, or above it near the bottom of the display. The list grows away from the
    /// selection, on the side with room for it, and scrolls when neither side has room for all of it. The anchor
    /// spans every line of the selection, so neither side covers an earlier line.
    static func frame(natural: CGSize, expanded: Bool, anchor: CGRect?, pointer: CGPoint, screens: [CGRect]) -> CGRect {
        var size = natural
        if expanded {
            size = listSize(natural: natural, room: PanelPlacement.room(anchor: anchor, pointer: pointer, screens: screens, gap: gap))
        }
        return PanelPlacement.place(size: size, anchor: anchor, pointer: pointer, screens: screens, gap: gap).frame
    }

    /// The list as wide as its longest row within `listWidths`, and as tall as its rows up to the room beside the
    /// selection and `listMaxHeight`.
    static func listSize(natural: CGSize, room: CGFloat) -> CGSize {
        let widths = SelectionBubbleView.listWidths
        return CGSize(width: min(max(natural.width, widths.lowerBound), widths.upperBound),
                      height: min(natural.height, listMaxHeight, max(room, listMinHeight)))
    }

    /// A point on screen in the bubble's coordinates, from its top left as SwiftUI counts; nil outside it.
    static func location(of point: CGPoint, in frame: CGRect) -> CGPoint? {
        guard frame.contains(point) else { return nil }
        return CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    /// Highlights the button under the pointer and tells the watcher when the pointer came or went.
    private func track(_ location: CGPoint?) {
        hover.location = location
        let now = location != nil
        guard now != inside else { return }
        inside = now
        onHover?(now)
    }

    private func content(listSize: CGSize? = nil, scrolls: Bool = false) -> SelectionBubbleView {
        SelectionBubbleView(visible: visible, more: more, expanded: expanded, pointer: hover, listSize: listSize,
                            listScrolls: scrolls,
                            select: { [weak self] in self?.onSelect?($0) },
                            expand: { [weak self] in self?.expand() })
    }

    private func makePanel() -> FrogFloatingPanel {
        if let panel { return panel }
        let panel = FrogFloatingPanel(size: CGSize(width: 120, height: 30), allowsKey: false)
        panel.collectionBehavior.insert(.ignoresCycle)
        panel.acceptsMouseMovedEvents = true
        panel.title = L10n.text("Selection bubble")
        let container = BubbleHoverView()
        container.onMove = { [weak self] in self?.track($0) }
        let hosting = FirstMouseHostingView(rootView: content())
        // The panel sets its own size from the measured content.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        hosting.frame = container.bounds
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// Reports the pointer entering, moving over and leaving the bubble while another app is active.
private final class BubbleHoverView: NSView {
    /// The pointer in the bubble's coordinates, from its top left as SwiftUI counts; nil once it left.
    var onMove: ((CGPoint?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { move(event) }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseExited(with event: NSEvent) { onMove?(nil) }

    private func move(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMove?(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }
}
