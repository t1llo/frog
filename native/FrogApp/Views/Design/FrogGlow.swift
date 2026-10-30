import AppKit
import FrogCore
import Observation
import SwiftUI

/// The light inside Frog's glass: a soft glow in the accent's colours and a glare on the rim nearest it, drawn by
/// the `frogGlow` Metal shader (Resources/FrogGlow.metal). `frogSurface` puts it on popups and the sidebar; a view
/// never adds it itself.
struct FrogGlow: View {
    let style: AppearancePreferences.Glow
    let strength: Double
    let radius: CGFloat
    /// How much glare the edge takes. A sidebar has none: its edge is the window's, and a lit line there would
    /// read as a divider.
    var rim: Double = 1
    /// Drifts while shown. Still under Reduce Motion.
    var moving = false
    /// Where the pointer is over the surface; nil keeps the light where it rests.
    var pointer: FrogGlowPointer?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if style != .off, let library = FrogGlowShader.library {
            let light = pointer?.location ?? FrogGlowPointer.rest
            Group {
                if moving && !reduceMotion {
                    // 30 frames a second is smooth for a drift this slow and half the work of the display's rate.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        field(library, time: Self.seconds(context.date), light: light)
                    }
                } else {
                    field(library, time: 0, light: light)
                }
            }
            .animation(reduceMotion ? nil : FrogMotion.glare, value: light)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func field(_ library: ShaderLibrary, time: Double, light: CGPoint) -> some View {
        GlowField(library: library, style: style, strength: strength, radius: radius, rim: rim,
                  dark: scheme == .dark, time: time, light: light, hues: FrogGlowShader.hues(of: FrogStyle.accent))
    }

    /// Seconds within the hour, which keeps the shader's float time precise; the drift is too slow to see the wrap.
    private static func seconds(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
    }
}

/// The shader over the surface. `light` is animatable, so the glare glides after the pointer.
private struct GlowField: View, Animatable {
    let library: ShaderLibrary
    let style: AppearancePreferences.Glow
    let strength: Double
    let radius: CGFloat
    let rim: Double
    let dark: Bool
    let time: Double
    var light: CGPoint
    let hues: (Color, Color, Color)

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(light.x, light.y) }
        set { light = CGPoint(x: newValue.first, y: newValue.second) }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // An all but clear base: wherever the shader cannot run, nothing shows.
            Rectangle().fill(.black.opacity(0.001)).colorEffect(library.frogGlow(
                .float2(size), .float(time), .float(Self.index(style)),
                .color(hues.0), .color(hues.1), .color(hues.2),
                .float2(light), .float(strength), .float(radius), .float(rim), .float(dark ? 1 : 0)))
        }
    }

    private static func index(_ style: AppearancePreferences.Glow) -> Float {
        switch style {
        case .off, .halo: 0
        case .aurora: 1
        case .prism: 2
        }
    }
}

/// Where the pointer is over a surface, 0 to 1 across it. Kept outside the surface's own state so a move redraws
/// only the glow, never the popup's content.
@Observable
final class FrogGlowPointer {
    /// The light's place while the pointer is away: high on the leading side, where light usually falls.
    static let rest = CGPoint(x: 0.28, y: 0.08)
    private(set) var location: CGPoint?
    /// The surface's size, which turns a hover point into a place across it.
    @ObservationIgnored var size: CGSize = .zero

    func update(_ phase: HoverPhase) {
        switch phase {
        case .active(let point) where size.width > 0 && size.height > 0:
            location = CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
        default:
            location = nil
        }
    }
}

enum FrogGlowShader {
    /// Frog's compiled shaders, or nil when the bundle has none, so a missing library draws no glow rather than a
    /// white sheet.
    static let library: ShaderLibrary? = FrogResources.bundle.url(forResource: "default", withExtension: "metallib")
        .map { ShaderLibrary(url: $0) }

    /// The accent and its two neighbours on the colour wheel, saturated enough to glow. A grey accent lights in a
    /// cool blue rather than in the red its undefined hue would give.
    static func hues(of color: Color) -> (Color, Color, Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return (color, color, color) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.08 { hue = 0.6 }
        func shifted(_ offset: CGFloat) -> Color {
            Color(hue: (hue + offset + 1).truncatingRemainder(dividingBy: 1),
                  saturation: min(0.85, max(0.55, saturation * 1.25)), brightness: max(0.8, brightness))
        }
        return (shifted(0), shifted(0.1), shifted(-0.12))
    }
}
