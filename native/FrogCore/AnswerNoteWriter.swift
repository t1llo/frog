import Foundation

/// Writes answers as Markdown into the notes folder the person chose, and nowhere else: a
/// folder or file that resolves outside it, through a symbolic link, is refused.
public struct AnswerNoteWriter: Sendable {
    public static let missingFolder = "Choose a notes folder that exists."
    public static let outsideFolder = "The note would be written outside the notes folder."
    public static let tooLarge = "The note is larger than 5 MB. Choose another file."
    static let maximumAppendBytes = 5 * 1024 * 1024

    public init() {}

    /// Returns the URL written.
    public func save(_ content: AnswerNoteContent, folder: URL, mode: ExplainSettings.NotesMode, file pattern: String, now: Date) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FrogError.message(Self.missingFolder)
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        switch mode {
        case .perAnswer: return try writeNote(content, root: root, fileManager: fileManager)
        case .append: return try appendSection(content, root: root, pattern: pattern, now: now, fileManager: fileManager)
        }
    }

    /// A new file named after the selection; a name taken meanwhile moves on to the next one.
    private func writeNote(_ content: AnswerNoteContent, root: URL, fileManager: FileManager) throws -> URL {
        var existing = Set((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
        let data = Data(AnswerNote.document(content).utf8)
        for _ in 0..<200 {
            let name = AnswerNote.fileName(selection: content.selection, date: content.date, existing: existing)
            let target = root.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return target
            } catch where Self.exists(target, fileManager) {
                existing.insert(name)
            }
        }
        throw FrogError.message("Frog could not find a free file name in the notes folder.")
    }

    /// Adds a section to the end of one file, creating it and its folders when they are missing.
    private func appendSection(_ content: AnswerNoteContent, root: URL, pattern: String, now: Date, fileManager: FileManager) throws -> URL {
        var components = try AnswerNote.expand(pattern: pattern, date: now, calendar: .current).split(separator: "/").map(String.init)
        let name = components.removeLast()
        var directory = root
        for component in components {
            let next = directory.appendingPathComponent(component, isDirectory: true)
            if !Self.exists(next, fileManager) { try fileManager.createDirectory(at: next, withIntermediateDirectories: false) }
            let resolved = next.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isInside(resolved, root) else { throw FrogError.message(Self.outsideFolder) }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FrogError.message(AnswerNote.invalidFile)
            }
            directory = resolved
        }
        let target = directory.appendingPathComponent(name, isDirectory: false)
        let section = Data(AnswerNote.section(content).utf8)
        guard Self.exists(target, fileManager) else {
            guard fileManager.createFile(atPath: target.path, contents: section, attributes: [.posixPermissions: 0o644]) else {
                throw FrogError.message("Frog could not create the note in the notes folder.")
            }
            return target
        }
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isInside(resolved, root) else { throw FrogError.message(Self.outsideFolder) }
        let attributes = try fileManager.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FrogError.message(AnswerNote.invalidFile) }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumAppendBytes else { throw FrogError.message(Self.tooLarge) }
        let handle = try FileHandle(forUpdating: resolved)
        defer { try? handle.close() }
        // One blank line between what is there and the new section.
        var separator = Data()
        if size > 0 {
            try handle.seek(toOffset: UInt64(max(0, size - 2)))
            let tail = try handle.readToEnd() ?? Data()
            if tail.last != 0x0A { separator = Data("\n\n".utf8) }
            else if tail.count < 2 || tail[tail.startIndex] != 0x0A { separator = Data("\n".utf8) }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: separator + section)
        return resolved
    }

    /// True for anything at the path, a symbolic link whose target is missing included.
    private static func exists(_ url: URL, _ fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
