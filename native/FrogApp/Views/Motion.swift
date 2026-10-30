import AppKit
import SwiftUI

/// Frog's motion. docs/design.md says what moves and what never does; `StyleTokenScanTests` checks that every
/// animation in the app names one of these.
enum FrogMotion {
    /// A button answering a press: a quick strong ease-out to 0.97 and back, short enough to never lag a click.
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    /// A hover fill leaving. It arrives at once. CSS `ease`, the curve for a colour change.
    static let hoverOut = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15)
    /// A choice moving to another option, such as the thumb of a segmented control.
    static let slide = Animation.spring(response: 0.28, dampingFraction: 1)
    /// Something occasional arriving, such as an error banner. A strong ease-out: it moves at once and settles
    /// slowly, where the built-in ease-out starts too gently.
    static let reveal = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    /// The same leaving, a little faster than it came.
    static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    /// A checkbox's mark arriving or leaving: small and frequent, so it stays at 0.15 s.
    static let check = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    /// A step of the setup assistant.
    static let step = Animation.spring(response: 0.35, dampingFraction: 1)
    /// Floating windows fading out (status pills, status item popups), for `NSAnimationContext`, on the curve of
    /// `reveal` and `exit`.
    static let fadeOut: TimeInterval = 0.2
    static let fadeOutCurve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// The dictation pill growing with its text, for `NSAnimationContext`. It changes shape on screen, so it eases
    /// in and out.
    static let resize: TimeInterval = 0.22
    static let resizeCurve = CAMediaTimingFunction(name: .easeInEaseOut)
    /// How long a copy stays confirmed.
    static let confirmation = Duration.seconds(1.5)

    /// Hover in is instant and hover out fades, except on keyboard surfaces, where nothing moves.
    static func hover(_ active: Bool, keyboardSurface: Bool) -> Animation? {
        active || keyboardSurface ? nil : hoverOut
    }
}

extension NSWindow {
    /// A status pill or popup leaving: it fades over `FrogMotion.fadeOut`, orders out, then runs `done`. Setting
    /// `alphaValue` back to 1 meanwhile ends the fade and keeps the window. Only for windows whose content stays as
    /// it was while fading.
    func fadeOut(then done: (() -> Void)? = nil) {
        guard isVisible else { done?(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FrogMotion.fadeOut
            context.timingFunction = FrogMotion.fadeOutCurve
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.alphaValue < 0.01 else { return }
            self.orderOut(nil)
            done?()
        }
    }
}

private struct FrogKeyboardSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The command bar, clipboard history, window switcher and layout picker: opened and driven by keys many
    /// times a day, so nothing inside them animates.
    var frogKeyboardSurface: Bool {
        get { self[FrogKeyboardSurfaceKey.self] }
        set { self[FrogKeyboardSurfaceKey.self] = newValue }
    }
}
