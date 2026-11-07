import AppKit
import CoreServices

/// Puts every new macOS screenshot on the clipboard as soon as it is taken, so it can be pasted straight away
/// instead of dragged from the thumbnail.
///
/// macOS writes a screenshot twice: first to a temporary folder of `screencaptureui` while its thumbnail floats
/// in the corner, then to the save folder once the thumbnail goes away. Frog watches both, takes whichever comes
/// first and skips the second copy of the same name.
@MainActor final class ScreenshotClipboard: ObservableObject {
    struct Copied: Equatable {
        let name: String
        let time: Date
    }

    @Published private(set) var lastCopied: Copied?
    @Published private(set) var saveFolder: URL

    /// Called after each copy, for the clipboard history and a notice.
    var onCopy: ((Copied) -> Void)?

    private let pasteboard: NSPasteboard
    private let temporaryRoot: URL
    private let readSaveFolder: () -> URL
    private var stream: FSEventStreamRef?
    private var folderTimer: Timer?
    /// Names already copied, with when, so the temporary file and the saved one count once.
    private var seen: [String: Date] = [:]
    private let queue = DispatchQueue(label: "frog.screenshots", qos: .userInitiated)

    init(pasteboard: NSPasteboard = .general,
         temporaryRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
         saveFolder: @escaping () -> URL = ScreenshotClipboard.systemSaveFolder) {
        self.pasteboard = pasteboard
        self.temporaryRoot = temporaryRoot.resolvingSymlinksInPath()
        readSaveFolder = saveFolder
        self.saveFolder = saveFolder().resolvingSymlinksInPath()
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        saveFolder = readSaveFolder().resolvingSymlinksInPath()
        startStream()
        // macOS has no notice for a new save folder; looking once a minute is enough.
        folderTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSaveFolder() }
        }
    }

    func stop() {
        folderTimer?.invalidate(); folderTimer = nil
        stopStream()
    }

    private func followSaveFolder() {
        let folder = readSaveFolder().resolvingSymlinksInPath()
        guard folder != saveFolder else { return }
        saveFolder = folder
        stopStream(); startStream()
    }

    // MARK: Watching

    private func startStream() {
        let paths = Array(Set([temporaryRoot.path, saveFolder.path])) as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changed: [String] = []
            for index in 0..<min(count, list.count) {
                let flag = Int(flags[index])
                let created = flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemXattrMod) != 0
                if created, flag & kFSEventStreamEventFlagItemIsFile != 0 { changed.append(list[index]) }
            }
            guard !changed.isEmpty else { return }
            let watcher = Unmanaged<ScreenshotClipboard>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.handle(changed) } }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: Copying

    /// Looks at changed files and copies the screenshots among them. Internal for tests.
    func handle(_ paths: [String]) {
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard seen[name] == nil, isScreenshot(url, now: now) else { continue }
            seen[name] = now
            copy(url, attempt: 0)
        }
    }

    /// An image macOS's screenshot tool wrote just now: in its temporary folder, or in the save folder with the
    /// screen-capture mark macOS puts on every screenshot. Other images in the save folder are left alone.
    func isScreenshot(_ url: URL, now: Date = Date()) -> Bool {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix(".") else { return false }
        let path = url.resolvingSymlinksInPath().path
        let inTemporary = path.hasPrefix(temporaryRoot.path + "/") && path.contains("screencaptureui")
        let inSaveFolder = url.resolvingSymlinksInPath().deletingLastPathComponent().path == saveFolder.path
        guard inTemporary || (inSaveFolder && Self.hasScreenCaptureMark(url)) else { return false }
        // A screenshot is new; an old one that was renamed or touched is not.
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
        return now.timeIntervalSince(created) < 60
    }

    /// The file may still be being written when its event comes; a few short retries cover that.
    private func copy(_ url: URL, attempt: Int) {
        if let data = try? Data(contentsOf: url), !data.isEmpty, let image = NSImage(data: data), image.isValid {
            write(data, image: image, type: url.pathExtension.lowercased())
            let copied = Copied(name: url.deletingPathExtension().lastPathComponent, time: Date())
            lastCopied = copied
            onCopy?(copied)
            return
        }
        guard attempt < 10 else { seen[url.lastPathComponent] = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.copy(url, attempt: attempt + 1) }
        }
    }

    private func write(_ data: Data, image: NSImage, type: String) {
        let item = NSPasteboardItem()
        switch type {
        case "png": item.setData(data, forType: .png)
        case "jpg", "jpeg": item.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
        case "heic": item.setData(data, forType: NSPasteboard.PasteboardType("public.heic"))
        default: break
        }
        // Every app reads TIFF; PNG for those that prefer it when the screenshot was saved in another format.
        if type != "png", let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Copies the newest screenshot in the save folder again, for the command bar and agents.
    @discardableResult
    func copyLatest() -> Copied? {
        let files = (try? FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        let latest = files.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) && Self.hasScreenCaptureMark($0) }
            .max { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        guard let latest, let data = try? Data(contentsOf: latest), let image = NSImage(data: data) else { return nil }
        write(data, image: image, type: latest.pathExtension.lowercased())
        let copied = Copied(name: latest.deletingPathExtension().lastPathComponent, time: Date())
        lastCopied = copied
        onCopy?(copied)
        return copied
    }

    // MARK: macOS

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"]
    static let screenCaptureMark = "com.apple.metadata:kMDItemIsScreenCapture"

    static func hasScreenCaptureMark(_ url: URL) -> Bool {
        getxattr(url.path, screenCaptureMark, nil, 0, 0, 0) > 0
    }

    /// Where macOS saves screenshots: Screenshot's Options > Save to, the Desktop unless changed.
    nonisolated static func systemSaveFolder() -> URL {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        if let location = CFPreferencesCopyAppValue("location" as CFString, domain) as? String, !location.isEmpty {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Whether macOS also floats a thumbnail after each screenshot; Frog copies at once either way.
    nonisolated static var systemShowsThumbnail: Bool {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("show-thumbnail" as CFString, domain) as? Bool) ?? true
    }
}

private extension URL {
    var creationDate: Date? { try? resourceValues(forKeys: [.creationDateKey]).creationDate }
}
