import Foundation

public struct UtilityDocument: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case note, snippet, shelf, script }
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var text: String
    public var files: [URL]
    public var modified: Date
    public init(id: UUID = UUID(), kind: Kind, title: String, text: String = "", files: [URL] = [], modified: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.files = files; self.modified = modified
    }
}

/// User documents have their own private store, never part of portable settings.
public actor UtilityDocumentStore {
    /// What a `load` had to leave out of the list it returned.
    public struct Unreadable: Equatable, Sendable {
        /// Items this version of Frog could not read, out of `total` in the file.
        public let count: Int
        public let total: Int
        public let file: URL
        /// Where the file is kept as it was, before the first save replaces it.
        public let backup: URL
        public var message: String {
            "\(count) of \(total) items in \(file.shownPath) could not be read and \(count == 1 ? "is" : "are") not shown. Before Frog saves a change, it keeps that file as \(backup.lastPathComponent) in the same folder."
        }
    }
    public nonisolated let file: URL
    private var revision = -1
    /// Set by a `load` that could not read every item, nil after one that could.
    public private(set) var unreadable: Unreadable?
    /// The file as that `load` found it, until a save has kept it as `unreadable.backup`.
    private var unsavedOriginal: Data?
    public init(directory: URL) { file = directory.appendingPathComponent("toolkit-documents.json") }
    public func load() throws -> [UtilityDocument] {
        guard FileManager.default.fileExists(atPath: file.path) else { unreadable = nil; unsavedOriginal = nil; return [] }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { throw FrogError.message("\(file.shownPath) could not be read: \(error.localizedDescription)") }
        guard data.count <= 16 * 1024 * 1024 else { throw FrogError.message("The local document store at \(file.shownPath) exceeds 16 MB.") }
        // One item this version cannot read, such as a kind a later version added, must not hide the others.
        guard let elements = try? JSONDecoder().decode([ReadableDocument].self, from: data) else {
            throw FrogError.message("\(file.shownPath) is not a list of Frog documents. The file was left unchanged. Repair it, or move it aside to start again without its items.")
        }
        let documents = elements.compactMap(\.document)
        if documents.count == elements.count { unreadable = nil; unsavedOriginal = nil; return documents }
        let backup = file.deletingLastPathComponent().appendingPathComponent("toolkit-documents-backup-\(UUID().uuidString).json").resolvingSymlinksInPath()
        unreadable = Unreadable(count: elements.count - documents.count, total: elements.count, file: file, backup: backup)
        unsavedOriginal = data
        return documents
    }
    public func save(_ documents: [UtilityDocument], revision: Int) throws {
        try Task.checkCancellation()
        guard revision > self.revision else { return }
        guard documents.count <= 1000, Set(documents.map(\.id)).count == documents.count,
              documents.allSatisfy({ $0.text.utf8.count <= 1_000_000 && $0.files.count <= 100 }) else {
            throw FrogError.message("Keep up to 1,000 items, with at most 1 MB of text and 100 files per item.")
        }
        let data = try JSONEncoder().encode(documents)
        guard data.count <= 16 * 1024 * 1024 else { throw FrogError.message("The local document store exceeds 16 MB.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let original = unsavedOriginal, let backup = unreadable?.backup {
            // This write drops the items that could not be read. Keep the file as it was first, once.
            do { try PrivateFile.write(original, to: backup, secureDirectory: false) }
            catch { throw FrogError.message("Nothing was saved, because the file with the unreadable items could not be kept as \(backup.lastPathComponent) first. \(error.localizedDescription)") }
            unsavedOriginal = nil
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        self.revision = revision
    }
}

/// One element of the saved list, or nothing where this version of Frog cannot read it.
private struct ReadableDocument: Decodable {
    let document: UtilityDocument?
    init(from decoder: Decoder) throws { document = try? UtilityDocument(from: decoder) }
}

private extension URL {
    /// The path as a person would write it, with the home folder as a tilde.
    var shownPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

public enum SnippetExpansion {
    public static func expand(_ template: String, clipboard: String, date: Date = Date(), locale: Locale = .current) -> String {
        let day = DateFormatter(); day.locale = locale; day.dateStyle = .short; day.timeStyle = .none
        let time = DateFormatter(); time.locale = locale; time.dateStyle = .none; time.timeStyle = .short
        // One pass prevents clipboard contents from being treated as another template.
        let values = ["date": day.string(from: date), "time": time.string(from: date), "clipboard": clipboard]
        let pattern = try! NSRegularExpression(pattern: "\\{\\{(date|time|clipboard)\\}\\}")
        let text = template as NSString
        var output = template
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: text.length)).reversed() {
            guard let range = Range(match.range, in: output), let value = values[text.substring(with: match.range(at: 1))] else { continue }
            output.replaceSubrange(range, with: value)
        }
        return output
    }
}

public enum LinkCleaning {
    public static func clean(_ text: String) -> String? {
        guard var url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        let trackers: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "si"]
        url.queryItems = url.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !trackers.contains($0.name.lowercased()) }
        if url.queryItems?.isEmpty == true { url.queryItems = nil }
        return url.string
    }
}
