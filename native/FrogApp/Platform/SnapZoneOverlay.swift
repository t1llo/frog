import AppKit
import FrogCore
import SwiftUI

/// What the zone overlay shows on one display, in Accessibility's top-left-origin coordinates.
struct SnapZoneLayout: Equatable {
    struct Zone: Equatable, Identifiable {
        var action: WindowAction
        var frame: CGRect
        var id: WindowAction { action }
    }

    /// The visible frame of the display the overlay covers.
    var frame: CGRect
    var zones: [Zone]
    var highlight: WindowAction?

    /// The zones of `grid` over a display's usable area, the way a release there would use them.
    init(display: WindowDisplay, grid: ZoneGrid, options: WindowLayoutOptions, highlight: WindowAction? = nil) {
        let area = options.usableArea(display.visibleFrame)
        frame = display.visibleFrame
        zones = grid.rects(in: area, portrait: options.portraitThirds && area.height > area.width)
            .map { Zone(action: $0.0, frame: $0.1) }
        self.highlight = highlight
    }
}

/// Covers one display with the zones a window held with Shift can be dropped into. Clicks pass
/// through; never key and never activates Frog. Created once and reused.
@MainActor
final class SnapZoneOverlay {
    private var panel: NSPanel?
    private let model = SnapZoneOverlayModel()

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ layout: SnapZoneLayout) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = WindowPreviewPanel.cocoaRect(layout.frame, primaryTop: primaryTop)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.layout = layout
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
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
        panel.contentView = NSHostingView(rootView: SnapZoneOverlayView(model: model))
        return panel
    }
}

@MainActor
private final class SnapZoneOverlayModel: ObservableObject {
    @Published var layout: SnapZoneLayout?
}

/// Tiles with a window's corner radius, a 1 pt accent outline and the layout's name; the one under
/// the pointer filled with the accent at 30 %.
private struct SnapZoneOverlayView: View {
    @ObservedObject var model: SnapZoneOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layout = model.layout {
                ForEach(layout.zones) { zone in
                    let local = zone.frame.offsetBy(dx: -layout.frame.minX, dy: -layout.frame.minY).insetBy(dx: 4, dy: 4)
                    let highlighted = zone.action == layout.highlight
                    RoundedRectangle(cornerRadius: FrogStyle.panelRadius)
                        .fill(highlighted ? FrogStyle.accent.opacity(0.3) : Color.black.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: FrogStyle.panelRadius).strokeBorder(FrogStyle.accent, lineWidth: 1))
                        .overlay {
                            Text(zone.action.title)
                                .font(FrogType.bodyMedium)
                                .foregroundStyle(FrogStyle.ink)
                                .padding(.horizontal, 8).frame(height: FrogStyle.compactHeight)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                        }
                        .frame(width: max(0, local.width), height: max(0, local.height))
                        .offset(x: local.minX, y: local.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
