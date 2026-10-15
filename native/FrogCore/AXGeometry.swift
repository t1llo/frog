import CoreGraphics

/// Converts rectangles reported through Accessibility, whose origin is the top left of the primary display.
public enum AXGeometry {
    /// Larger than any arrangement of displays; apps that report nonsense often report huge values.
    static let largestSide: CGFloat = 100_000

    /// The Cocoa rectangle (origin bottom left of the primary display) for an Accessibility rectangle, or nil when
    /// the app reported an empty, negative, non-finite or absurd size, or a place on no display. A caret's zero width
    /// is kept, since apps report an insertion point that way.
    public static func cocoaRect(_ axRect: CGRect, primaryHeight: CGFloat, screens: [CGRect]) -> CGRect? {
        let values = [axRect.origin.x, axRect.origin.y, axRect.size.width, axRect.size.height, primaryHeight]
        guard values.allSatisfy(\.isFinite) else { return nil }
        // CGRect.width and height standardize negative sizes away, so read the stored size.
        let width = axRect.size.width, height = axRect.size.height
        guard width >= 0, height > 0, width <= largestSide, height <= largestSide else { return nil }
        let rect = CGRect(x: axRect.origin.x, y: primaryHeight - axRect.origin.y - height, width: width, height: height)
        // An empty rectangle intersects nothing, so a caret is tested with a width of one point.
        let probe = CGRect(x: rect.minX, y: rect.minY, width: max(width, 1), height: height)
        guard screens.contains(where: { $0.intersects(probe) }) else { return nil }
        return rect
    }
}
