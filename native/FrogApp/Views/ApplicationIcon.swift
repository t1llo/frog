import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Icons are requested only for mounted rows and reused when rows or tabs are revisited.
struct ApplicationIcon: View {
    let path: String
    var size: CGFloat = 28
    @State private var image: CGImage?
    private static let generic = NSWorkspace.shared.icon(for: .applicationBundle)

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 2).resizable() }
            // The system's generic app icon until the app's own is drawn, in both themes; an outlined
            // square here read as an empty checkbox.
            else { Image(nsImage: Self.generic).resizable() }
        }.frame(width: size, height: size)
            .task(id: path) {
                guard !Task.isCancelled else { return }
                let loaded = await ApplicationIconCache.shared.image(for: path)
                guard !Task.isCancelled else { return }
                image = loaded
            }
            .accessibilityHidden(true)
    }
}

private actor ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let images = NSCache<NSString, CGImage>()
    private init() { images.countLimit = 256 }
    func image(for path: String) -> CGImage? {
        let key = path as NSString
        if let image = images.object(forKey: key) { return image }
        // NSWorkspace icons defer IconServices work until drawing. Rasterize off the UI thread
        // so scrolling never has to resolve or decode a newly visible application's icon.
        // A bundle without a runnable executable (half-removed, or a stub) gets Finder's "prohibited"
        // badge; the generic app icon reads as an app instead of an error.
        // A symlinked app (Safari in /Applications points into the system's cryptex) would carry Finder's alias
        // arrow; the app it points to has its plain icon.
        let icon = Self.isLaunchable(path) ? NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 56,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: 56, height: 56))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    private static func isLaunchable(_ path: String) -> Bool {
        guard path.hasSuffix(".app") else { return true }
        // An iPhone or iPad app installed on the Mac keeps its bundle in a wrapper, with no executable at the top.
        if FileManager.default.fileExists(atPath: path + "/WrappedBundle") { return true }
        guard let executable = Bundle(path: path)?.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }
}
