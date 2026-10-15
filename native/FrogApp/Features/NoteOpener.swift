import AppKit

/// Where a saved note opens: in Obsidian when its folder is inside a vault and Obsidian is
/// installed, otherwise in the default app for Markdown.
enum NoteOpenTarget {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func decide(file: URL, vaultRoot: URL?, obsidianAvailable: Bool) -> URL {
        guard vaultRoot != nil, obsidianAvailable,
              let path = file.path.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "obsidian://open?path=\(path)") else { return file }
        return url
    }

    /// The nearest folder above the file that holds a `.obsidian` folder. The search ends at the
    /// home folder, or at `/` for a file outside it.
    static func vaultRoot(for file: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let homePath = home.standardizedFileURL.path
        var directory = file.deletingLastPathComponent().standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".obsidian").path, isDirectory: &isDirectory),
               isDirectory.boolValue { return directory }
            if directory.path == homePath || directory.path == "/" { return nil }
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
    }
}

@MainActor enum NoteOpener {
    static func open(_ file: URL) {
        let obsidian = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://")!) != nil
        let target = NoteOpenTarget.decide(file: file, vaultRoot: NoteOpenTarget.vaultRoot(for: file), obsidianAvailable: obsidian)
        NSWorkspace.shared.open(target)
    }
}
