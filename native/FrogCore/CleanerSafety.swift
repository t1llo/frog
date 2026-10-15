import Foundation
import Darwin

/// The rules that decide which paths the cleaner may ever offer. Every scanner and the remover ask it, so a
/// path Frog must never touch is refused in one place, whatever found it.
public struct CleanerSafety: Sendable {
    public enum Purpose: Sendable { case application, leftover, junk, disk }

    public let roots: CleanerRoots
    private let protectedPaths: [String]
    private let fileFlags: @Sendable (URL) -> UInt32?

    /// `protectedPaths` are Frog's own app bundle, data folder and configuration folder.
    public init(roots: CleanerRoots, protectedPaths: [URL] = [],
                fileFlags: @escaping @Sendable (URL) -> UInt32? = CleanerSafety.lstatFlags) {
        self.roots = roots
        self.fileFlags = fileFlags
        // Both spellings, so a protected folder reached through a link is still protected.
        self.protectedPaths = Array(Set(protectedPaths.flatMap { url -> [String] in
            let given = roots.resolved(url).path
            guard let pointer = realpath(given, nil) else { return [given] }
            defer { free(pointer) }
            return [given, String(cString: pointer)]
        }))
    }

    /// lstat's `st_flags`, or nil when the item is missing.
    public static let lstatFlags: @Sendable (URL) -> UInt32? = { url in
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_flags
    }

    /// True for a single path component that belongs to Apple. OrphanFinder, JunkScanner and StartupItemLister
    /// use the same function, so there is one Apple rule in the cleaner. Apple's team-prefixed group containers
    /// (`<TEAM>.groups.com.apple.podcasts`) contain `com.apple.` too, so no list of team IDs is needed.
    public static func isAppleName(_ component: String) -> Bool {
        let name = component.lowercased()
        return name.contains("com.apple.") || name.hasPrefix("group.is.workflow.") || name.hasPrefix("is.workflow.")
    }

    /// Folders directly inside a Library or leftover location that macOS itself keeps.
    public static let appleOwnedNames: Set<String> = [
        "AddressBook", "Animoji", "AppStore", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "CloudKit",
        "CrashReporter", "Dock", "FamilyCircle", "FileProvider", "GeoServices", "iCloud", "Knowledge", "Metadata",
        "MobileSync", "PassKit", "SiriTTS", "SyncServices", "Ubiquity"
    ]
    private static let appleOwnedLowercased = Set(appleOwnedNames.map { $0.lowercased() })

    private static let invalidPath = "Frog cannot use this path."
    private static let inTrash = "This item is already in the Trash."
    private static let frogsOwn = "Frog never moves its own files."
    private static let apples = "Frog never moves Apple's own files."
    private static let synced = "Frog never moves iCloud or synced folders."
    private static let personalData = "Frog never moves mail, messages, Safari, Photos or keychain data."
    private static let wholeLibrary = "Frog never moves a whole Library folder."
    private static let throughLink = "This path goes through a link, so Frog cannot be sure where it points."
    private static let restricted = "macOS protects this item."
    private static let outside = "This item is outside the folders Frog cleans."

    /// `SF_RESTRICTED` from sys/stat.h: System Integrity Protection guards the item.
    private static let restrictedFlag: UInt32 = 0x0008_0000

    /// nil when Frog may offer the item for the purpose; otherwise the sentence shown to the user.
    public func refusal(for url: URL, purpose: Purpose) -> String? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { return Self.invalidPath }
        let item = roots.resolved(url)
        let path = item.path
        guard !item.pathComponents.contains("..") else { return Self.invalidPath }

        let home = roots.home.path, system = roots.system.path
        if CleanerRoots.isInside(path, roots.home.appendingPathComponent(".Trash").path, orEqual: true) { return Self.inTrash }
        if protectedPaths.contains(where: { CleanerRoots.isInside(path, $0, orEqual: true) }) { return Self.frogsOwn }

        // The deepest root the item lies in: home is inside `/` in the app.
        let root = CleanerRoots.isInside(path, home, orEqual: true) ? home
            : CleanerRoots.isInside(path, system, orEqual: true) ? system : nil
        if isApple(path, root: root) { return Self.apples }

        let userLibrary = roots.userLibrary.path
        if ["Mobile Documents", "CloudStorage"].contains(where: {
            CleanerRoots.isInside(path, userLibrary + "/" + $0, orEqual: true)
        }) { return Self.synced }
        let personal = ["Keychains", "Mail", "Messages", "Safari", "Daemon Containers", "Photos"].map { userLibrary + "/" + $0 }
            + [roots.systemLibrary.path + "/Keychains"]
        if personal.contains(where: { CleanerRoots.isInside(path, $0, orEqual: true) })
            || item.pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) {
            return Self.personalData
        }

        if wholeFolders.contains(path) { return Self.wholeLibrary }
        if let root, goesThroughLink(path, root: root) { return Self.throughLink }
        if let flags = fileFlags(item), flags & Self.restrictedFlag != 0 { return Self.restricted }
        return isInScope(path, purpose: purpose) ? nil : Self.outside
    }

    private func isApple(_ path: String, root: String?) -> Bool {
        let system = roots.system.path
        if root == system {
            let guarded = ["System", "usr", "bin", "sbin", "private", "Library/Apple"].map {
                roots.system.appendingPathComponent($0).path
            }
            if guarded.contains(where: { CleanerRoots.isInside(path, $0, orEqual: true) }) { return true }
        }
        if let root, let relative = CleanerRoots.relative(path, below: root),
           relative.split(separator: "/").contains(where: { Self.isAppleName(String($0)) }) {
            return true
        }
        // Apple's own folders directly inside a Library or one of its leftover locations.
        let parents = [roots.userLibrary, roots.systemLibrary] + locationFolders
        return parents.contains { parent in
            guard let relative = CleanerRoots.relative(path, below: parent.path),
                  let first = relative.split(separator: "/").first else { return false }
            return Self.appleOwnedLowercased.contains(first.lowercased())
        }
    }

    private var locationFolders: [URL] {
        LeftoverLocation.allCases.flatMap { location in location.domains.compactMap { roots.folder(location, $0) } }
    }

    /// The roots, the Library folders and every leftover location folder itself.
    private var wholeFolders: Set<String> {
        Set([roots.home, roots.system, roots.userLibrary, roots.systemLibrary].map(\.path) + locationFolders.map(\.path))
    }

    /// Checks every parent between the root and the item, from the root down. The item itself may be a link:
    /// it moves as a link. Components above the root were resolved once by realpath.
    private func goesThroughLink(_ path: String, root: String) -> Bool {
        guard let relative = CleanerRoots.relative(path, below: root) else { return false }
        var parent = root
        for component in relative.split(separator: "/").dropLast() {
            parent = parent == "/" ? "/" + component : parent + "/" + component
            var info = stat()
            guard lstat(parent, &info) == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    private func isInScope(_ path: String, purpose: Purpose) -> Bool {
        switch purpose {
        case .application:
            guard path.lowercased().hasSuffix(".app") else { return false }
            return roots.applicationFolders.contains { folder in
                guard let relative = CleanerRoots.relative(path, below: folder.path) else { return false }
                let components = relative.split(separator: "/")
                // Suites nest their apps up to three folders deep; an app inside another app is part of it.
                return components.count <= 4 && !components.dropLast().contains { $0.lowercased().hasSuffix(".app") }
            }
        case .leftover:
            return locationFolders.contains { CleanerRoots.relative(path, below: $0.path) != nil }
        case .junk, .disk:
            return CleanerRoots.relative(path, below: roots.home.path) != nil
        }
    }
}
