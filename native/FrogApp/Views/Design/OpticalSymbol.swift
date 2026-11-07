import AppKit
import SwiftUI

/// An SF Symbol centred by its ink, not its layout box. Many symbols carry uneven room in their box (an arrow
/// leaning up and right, a refresh arrow's head, a cup with its saucer), and SwiftUI rounds an odd-sized box to
/// pixels, so centring the box leaves the drawing a pixel off in a square button or tile, most visibly at 1×.
/// This measures the symbol's ink once per symbol, size and weight, and draws it on an even-sized square with the
/// ink on its centre, so a tile or button of an even size centres it on whole pixels.
struct OpticalSymbol: View {
    let name: String
    let size: CGFloat
    var weight: NSFont.Weight = .medium

    var body: some View {
        Image(nsImage: Self.image(name, size: size, weight: weight)).renderingMode(.template)
            .accessibilityHidden(true)
    }

    private struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
    }
    @MainActor private static var images: [Key: NSImage] = [:]
    @MainActor private static var offsets: [Key: CGSize] = [:]

    /// The symbol drawn on a square canvas of an even number of points with its ink on the canvas's centre, so a
    /// tile or button of an even size centres it on whole pixels at 1× and 2× alike. A template image: it takes
    /// the view's foreground style.
    @MainActor static func image(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        let key = Key(name: name, size: size, weight: weight.rawValue)
        if let image = images[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let ink = inkCentre(of: symbol)
        let side = (max(symbol.size.width, symbol.size.height) / 2).rounded(.up) * 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            symbol.draw(in: NSRect(x: side / 2 - ink.x, y: side / 2 - ink.y,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        if images.count > 512 { images.removeAll() }
        images[key] = image
        return image
    }

    /// How far to move the symbol from its layout box's centre so the centre of its ink lands there, for a
    /// symbol drawn by hand (the Stay awake menu-bar icon). Positive moves right and down.
    @MainActor static func offset(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGSize {
        let key = Key(name: name, size: size, weight: weight.rawValue)
        if let offset = offsets[key] { return offset }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .zero }
        let ink = inkCentre(of: symbol)
        let offset = CGSize(width: symbol.size.width / 2 - ink.x, height: ink.y - symbol.size.height / 2)
        if offsets.count > 512 { offsets.removeAll() }
        offsets[key] = offset
        return offset
    }

    /// The centre of the symbol's ink in its own points, measured from the bottom left: drawn at 4× into a
    /// bitmap, the box of every pixel that is more than faintly covered.
    private static func inkCentre(of image: NSImage) -> CGPoint {
        let fallback = CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        let scale: CGFloat = 4
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              // An alpha-only context draws nothing for a symbol, so this is RGBA and only the alpha is read.
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return fallback }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return fallback }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in 0..<height {
            for column in 0..<width where data[(row * width + column) * 4 + 3] > 40 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return fallback }
        // The bitmap's first row is its top.
        let x = CGFloat(minX + maxX + 1) / 2 / scale
        let yFromTop = CGFloat(minY + maxY + 1) / 2 / scale
        return CGPoint(x: x, y: image.size.height - yFromTop)
    }
}

