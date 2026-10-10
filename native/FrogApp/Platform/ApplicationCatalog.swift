import Foundation
import Combine
import FrogCore

enum ApplicationCatalog {
    static func scan(roots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
    ]) -> [Rule] {
        let manager = FileManager.default
        var seen = Set<String>()
        var rules: [Rule] = []
        for root in roots {
            guard let contents = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            // Include app links before recursive discovery. Safari's hidden link
            // is covered by the system Cryptex Applications root above.
            let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            let urls = children + contents.compactMap { $0 as? URL }
            for url in urls {
                guard url.pathExtension.lowercased() == "app" else { continue }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(path).inserted, let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
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
        return rules.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    private let discover: @Sendable () async -> [Rule]
    private var loading: Task<[Rule], Never>?
    private var scannedAt: ContinuousClock.Instant?
    private var cachedConfiguration: [Rule]?
    private var cachedRows: [Rule] = []

    init(discover: @escaping @Sendable () async -> [Rule] = {
        await Task.detached(priority: .utility) { ApplicationCatalog.scan() }.value
    }) { self.discover = discover }

    func loadIfNeeded() async {
        if let scannedAt, scannedAt.duration(to: .now) < .seconds(60) { return }
        if let loading { _ = await loading.value; return }
        let discover = self.discover
        let task = Task { await discover() }
        loading = task
        let discovered = await task.value
        let previousIDs = Dictionary(uniqueKeysWithValues: installed.compactMap { rule in
            rule.action?.applicationPath.map { ($0, rule.id) }
        })
        let refreshed = discovered.map { rule in
            var rule = rule
            if let path = rule.action?.applicationPath, let id = previousIDs[path] { rule.id = id }
            return rule
        }
        if refreshed != installed {
            cachedConfiguration = nil
            installed = refreshed
        }
        scannedAt = .now; loading = nil
    }

    func rows(configured: [Rule]) -> [Rule] {
        if cachedConfiguration == configured { return cachedRows }
        cachedRows = ApplicationCatalog.rows(installed: installed, configured: configured)
        cachedConfiguration = configured
        return cachedRows
    }
}
