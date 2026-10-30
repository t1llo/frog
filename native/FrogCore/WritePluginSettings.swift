import Foundation

/// `[writing]` in config.toml. The rules themselves stay in Frog's rule list, shared with Dictation.
public struct WritingConfig: ConfigSection {
    /// `[writing.bubble]`: the bubble that offers your rules after you select text.
    public struct Bubble: ConfigSection {
        public var on = false
        public var doubleClick = true
        public var keyboard = true
        public var chromiumApps = true
        public var maxCharacters = 4_000
        public var excludedApps = SelectionBubbleOptions.defaultExcludedApps.sorted()
        public init() {}

        /// What the selection watcher decides with.
        public var options: SelectionBubbleOptions {
            var options = SelectionBubbleOptions()
            options.doubleClick = doubleClick
            options.keyboard = keyboard
            options.chromiumApps = chromiumApps
            let range = SelectionBubbleOptions.characterRange
            options.maxCharacters = min(max(maxCharacters, range.lowerBound), range.upperBound)
            options.excludedApps = Set(excludedApps)
            return options
        }
    }

    public var bubble = Bubble()
    public init() {}

    /// The settings Explain kept for the bubble before Writing had its own table. The bubble ran only while Explain
    /// was on too, so it starts on only then.
    public init(legacy: ExplainSettings, explainOn: Bool) {
        bubble.on = legacy.selectionBubble && explainOn
        bubble.doubleClick = legacy.bubbleDoubleClick
        bubble.keyboard = legacy.bubbleKeyboard
        bubble.chromiumApps = legacy.bubbleExposeText
        bubble.maxCharacters = legacy.normalized.bubbleMaxCharacters
        bubble.excludedApps = legacy.bubbleExcludedApps
    }

    public func validate() throws { try BundleIdentifiers.validate(bubble.excludedApps) }

    public static let comments = [
        "": "Writing: rules that rewrite selected text.",
        "bubble": "The bubble that offers your rules after you select text",
        "bubble.double-click": "Also after a double- or triple-click",
        "bubble.keyboard": "Also after selecting with Shift and the arrow keys",
        "bubble.chromium-apps": "Also in Chrome, Electron and other apps that hide their text",
        "bubble.max-characters": "Longer selections show no bubble (100 to 20000)",
        "bubble.excluded-apps": "Bundle identifiers of apps that never show it",
    ]
}

/// `[explain]` in config.toml.
public struct ExplainConfig: ConfigSection {
    public typealias NotesMode = ExplainSettings.NotesMode

    /// `[explain.notes]`: Save to note in the answer panel.
    public struct Notes: ConfigSection {
        public var on = false
        public var folder: String?
        public var mode = NotesMode.perAnswer
        public var file = "Daily/YYYY-MM-DD.md"
        public var open = false
        public init() {}

        /// The folder as a file URL, with the tilde expanded.
        public var folderURL: URL? {
            folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        }
    }

    public var context = true
    public var notes = Notes()
    public init() {}

    /// The answer settings from before Explain had its own table.
    public init(legacy: ExplainSettings) {
        context = legacy.includeContext
        notes.on = legacy.notes
        notes.folder = legacy.notesFolder
        notes.mode = legacy.notesMode
        notes.file = legacy.notesFile
        notes.open = legacy.notesOpen
    }

    public func validate() throws {
        if let folder = notes.folder, !Self.validFolder(folder) { throw FrogError.message(ExplainSettings.invalidNotesFolder) }
        _ = try AnswerNote.expand(pattern: notes.file, date: Date(), calendar: Calendar(identifier: .gregorian))
    }

    /// The folder must be absolute; `~/` stands for the home folder.
    static func validFolder(_ folder: String) -> Bool {
        (folder.hasPrefix("/") || folder.hasPrefix("~/"))
            && !folder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    /// These settings as read from a file edited outside Frog: an invalid folder is dropped and an invalid file
    /// pattern goes back to the default, so notes never go somewhere unintended. `issue` says what was dropped.
    public func sanitized() -> (settings: ExplainConfig, issue: String?) {
        var kept = self
        var issues: [String] = []
        if let folder = notes.folder, !Self.validFolder(folder) {
            kept.notes.folder = nil; issues.append(ExplainSettings.invalidNotesFolder)
        }
        do { _ = try AnswerNote.expand(pattern: notes.file, date: Date(), calendar: Calendar(identifier: .gregorian)) } catch {
            kept.notes.file = Notes().file; issues.append(error.localizedDescription)
        }
        return (kept, issues.isEmpty ? nil : "[explain.notes]: " + issues.joined(separator: " "))
    }

    public static let comments = [
        "": "Explain: ask about selected text and read the answer in a panel.",
        "context": "Send the sentence or paragraph around the selection too",
        "notes": "Save to note in the answer panel",
        "notes.folder": "Where notes go, such as an Obsidian vault",
        "notes.mode": "per-answer: a file for each answer\nappend: a section added to one file",
        "notes.file": "The file append adds to; YYYY, MM and DD become the date",
        "notes.open": "Open the note after saving",
    ]
}

extension ConfigStore {
    /// Writes `[name]` from `seed()` when the file has no such table yet, every key included, so the table
    /// itself records that it was seeded. True when it wrote.
    @discardableResult
    public func seedSection<T: ConfigSection>(_ name: String, _ seed: () throws -> T) throws -> Bool {
        var wrote = false
        try edit { document in
            guard document.value(at: [name]) == nil else { return }
            try document.update(name, seed(), all: true)
            wrote = true
        }
        return wrote
    }
}
