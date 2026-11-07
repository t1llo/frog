import AppKit
import FrogCore
import SwiftUI

/// What a surface sits on, which decides its material and how much of the user's transparency it takes.
enum FrogSurfaceKind {
    /// The content of a window. Glass is for chrome, so a window keeps the classic material on every macOS.
    case window
    /// A window's sidebar.
    case sidebar
    /// The content of an `NSPopover` or SwiftUI `.popover`. The popover draws its own material (glass on macOS
    /// 26), so this adds only the tint: a second glass inside it would blur twice.
    case popover
    /// A floating borderless panel: command bar, switchers, status pills, menu-bar popups.
    case hud

    /// Popovers and panels follow the popup transparency; windows and sidebars the window transparency.
    var isPopup: Bool { self == .popover || self == .hud }
    fileprivate var material: NSVisualEffectView.Material {
        switch self {
        case .window: .underWindowBackground
        case .sidebar: .sidebar
        case .popover, .hud: .popover
        }
    }
    fileprivate var defaultRadius: CGFloat { self == .hud ? FrogStyle.panelRadius : 0 }
    /// How much of the transparency setting reaches the tint, the same for every kind, so one setting looks the
    /// same on the window, the command bar, the switchers and clipboard history. At 100 % a fifth of the fill stays.
    fileprivate var strength: Double { 0.8 }
}

extension View {
    /// Frog's one background for windows, sidebars, popovers and floating panels.
    ///
    /// - Opaque (transparency 0, Reduce Transparency or Increase Contrast): a plain fill, no blur at all.
    /// - Translucent: an `NSVisualEffectView` blur under the theme's colour, and on a panel a light edge and sheen,
    ///   like a pane of frosted glass. Liquid Glass is not used: it changes its brightness with what lies behind,
    ///   so two panels with the same setting would look different.
    ///
    /// Put it once on the root of a popup, never on its rows.
    func frogSurface(_ kind: FrogSurfaceKind, cornerRadius: CGFloat? = nil, cornerStyle: RoundedCornerStyle = .continuous) -> some View {
        modifier(FrogSurfaceModifier(kind: kind, radius: cornerRadius ?? kind.defaultRadius, style: cornerStyle))
    }
}

extension View {
    /// A sheet's background: the main window's page, the same canvas over the same material, so a sheet's
    /// cards and buttons sit on the colours they have on a page and the sheet reads as part of Frog, not as the
    /// system's sheet grey.
    func frogSheetSurface() -> some View {
        background(FrogStyle.canvas).frogSurface(.window)
    }
}

private struct FrogSurfaceModifier: ViewModifier {
    let kind: FrogSurfaceKind
    let radius: CGFloat
    let style: RoundedCornerStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let amount = FrogAppearance.shared.settings.effectiveTransparency(
            popup: kind.isPopup, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        content
            .background { FrogSurfaceBackground(kind: kind, radius: radius, style: style, amount: amount) }
            .environment(\.frogPopupSurface, kind.isPopup)
    }
}

/// Exposed for tests: which way a surface is drawn.
enum FrogSurfaceRendering: Equatable {
    case opaque, tint, material

    static func choose(_ kind: FrogSurfaceKind, amount: Double) -> FrogSurfaceRendering {
        if amount <= 0 { return .opaque }
        if kind == .popover { return .tint }
        return .material
    }
}

private struct FrogSurfaceBackground: View {
    let kind: FrogSurfaceKind
    let radius: CGFloat
    let style: RoundedCornerStyle
    let amount: Double

    private var color: Color {
        switch kind {
        case .window: FrogStyle.opaqueCanvas
        case .sidebar: FrogStyle.opaqueSidebar
        // A panel is the window's own colour, as Rex draws its sheets and palettes on its canvas.
        case .hud: FrogStyle.opaqueCanvas
        case .popover: FrogStyle.panelSurface
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: style)
        let tint = color.opacity(1 - amount * kind.strength)
        ZStack {
            switch FrogSurfaceRendering.choose(kind, amount: amount) {
            case .opaque: shape.fill(color)
            case .tint: shape.fill(tint)
            case .material:
                FrogWindowMaterial(popup: kind.isPopup, cornerRadius: radius > 0 ? radius : nil, material: kind.material)
                    .overlay(shape.fill(tint))
                    // Light catching the top of the pane, as on a sheet of glass.
                    .overlay { if kind == .hud { shape.fill(LinearGradient(colors: [FrogStyle.glassSheen, .clear], startPoint: .top, endPoint: .center)) } }
            }
            // A borderless panel has to be clear itself for the rounded surface to show its corners.
            if kind == .hud { FrogClearWindow(cornerRadius: radius).accessibilityHidden(true) }
        }
    }
}

/// Makes the window of a borderless panel clear and clips its content host to the panel's corners, which the
/// material view does on its own. Draws nothing and takes no clicks.
private struct FrogClearWindow: NSViewRepresentable {
    let cornerRadius: CGFloat
    func makeNSView(context: Context) -> ClearingView { ClearingView() }
    func updateNSView(_ view: ClearingView, context: Context) { view.radius = cornerRadius; view.apply() }

    final class ClearingView: NSView {
        var radius: CGFloat = 0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func apply() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            guard !window.styleMask.contains(.titled), let host = window.contentView, radius > 0 else { return }
            host.wantsLayer = true
            if host.layer?.cornerRadius != radius {
                host.layer?.cornerRadius = radius
                host.layer?.masksToBounds = true
                window.invalidateShadow()
            }
        }
    }
}
