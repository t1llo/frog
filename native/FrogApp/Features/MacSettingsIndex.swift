import AppKit
import FrogCore

/// A single process-lifetime background scan, shared by warming and visible presentations.
actor MacSettingsIndex {
    static let shared = MacSettingsIndex()
    private let discover: @Sendable () -> [SystemSetting]
    private var pending: Task<[SystemSetting], Never>?

    init(discover: @escaping @Sendable () -> [SystemSetting] = { MacSettingsDiscovery.scan() }) {
        self.discover = discover
    }

    func load() async -> [SystemSetting] {
        if let pending { return await pending.value }
        let discover = discover
        let task = Task.detached(priority: .utility) { discover() }
        pending = task
        return await task.value
    }
}

enum MacSettingsDiscovery {
    static func scan(root: URL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions"),
                     legacyRoot: URL = URL(fileURLWithPath: "/System/Library/PreferencePanes"),
                     languages: [String] = Locale.preferredLanguages) -> [SystemSetting] {
        var destinations = SystemSettingsCatalog.defaults
        var positions: [String: Int] = [:]
        for (index, entry) in destinations.enumerated() where entry.anchor == nil { positions[entry.paneID] = index }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for url in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url), let info = bundle.infoDictionary,
                  let attributes = (info["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"] as? [String: Any],
                  attributes["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
                  let identifier = bundle.bundleIdentifier, identifier.hasPrefix("com.apple."),
                  identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }) else { continue }
            let title = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            var terms = searchTerms(bundle: bundle, languages: languages)
            if let legacy = attributes["legacyPrefPaneBundleName"] as? String,
               legacy == (legacy as NSString).lastPathComponent,
               let legacyBundle = Bundle(url: legacyRoot.appendingPathComponent(legacy)) {
                terms += " " + searchTerms(bundle: legacyBundle, languages: languages)
            }
            if let index = positions[identifier] {
                destinations[index] = destinations[index].includingSearchTerms(terms, localizedTitle: title)
            } else {
                positions[identifier] = destinations.count
                destinations.append(SystemSetting(paneID: identifier, title: title, keywords: terms))
            }
        }
        return destinations
    }

    private static func searchTerms(bundle: Bundle, languages: [String]) -> String {
        guard let resources = bundle.resourceURL else { return "" }
        let preferred = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages)
        var visited = Set<String>(), words: [String] = []
        for language in preferred + ["en"] where visited.insert(language).inserted {
            let directory = resources.appendingPathComponent(language + ".lproj")
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "searchTerms" {
                guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= 512_000,
                      let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                words.append(contentsOf: searchWords(plist))
                if words.count >= 256 { return words.prefix(256).joined(separator: " ") }
            }
        }
        return words.prefix(256).joined(separator: " ")
    }

    /// Apple ships nested search-term groups; read only user-facing titles/indexes.
    static func searchWords(_ plist: Any) -> [String] {
        var words: [String] = [], seen = Set<String>(), remaining = 4096
        func visit(_ value: Any, depth: Int) {
            guard remaining > 0, depth < 12, words.count < 256 else { return }
            remaining -= 1
            if let dictionary = value as? [String: Any] {
                for key in dictionary.keys.sorted() {
                    if ["title", "index"].contains(key), let text = dictionary[key] as? String {
                        for word in text.split(separator: ",") {
                            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty, clean.count <= 96, words.count < 256, seen.insert(clean.lowercased()).inserted { words.append(clean) }
                        }
                    } else if let child = dictionary[key] { visit(child, depth: depth + 1) }
                }
            } else if let array = value as? [Any] { for child in array { visit(child, depth: depth + 1) } }
        }
        visit(plist, depth: 0)
        return words
    }
}

@MainActor enum MacSettingsNavigation {
    static func open(_ setting: SystemSetting, using open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) throws {
        for url in setting.destinations where open(url) { return }
        guard open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) else {
            throw FrogError.message("Could not open System Settings.")
        }
    }
}
