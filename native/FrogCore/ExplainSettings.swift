import Foundation

/// How answer rules behave. Each field decodes with its default when it is missing, so a file
/// written before a field existed keeps working.
public struct ExplainSettings: Codable, Equatable, Sendable {
    /// How Save to note writes an answer.
    public enum NotesMode: String, Codable, CaseIterable, Sendable {
        /// A new file for each answer, named after the selection.
        case perAnswer = "per-answer"
        /// A section appended to one file, such as a daily note.
        case append
    }

    public static let invalidNotesFolder = "Choose a notes folder with a full path."

    /// Sends the sentence or paragraph around the selection with it.
    public var includeContext = true
    /// Adds Save to note to the answer panel and to answers in History.
    public var notes = false
    /// The folder notes are written into, tilde-abbreviated.
    public var notesFolder: String?
    public var notesMode: NotesMode = .perAnswer
    /// The file "Add to one note" appends to, inside the notes folder. YYYY, MM and DD become today's date.
    public var notesFile = "Daily/YYYY-MM-DD.md"
    /// Opens the note after saving, in Obsidian when the folder is inside a vault.
    public var notesOpen = false

    public init() {}

    public var normalized: Self { self }

    private enum CodingKeys: String, CodingKey {
        case includeContext, notes, notesFolder, notesMode, notesFile, notesOpen
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includeContext = try values.decodeIfPresent(Bool.self, forKey: .includeContext) ?? true
        notes = try values.decodeIfPresent(Bool.self, forKey: .notes) ?? false
        notesFolder = try values.decodeIfPresent(String.self, forKey: .notesFolder)
        notesMode = try values.decodeIfPresent(NotesMode.self, forKey: .notesMode) ?? .perAnswer
        notesFile = try values.decodeIfPresent(String.self, forKey: .notesFile) ?? "Daily/YYYY-MM-DD.md"
        notesOpen = try values.decodeIfPresent(Bool.self, forKey: .notesOpen) ?? false
        self = normalized
    }

    public func validate() throws {
        if let notesFolder {
            guard notesFolder.hasPrefix("/") || notesFolder.hasPrefix("~/"),
                  !notesFolder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw FrogError.message(Self.invalidNotesFolder) }
        }
        _ = try AnswerNote.expand(pattern: notesFile, date: Date(), calendar: Calendar(identifier: .gregorian))
    }

    /// The notes folder as a file URL, with the tilde expanded.
    public var notesFolderURL: URL? {
        notesFolder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
}

extension Preferences {
    public var explainSettings: ExplainSettings { toolkitSettings.explain ?? ExplainSettings() }
}
