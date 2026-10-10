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
    private let file: URL
    private var revision = -1
    public init(directory: URL) { file = directory.appendingPathComponent("toolkit-documents.json") }
    public func load() throws -> [UtilityDocument] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 16 * 1024 * 1024 else { throw FrogError.message("The local document store exceeds 16 MB.") }
        return try JSONDecoder().decode([UtilityDocument].self, from: data)
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
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        self.revision = revision
    }
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
