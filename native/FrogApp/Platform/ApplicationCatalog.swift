import Foundation
import FrogCore

enum ApplicationCatalog {
    static func scan(roots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
    ]) -> [Rule] {
        let manager = FileManager.default
        var seen = Set<String>()
        var rules: [Rule] = []
        for root in roots {
            guard let contents = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in contents {
                guard url.pathExtension.lowercased() == "app" else { continue }
                contents.skipDescendants()
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
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
