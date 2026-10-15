import AppKit
import SwiftUI
import FrogCore

/// The bubble next to a selection: a small panel that never becomes key and never activates Frog, so the other app
/// keeps its focused field. Clicks reach its buttons through first-mouse; a tracking area reports hovering, which
/// keeps the bubble from going away by itself.
@MainActor final class SelectionBubbleController: SelectionBubblePresenting {
    static let gap: CGFloat = 6
    var onHover: ((Bool) -> Void)?
    var onSelect: ((BubbleItem) -> Void)?
    private var panel: FrogFloatingPanel?
    private var hosting: FirstMouseHostingView<SelectionBubbleView>?
    private var visible: [BubbleItem] = []
    private var more: [BubbleItem] = []
    private var expanded = false
    private var anchor: CGRect?
    private var pointer: CGPoint = .zero

    var isVisible: Bool { panel?.isVisible == true }

    func show(visible: [BubbleItem], more: [BubbleItem], anchor: CGRect?, pointer: CGPoint) {
        self.visible = visible
        self.more = more
        self.anchor = anchor
        self.pointer = pointer
        expanded = false
        place()
    }

    func hide() {
        panel?.orderOut(nil)
        expanded = false
    }

    /// Measures the content and places the bubble below and right of the anchor, or above it near the bottom of
    /// the display. Expanding More places it again at its new size.
    private func place() {
        let panel = makePanel()
        let view = content()
        hosting?.rootView = view
        let size = NSHostingView(rootView: view).fittingSize
        let result = PanelPlacement.place(size: size, anchor: anchor, pointer: pointer, screens: panel.screensForPlacement(),
                                          gap: Self.gap)
        panel.show(at: result.frame)
    }

    private func content() -> SelectionBubbleView {
        SelectionBubbleView(visible: visible, more: more, expanded: expanded,
                            select: { [weak self] in self?.onSelect?($0) },
                            expand: { [weak self] in
                                guard let self else { return }
                                self.expanded = true
                                self.place()
                            })
    }

    private func makePanel() -> FrogFloatingPanel {
        if let panel { return panel }
        let panel = FrogFloatingPanel(size: CGSize(width: 120, height: 30), allowsKey: false)
        panel.collectionBehavior.insert(.ignoresCycle)
        panel.title = L10n.text("Selection bubble")
        let container = BubbleHoverView()
        container.onHover = { [weak self] in self?.onHover?($0) }
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

/// Reports the pointer entering and leaving the bubble while another app is active.
private final class BubbleHoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
