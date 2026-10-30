import AppKit

/// The app icons of the switcher's rows. Each is drawn once into a small bitmap at row size, so an
/// icon costs `bytesPerIcon` however large the app's icon file is, and at most `limit` are kept: the
/// least recently listed app goes first. Loaded off the main thread, on first need.
@MainActor final class WindowSwitcherIcons {
    /// 20 points at 2x.
    nonisolated static let pixels = 40
    nonisolated static let bytesPerIcon = pixels * pixels * 4

    let limit: Int
    private(set) var images: [pid_t: NSImage] = [:]
    /// Least recently listed first.
    private var order: [pid_t] = []
    private var loading: Task<Void, Never>?
    private let load: @Sendable (pid_t) -> NSImage?

    init(limit: Int = 64, load: @escaping @Sendable (pid_t) -> NSImage? = { NSRunningApplication(processIdentifier: $0)?.icon }) {
        self.limit = limit
        self.load = load
    }

    /// What the cache holds now, in bytes of bitmap.
    var byteCount: Int { images.count * Self.bytesPerIcon }

    /// Loads the icons of `pids` that are missing and calls `loaded` once they are in. Icons of apps no
    /// longer listed stay until the limit pushes them out, so an app that comes back needs no new load.
    func request(_ pids: [pid_t], loaded: @escaping @MainActor ([pid_t: NSImage]) -> Void) {
        touch(pids)
        let missing = pids.filter { images[$0] == nil }
        guard !missing.isEmpty else { return }
        loading?.cancel()
        let load = load
        loading = Task { [weak self] in
            let task = Task.detached(priority: .utility) { () -> [pid_t: NSImage] in
                var icons: [pid_t: NSImage] = [:]
                for pid in missing {
                    guard !Task.isCancelled else { break }
                    if let icon = load(pid).flatMap(Self.rasterize) { icons[pid] = icon }
                }
                return icons
            }
            let icons = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.insert(icons, listed: missing)
            loaded(self.images)
        }
    }

    /// Adds loaded icons, as recent in the order the apps were listed, then drops the oldest past the limit.
    private func insert(_ icons: [pid_t: NSImage], listed: [pid_t]) {
        for (pid, icon) in icons { images[pid] = icon }
        touch(listed.filter { icons[$0] != nil })
        while images.count > limit, let oldest = order.first {
            order.removeFirst(); images[oldest] = nil
        }
    }

    func clear() {
        loading?.cancel(); loading = nil
        images = [:]; order = []
    }

    /// Moves the held icons of `pids` to the recent end, in the order given.
    private func touch(_ pids: [pid_t]) {
        let listed = Set(pids)
        order.removeAll { listed.contains($0) }
        var seen = Set<pid_t>()
        order += pids.filter { images[$0] != nil && seen.insert($0).inserted }
    }

    /// The icon drawn once into a `pixels`-square bitmap, which also resolves its lazy representations here
    /// rather than while SwiftUI draws the row.
    nonisolated static func rasterize(_ image: NSImage) -> NSImage? {
        guard image.isValid,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: pixels / 2, height: pixels / 2)
        let icon = NSImage(size: bitmap.size)
        icon.addRepresentation(bitmap)
        return icon
    }
}
