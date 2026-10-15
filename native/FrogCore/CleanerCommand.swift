import Foundation

/// What the command bar needs to offer "Uninstall <App>": the typed verb, the row's id, and which apps may have a row.
public enum CleanerCommand {
    private static let verbs = ["uninstall", "remove"]
    private static let prefix = "uninstall:"

    /// "uninstall slack" or "remove slack" (any case, extra spaces allowed) → "slack".
    /// A bare "uninstall" or "remove", or anything else → nil.
    public static func appQuery(_ query: String) -> String? {
        let text = query.drop(while: \.isWhitespace)
        for verb in verbs {
            let rest = text.dropFirst(verb.count)
            guard text.prefix(verb.count).lowercased() == verb, rest.first?.isWhitespace == true else { continue }
            let term = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            // One letter would list every app that contains it.
            return term.count >= 2 ? term : nil
        }
        return nil
    }

    /// The id of a row: "uninstall:<path>", and back.
    public static func rowID(path: String) -> String { prefix + path }

    public static func path(fromRowID id: String) -> String? {
        guard id.hasPrefix(prefix), id.count > prefix.count else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    /// Whether the bar may offer "Uninstall" for this app: the same rules as the page's app list.
    /// False for a path outside `applicationFolders` (up to three folders deep, so Finder in
    /// /System/Library/CoreServices and apps in /System/Applications get no row), for an Apple bundle
    /// ID (`CleanerSafety.isAppleName`), and for Frog's own bundle.
    public static func offers(path: String, bundleID: String?, ownBundlePath: String,
                              applicationFolders: [URL]) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.lowercased().hasSuffix(".app"),
              path != URL(fileURLWithPath: ownBundlePath).standardizedFileURL.path else { return false }
        if let bundleID, CleanerSafety.isAppleName(bundleID) { return false }
        return applicationFolders.contains { folder in
            guard let relative = CleanerRoots.relative(path, below: folder.standardizedFileURL.path) else { return false }
            let components = relative.split(separator: "/")
            // As on the page: suites nest their apps up to three folders deep; an app inside an app is part of it.
            return components.count <= 4 && !components.dropLast().contains { $0.lowercased().hasSuffix(".app") }
        }
    }
}
