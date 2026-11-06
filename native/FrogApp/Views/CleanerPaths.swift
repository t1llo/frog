import Foundation
import FrogCore

extension CleanerRoots {
    /// "~/Library/Caches" in home and "/Applications" below the system root, whatever folder the system root
    /// stands for, so a path never shows its temporary or `/private` spelling.
    func shownPath(_ url: URL) -> String {
        let path = resolved(url).path
        if path == home.path || Self.below(path, home.path) != nil { return displayPath(url) }
        if let relative = Self.below(path, system.path) { return "/" + relative }
        return displayPath(url)
    }

    /// An item's own name and the folder it sits in, read on two lines rather than one path cut mid-word.
    func shownParts(_ url: URL) -> (name: String, folder: String) {
        let full = shownPath(url)
        guard let slash = full.lastIndex(of: "/"), full != "/", full != "~" else { return (full, "") }
        let folder = String(full[..<slash])
        return (String(full[full.index(after: slash)...]), folder.isEmpty ? "/" : folder)
    }

    private static func below(_ path: String, _ root: String) -> String? {
                let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
