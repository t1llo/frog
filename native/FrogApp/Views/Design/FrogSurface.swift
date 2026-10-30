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
    /// Panels and sidebars carry the glow. A window's content stays calm, and a popover's material is the system's.
    var glows: Bool { self == .hud || self == .sidebar }
    fileprivate var material: NSVisualEffectView.Material {
        switch self {
        case .window: .underWindowBackground
        case .sidebar: .sidebar
        case .popover, .hud: .popover
        }
    }
    fileprivate var defaultRadius: CGFloat { self == .hud ? FrogStyle.panelRadius : 0 }
    /// How much of the transparency setting reaches the tint: popups keep at least half their fill, so text on
    /// them stays readable over anything.
    fileprivate var strength: Double { isPopup ? 0.5 : 0.85 }
}

extension View {
    /// Frog's one background for windows, sidebars, popovers and floating panels.
    ///
    /// - Opaque (transparency 0, Reduce Transparency or Increase Contrast): a plain fill, no blur at all.
    /// - Translucent on macOS 26 and later: one Liquid Glass surface (`glassEffect`) for sidebars and panels.
    /// - Translucent before macOS 26, and windows: an `NSVisualEffectView` with the kind's material.
    ///
    /// Put it once on the root of a popup, never on its rows.
    func frogSurface(_ kind: FrogSurfaceKind, cornerRadius: CGFloat? = nil) -> some View {
        modifier(FrogSurfaceModifier(kind: kind, radius: cornerRadius ?? kind.defaultRadius))
    }
}

extension View {
    /// The glow of a surface that draws its own fill rather than `frogSurface`, such as the main window's sidebar.
    /// Put it just inside the fill, so the light lies over the fill and under the content:
    /// `.frogGlow(.sidebar).background(FrogStyle.sidebar)`.
    func frogGlow(_ kind: FrogSurfaceKind, cornerRadius: CGFloat = 0) -> some View {
        modifier(FrogGlowModifier(kind: kind, radius: cornerRadius))
    }
}

private struct FrogSurfaceModifier: ViewModifier {
    let kind: FrogSurfaceKind
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let amount = FrogAppearance.shared.settings.effectiveTransparency(
            popup: kind.isPopup, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        content
            .frogGlow(kind, cornerRadius: radius)
            .background { FrogSurfaceBackground(kind: kind, radius: radius, amount: amount) }
            .environment(\.frogPopupSurface, kind.isPopup)
    }
}

/// Panels glow fully, drift and follow the pointer; a sidebar glows softer, stays still and has no glare.
private struct FrogGlowModifier: ViewModifier {
    let kind: FrogSurfaceKind
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pointer = FrogGlowPointer()

    func body(content: Content) -> some View {
        let settings = FrogAppearance.shared.settings
        let glow = kind.glows ? settings.effectiveGlow(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased) : .off
        let panel = kind == .hud
        let moving = panel && settings.glowMotion != false
        if glow == .off {
            content
        } else {
            content
                .background {
                    FrogGlow(style: glow, strength: settings.effectiveGlowStrength * (panel ? 1 : 0.6), radius: radius,
                             rim: panel ? 1 : 0, moving: moving, pointer: panel ? pointer : nil)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { pointer.size = $0 }
                .onContinuousHover { phase in if moving { pointer.update(phase) } }
        }
    }
}

/// Exposed for tests: which way a surface is drawn.
enum FrogSurfaceRendering: Equatable {
    case opaque, tint, glass, material

    static func choose(_ kind: FrogSurfaceKind, amount: Double, glassAvailable: Bool) -> FrogSurfaceRendering {
        if amount <= 0 { return .opaque }
        if kind == .popover { return .tint }
        if glassAvailable, kind != .window { return .glass }
        return .material
    }

    static var glassAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
}

private struct FrogSurfaceBackground: View {
    let kind: FrogSurfaceKind
    let radius: CGFloat
    let amount: Double

    private var color: Color {
        switch kind {
        case .window: FrogStyle.opaqueCanvas
        case .sidebar: FrogStyle.opaqueSidebar
        case .popover, .hud: FrogStyle.panelSurface
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = color.opacity(1 - amount * kind.strength)
        ZStack {
            switch FrogSurfaceRendering.choose(kind, amount: amount, glassAvailable: FrogSurfaceRendering.glassAvailable) {
            case .opaque: shape.fill(color)
            case .tint: shape.fill(tint)
            case .glass: GlassBackdrop(shape: shape, tint: tint)
            case .material: FrogWindowMaterial(popup: kind.isPopup, cornerRadius: radius > 0 ? radius : nil, material: kind.material).overlay(shape.fill(tint))
            }
            // A borderless panel has to be clear itself for the rounded surface to show its corners.
            if kind == .hud { FrogClearWindow(cornerRadius: radius).accessibilityHidden(true) }
        }
    }
}

private struct GlassBackdrop: View {
    let shape: RoundedRectangle
    let tint: Color
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            shape.fill(tint).glassEffect(.regular, in: shape)
        } else {
            shape.fill(tint)
        }
        #else
        shape.fill(tint)
        #endif
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
