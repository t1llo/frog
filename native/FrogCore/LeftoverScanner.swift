import Foundation
import Darwin

/// The few file-system calls the scanner makes, so tests can watch and fail them.
public struct CleanerFileSystem: Sendable {
    /// Entry names, no "." or "..".
    public var contents: @Sendable (URL) throws -> [String]
    /// lstat succeeds.
    public var exists: @Sendable (URL) -> Bool
    /// lstat says S_IFDIR; links are not directories.
    public var isDirectory: @Sendable (URL) -> Bool
    public var owner: @Sendable (URL) -> CleanerOwner

    public init(contents: @escaping @Sendable (URL) throws -> [String], exists: @escaping @Sendable (URL) -> Bool,
                isDirectory: @escaping @Sendable (URL) -> Bool, owner: @escaping @Sendable (URL) -> CleanerOwner) {
        self.contents = contents
        self.exists = exists
        self.isDirectory = isDirectory
        self.owner = owner
    }

    public static let live = CleanerFileSystem(
        contents: { try FileManager.default.contentsOfDirectory(atPath: $0.path) },
        exists: { url in
            var info = stat()
            return lstat(url.path, &info) == 0
        },
        isDirectory: { url in
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        },
        owner: AppBundleInspector.fileOwner)
}

/// Finds an app's bundle and its leftovers in the Library folders. It lists folder names and reads only launchd
/// property lists; containers and group containers are probed by exact name and never listed, so a scan does
/// not trigger the "access data from other apps" prompt.
public struct LeftoverScanner: Sendable {
    public static let maximumItems = 500
    private static let ignoredNames: Set<String> = [".DS_Store", ".localized"]
    private static let checkEvery = 200

    private let roots: CleanerRoots
    private let safety: CleanerSafety
    private let fileSystem: CleanerFileSystem
    private let hasFullDiskAccess: Bool

    public init(roots: CleanerRoots, safety: CleanerSafety, fileSystem: CleanerFileSystem = .live,
                hasFullDiskAccess: Bool = true) {
        self.roots = roots
        self.safety = safety
        self.fileSystem = fileSystem
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    /// The app bundle first, then leftovers by confidence (certain, likely, possible) and path.
    /// Throws CancellationError when the task is cancelled. At most 500 items.
    public func scan(app: AppIdentity, otherApps: [AppIdentity]) throws -> [CleanerItem] {
        let bundle = roots.resolved(app.url)
        if let refusal = safety.refusal(for: bundle, purpose: .application) { throw FrogError.message(refusal) }
        let matcher = LeftoverMatcher(app: app, otherApps: otherApps)
        var found: [String: CleanerItem] = [:]

        // URLs here are built from the resolved roots; CleanerItem standardizes its own copy.
        func add(_ url: URL, _ location: LeftoverLocation, _ match: LeftoverMatcher.Match, launchLabel: String? = nil) {
            if let existing = found[url.path], existing.confidence >= match.confidence { return }
            guard safety.refusal(for: url, purpose: .leftover) == nil else { return }
            var kind = location.itemKind
            if kind == .folder, !fileSystem.isDirectory(url) { kind = .file }
            found[url.path] = CleanerItem(
                url: url, kind: kind, confidence: match.confidence, reason: match.reason, owner: fileSystem.owner(url),
                sharedWith: match.sharedWith, needsFullDiskAccess: location.needsFullDiskAccess && !hasFullDiskAccess,
                launchLabel: launchLabel)
        }

        for location in LeftoverLocation.allCases where !location.probesOnly {
            for domain in location.domains {
                guard let folder = roots.folder(location, domain) else { continue }
                try Task.checkCancellation()
                // A folder macOS keeps closed, such as Cookies without Full Disk Access, is skipped.
                guard let names = try? fileSystem.contents(folder) else { continue }
                for (index, name) in names.enumerated() where !Self.ignoredNames.contains(name) {
                    if index > 0, index.isMultiple(of: Self.checkEvery) { try Task.checkCancellation() }
                    let url = folder.appendingPathComponent(name)
                    if location == .launchAgents || location == .launchDaemons {
                        guard url.pathExtension.lowercased() == "plist", let plist = LaunchPlist.read(url),
                              let match = matcher.match(launchPlist: plist) else { continue }
                        add(url, location, match, launchLabel: plist.label)
                        continue
                    }
                    if let match = matcher.match(name: name, location: location) { add(url, location, match) }
                    if location == .applicationSupport || location == .caches,
                       let match = matcher.matchVendorFolder(name: name) {
                        add(url, location, match)
                        try scanVendorFolder(url, location: location, matcher: matcher, add: add)
                    }
                }
            }
        }

        let probes: [(LeftoverLocation, [String])] = [(.containers, app.bundleIDs), (.groupContainers, app.appGroups)]
        for (location, names) in probes {
            guard let folder = roots.folder(location, .user) else { continue }
            for name in names where !name.isEmpty && !name.contains("/") {
                try Task.checkCancellation()
                let url = folder.appendingPathComponent(name, isDirectory: true)
                guard fileSystem.exists(url), let match = matcher.match(name: name, location: location) else { continue }
                add(url, location, match)
            }
        }

        found.removeValue(forKey: bundle.path)
        let leftovers = found.values.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.url.path < $1.url.path
        }
        let item = CleanerItem(url: bundle, kind: .application, confidence: .certain, reason: "The app itself.",
                               owner: app.owner)
        return [item] + leftovers.prefix(Self.maximumItems - 1)
    }

    /// Folders named exactly after the app one level inside the developer's folder.
    private func scanVendorFolder(_ vendor: URL, location: LeftoverLocation, matcher: LeftoverMatcher,
                                  add: (URL, LeftoverLocation, LeftoverMatcher.Match, String?) -> Void) throws {
        guard fileSystem.isDirectory(vendor) else { return }
        try Task.checkCancellation()
        guard let names = try? fileSystem.contents(vendor) else { return }
        for name in names where !Self.ignoredNames.contains(name) {
            guard let match = matcher.matchInsideVendor(name: name, vendorFolder: vendor.lastPathComponent) else { continue }
            add(vendor.appendingPathComponent(name), location, match, nil)
        }
    }
}
