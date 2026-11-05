import CoreGraphics
import Foundation

/// Where the "Drag Frog into the list" helper goes, and what it hands over. Pure geometry and paths, so it is
/// tested without a screen. Rects are in AppKit coordinates (origin at the bottom left) unless named `quartz`.
public enum PermissionHelperPlacement {
    /// Space between the helper and the System Settings window.
    public static let gap: CGFloat = 8
    /// How far above the bottom edge the helper sits when it has to overlap the window or the screen.
    public static let inset: CGFloat = 20

    /// A window rect from `CGWindowListCopyWindowInfo` (origin at the top left of the main display) in AppKit space.
    public static func appKitRect(fromQuartz rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Centred under the System Settings window when the screen has room below it; otherwise centred inside the
    /// window's bottom edge. Without a window, at the bottom centre of the screen. Always kept on the screen.
    public static func frame(panel: CGSize, settingsWindow: CGRect?, screen: CGRect) -> CGRect {
        var origin: CGPoint
        if let window = settingsWindow {
            let x = window.midX - panel.width / 2
            let below = window.minY - gap - panel.height
            origin = CGPoint(x: x, y: below >= screen.minY ? below : window.minY + inset)
        } else {
            origin = CGPoint(x: screen.midX - panel.width / 2, y: screen.minY + inset + 4)
        }
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - panel.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - panel.height))
        return CGRect(origin: origin, size: panel)
    }

    /// What dragging the icon provides: the app bundle, or the bare executable when running unbundled
    /// (`.build/release/Frog`), which the privacy lists also accept.
    public static func dragURL(bundleURL: URL, executableURL: URL?) -> (url: URL, isBundle: Bool) {
        if bundleURL.pathExtension == "app" { return (bundleURL, true) }
        return (executableURL ?? bundleURL, false)
    }
}
