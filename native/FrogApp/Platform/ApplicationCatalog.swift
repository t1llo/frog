import Foundation
import Combine
import FrogCore

enum ApplicationCatalog {
    /// What a scan finds: the applications under the name Finder shows and, by application path, the bundle and
    /// file names that differ from it. Search matches those as well.
    struct Discovery: Sendable {
        var rules: [Rule] = []
        var alternativeNames: [String: [String]] = [:]
    }
    static func scan(roots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
    ]) -> Discovery {
        let manager = FileManager.default
        var seen = Set<String>()
        var rules: [Rule] = []
        var alternativeNames: [String: [String]] = [:]
        for root in roots {
            guard let contents = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            // Include app links before recursive discovery. Safari's hidden link
            // is covered by the system Cryptex Applications root above.
            let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            var urls = children
            while let item = contents.nextObject() {
                // Suites nest their apps up to three folders deep. Below that are documents and helpers, by the thousand.
                if contents.level > 3 { contents.skipDescendants() }
                if let url = item as? URL { urls.append(url) }
            }
            for url in urls {
                guard url.pathExtension.lowercased() == "app" else { continue }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(path).inserted, let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
                // Finder appends the extension when it is set to show all of them.
                let shown = manager.displayName(atPath: path)
                let name = shown.lowercased().hasSuffix(".app") ? String(shown.dropLast(4)) : shown
                var listed: Set = [name]
                let others = (["CFBundleDisplayName", "CFBundleName"].compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
                    + [url.deletingPathExtension().lastPathComponent]).filter { !$0.isEmpty && listed.insert($0).inserted }
                if !others.isEmpty { alternativeNames[path] = others }
                var rule = Rule(name: name, instructions: "", enabled: false)
                var action = RuleAction(); action.category = .application; action.applicationPath = path
                action.applicationBundleID = bundleID
                rule.action = action; rules.append(rule)
            }
        }
        // Finder lives outside the normal Applications directories.
        if roots.contains(where: { $0.path == "/System/Applications" }),
           manager.fileExists(atPath: "/System/Library/CoreServices/Finder.app") {
            var rule = Rule(name: "Finder", instructions: "", enabled: false)
            var action = RuleAction(); action.category = .application; action.applicationPath = "/System/Library/CoreServices/Finder.app"
            action.applicationBundleID = "com.apple.finder"
            rule.action = action; rules.append(rule)
        }
        return Discovery(rules: rules.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, alternativeNames: alternativeNames)
    }

    static func rows(installed: [Rule], configured: [Rule]) -> [Rule] {
        let configured = configured.filter { $0.category == .application }
        let paths = Set(configured.compactMap { $0.action?.applicationPath }.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        })
        return (configured + installed.filter { !paths.contains($0.action?.applicationPath ?? "") })
            .sorted {
                if ($0.hotkey != nil) != ($1.hotkey != nil) { return $0.hotkey != nil }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

/// Shared across tab visits; discovery runs off the main thread and coalesces concurrent requests.
@MainActor
final class ApplicationCatalogStore: ObservableObject {
    static let shared = ApplicationCatalogStore()
    @Published private(set) var installed: [Rule] = []
    /// By application path, as the last scan found them.
    private(set) var alternativeNames: [String: [String]] = [:]
    private let discover: @Sendable () async -> ApplicationCatalog.Discovery
    private var loading: Task<[Rule], Never>?
    private var scannedAt: ContinuousClock.Instant?
    private var cachedConfiguration: [Rule]?
    private var cachedRows: [Rule] = []

    init(discover: @escaping @Sendable () async -> ApplicationCatalog.Discovery = {
        await Task.detached(priority: .utility) { ApplicationCatalog.scan() }.value
    }) { self.discover = discover }

    func loadIfNeeded() async { await load() }
    /// The installed applications, scanned again when the last scan is older than a minute. Callers that arrive
    /// during a scan share it. The scan stores what it found before any of them goes on, so none reads the list
    /// of the scan before.
    @discardableResult func load() async -> [Rule] {
        if let scannedAt, scannedAt.duration(to: .now) < .seconds(60) { return installed }
        if let loading { return await loading.value }
        let discover = self.discover
        let task = Task {
            let discovered = await discover()
            let previousIDs = Dictionary(uniqueKeysWithValues: installed.compactMap { rule in
                rule.action?.applicationPath.map { ($0, rule.id) }
            })
            let refreshed = discovered.rules.map { rule in
                var rule = rule
                if let path = rule.action?.applicationPath, let id = previousIDs[path] { rule.id = id }
                return rule
            }
            alternativeNames = discovered.alternativeNames
            if refreshed != installed {
                cachedConfiguration = nil
                installed = refreshed
            }
            scannedAt = .now; loading = nil
            return installed
        }
        loading = task
        return await task.value
    }

    func rows(configured: [Rule]) -> [Rule] {
        if cachedConfiguration == configured { return cachedRows }
        cachedRows = ApplicationCatalog.rows(installed: installed, configured: configured)
        cachedConfiguration = configured
        return cachedRows
    }
}
