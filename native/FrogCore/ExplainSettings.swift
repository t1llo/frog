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
    /// Shows a bubble with Explain and the other rules after text is selected in another app.
    public var selectionBubble = false
    /// The bubble also follows a double- or triple-click.
    public var bubbleDoubleClick = true
    /// The bubble also follows a selection made with Shift and the arrow keys.
    public var bubbleKeyboard = true
    /// Longer selections show no bubble.
    public var bubbleMaxCharacters = 4_000
    /// Apps the bubble never shows in, by bundle identifier.
    public var bubbleExcludedApps: [String] = SelectionBubbleOptions.defaultExcludedApps.sorted()
    /// Asks Chrome, Electron and similar apps once to expose their text, so the bubble works there too.
    public var bubbleExposeText = true
    /// Rules the person took out of the bubble; their shortcuts still work.
    public var bubbleHiddenRules: [UUID] = []

    public init() {}

    public var normalized: Self {
        var settings = self
        let range = SelectionBubbleOptions.characterRange
        settings.bubbleMaxCharacters = min(max(bubbleMaxCharacters, range.lowerBound), range.upperBound)
        return settings
    }

    private enum CodingKeys: String, CodingKey {
        case includeContext, notes, notesFolder, notesMode, notesFile, notesOpen
        case selectionBubble, bubbleDoubleClick, bubbleKeyboard, bubbleMaxCharacters, bubbleExcludedApps, bubbleHiddenRules, bubbleExposeText
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includeContext = try values.decodeIfPresent(Bool.self, forKey: .includeContext) ?? true
        notes = try values.decodeIfPresent(Bool.self, forKey: .notes) ?? false
        notesFolder = try values.decodeIfPresent(String.self, forKey: .notesFolder)
        notesMode = try values.decodeIfPresent(NotesMode.self, forKey: .notesMode) ?? .perAnswer
        notesFile = try values.decodeIfPresent(String.self, forKey: .notesFile) ?? "Daily/YYYY-MM-DD.md"
        notesOpen = try values.decodeIfPresent(Bool.self, forKey: .notesOpen) ?? false
        selectionBubble = try values.decodeIfPresent(Bool.self, forKey: .selectionBubble) ?? false
        bubbleDoubleClick = try values.decodeIfPresent(Bool.self, forKey: .bubbleDoubleClick) ?? true
        bubbleKeyboard = try values.decodeIfPresent(Bool.self, forKey: .bubbleKeyboard) ?? true
        bubbleMaxCharacters = try values.decodeIfPresent(Int.self, forKey: .bubbleMaxCharacters) ?? 4_000
        bubbleExcludedApps = try values.decodeIfPresent([String].self, forKey: .bubbleExcludedApps)
            ?? SelectionBubbleOptions.defaultExcludedApps.sorted()
        bubbleHiddenRules = try values.decodeIfPresent([UUID].self, forKey: .bubbleHiddenRules) ?? []
        bubbleExposeText = try values.decodeIfPresent(Bool.self, forKey: .bubbleExposeText) ?? true
        self = normalized
    }

    public func validate() throws {
        if let notesFolder {
            guard notesFolder.hasPrefix("/") || notesFolder.hasPrefix("~/"),
                  !notesFolder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw FrogError.message(Self.invalidNotesFolder) }
        }
        _ = try AnswerNote.expand(pattern: notesFile, date: Date(), calendar: Calendar(identifier: .gregorian))
        try BundleIdentifiers.validate(bubbleExcludedApps)
    }

    /// What the selection bubble decides with.
    public var bubbleOptions: SelectionBubbleOptions {
        var options = SelectionBubbleOptions()
        options.doubleClick = bubbleDoubleClick
        options.keyboard = bubbleKeyboard
        options.maxCharacters = normalized.bubbleMaxCharacters
        options.excludedApps = Set(bubbleExcludedApps)
        options.exposeText = bubbleExposeText
        return options
    }

    /// The notes folder as a file URL, with the tilde expanded.
    public var notesFolderURL: URL? {
        notesFolder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
}

extension Preferences {
    public var explainSettings: ExplainSettings { toolkitSettings.explain ?? ExplainSettings() }
}
