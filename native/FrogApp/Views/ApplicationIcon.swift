import AppKit
import SwiftUI

/// Icons are requested only for mounted rows and reused when rows or tabs are revisited.
struct ApplicationIcon: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() }
            else { Image(systemName: "app").resizable().foregroundStyle(FrogStyle.muted) }
        }.frame(width: 28, height: 28)
            .task(id: path) {
                guard !Task.isCancelled else { return }
                image = ApplicationIconCache.shared.image(for: path)
            }
            .accessibilityHidden(true)
    }
}

@MainActor
private final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let images = NSCache<NSString, NSImage>()
    private init() { images.countLimit = 256 }
    func image(for path: String) -> NSImage {
        let key = path as NSString
        if let image = images.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        images.setObject(image, forKey: key)
        return image
    }
}
