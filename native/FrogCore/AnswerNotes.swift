import Foundation

/// What Save to note writes of an answer: the selection, the answer and its follow-ups. The
/// surrounding text sent with the selection is never part of a note.
public struct AnswerNoteContent: Equatable, Sendable {
    public var ruleName: String
    public var selection: String
    /// "Qwen3 4B · Frog"
    public var modelLabel: String
    public var application: String?
    /// The page address or document path.
    public var source: String?
    public var date: Date
    /// Completed turns; `turns[0].question` is empty.
    public var turns: [AnswerTurn]

    public init(ruleName: String, selection: String, modelLabel: String, application: String?, source: String?,
                date: Date, turns: [AnswerTurn]) {
        self.ruleName = ruleName
        self.selection = selection
        self.modelLabel = modelLabel
        self.application = application
        self.source = source
        self.date = date
        self.turns = turns
    }

    /// The panel's conversation. A stopped answer keeps the text it had.
    public init(session: AnswerSession, date: Date) {
        var turns = session.turns
        let partial = session.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.phase == .stopped, !partial.isEmpty {
            turns.append(AnswerTurn(question: turns.isEmpty ? "" : session.pendingQuestion ?? "", answer: partial))
        }
        self.init(ruleName: session.ruleName, selection: session.selection, modelLabel: session.modelLabel,
                  application: session.application, source: session.source, date: date, turns: turns)
    }

    /// A saved answer from History.
    public init(entry: HistoryEntry) {
        self.init(ruleName: entry.ruleName, selection: entry.originalText,
                  modelLabel: AnswerPrompt.modelLabel(modelName: entry.model, providerName: entry.providerName, local: false),
                  application: entry.answer?.application, source: entry.answer?.source, date: entry.timestamp,
                  turns: [AnswerTurn(question: "", answer: entry.processedText)] + (entry.answer?.followUps ?? []))
    }
}

/// The Markdown of a saved answer and the names of its files.
public enum AnswerNote {
    public static let invalidFile = "Enter a file path inside the notes folder, such as Daily/YYYY-MM-DD.md."
    public static let notMarkdown = "Choose a Markdown file (.md)."
    /// Characters of the selection a note quotes.
    static let maximumQuote = 2_000
    /// Characters of one front matter value.
    static let maximumValue = 300
    /// Characters of a file name or heading taken from the selection.
    static let maximumTitle = 60
    private static let forbidden = Set("/\\:*?\"<>|#^[]{}")

    /// A file name from the selection's first line that is free in `existing`, ending in `.md`.
    public static func fileName(selection: String, date: Date, existing: Set<String>, timeZone: TimeZone = .current) -> String {
        var name = plain(String(firstLine(selection).filter { !forbidden.contains($0) }))
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        name = cut(name, to: maximumTitle).text
        if name.isEmpty { name = "Answer " + stamp(date, format: "yyyy-MM-dd HHmm", timeZone: timeZone) }
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains("\(name).md".lowercased()) { return "\(name).md" }
        for number in 2...99 where !taken.contains("\(name) \(number).md".lowercased()) { return "\(name) \(number).md" }
        return "\(name) \(UUID().uuidString.prefix(8).lowercased()).md"
    }

    /// The file "Add to one note" writes, relative to the notes folder: `YYYY`, `MM` and `DD` become the
    /// date's Gregorian year, month and day in the calendar's time zone. A path without an extension gets `.md`.
    public static func expand(pattern: String, date: Date, calendar: Calendar) throws -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let day = gregorian.dateComponents([.year, .month, .day], from: date)
        var path = pattern.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "YYYY", with: String(format: "%04d", day.year ?? 0))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", day.month ?? 0))
            .replacingOccurrences(of: "DD", with: String(format: "%02d", day.day ?? 0))
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains(where: isControl) else {
            throw FrogError.message(invalidFile)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw FrogError.message(invalidFile) }
        let fileExtension = (String(components[components.count - 1]) as NSString).pathExtension.lowercased()
        if fileExtension.isEmpty { path += ".md" }
        else if fileExtension != "md" && fileExtension != "markdown" { throw FrogError.message(notMarkdown) }
        guard path.count <= 255 else { throw FrogError.message(invalidFile) }
        return path
    }

    /// One note per answer: YAML front matter, the quoted selection, the answer and its follow-ups.
    public static func document(_ note: AnswerNoteContent, timeZone: TimeZone = .current) -> String {
        var lines = ["---"]
        if let source = note.source.flatMap(yamlString) { lines.append("source: \(source)") }
        if let app = note.application.flatMap(yamlString) { lines.append("app: \(app)") }
        if let model = yamlString(note.modelLabel) { lines.append("model: \(model)") }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        lines.append("date: \(formatter.string(from: note.date))")
        lines.append("tags: [\(tags(ruleName: note.ruleName).joined(separator: ", "))]")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body(note, followUpLevel: "##")
    }

    /// A section to add to one note: a heading with the time, rule and selection, then what
    /// `document` writes below its front matter.
    public static func section(_ note: AnswerNoteContent, timeZone: TimeZone = .current) -> String {
        let rule = collapsed(note.ruleName)
        var heading = "## \(stamp(note.date, format: "HH:mm", timeZone: timeZone)) · \(rule.isEmpty ? "Answer" : rule)"
        let title = cut(plain(firstLine(note.selection)), to: maximumTitle)
        if !title.text.isEmpty { heading += ": " + title.text + (title.shortened ? "…" : "") }
        var parts = [heading]
        let details = [note.application ?? "", note.modelLabel]
            .map { plain($0).replacingOccurrences(of: "*", with: "\\*") }
            .filter { !$0.isEmpty }
        if !details.isEmpty { parts.append("*\(details.joined(separator: " · "))*") }
        return parts.joined(separator: "\n\n") + "\n\n" + body(note, followUpLevel: "###")
    }

    /// `frog` and a slug of the rule name.
    static func tags(ruleName: String) -> [String] {
        var slug = ""
        for character in ruleName.lowercased() {
            if character.isLetter || character.isNumber { slug.append(character) }
            else if !slug.isEmpty, slug.last != "-" { slug.append("-") }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "answer" }
        // A tag of digits alone is not a tag in Obsidian.
        if slug.allSatisfy(\.isNumber) { slug = "answer-" + slug }
        return slug == "frog" ? ["frog"] : ["frog", slug]
    }

    // MARK: Parts

    private static func body(_ note: AnswerNoteContent, followUpLevel: String) -> String {
        var parts = [quote(note.selection)]
        for (index, turn) in note.turns.enumerated() {
            if index > 0 {
                parts.append("\(followUpLevel) Follow-up: \(plain(turn.question))")
            }
            let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { parts.append(answer) }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The selection as a block quote, shortened past 2,000 characters.
    private static func quote(_ selection: String) -> String {
        var text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumQuote {
            text = String(text.prefix(maximumQuote)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "> " + $0 }
            .joined(separator: "\n")
    }

    /// A double-quoted YAML scalar on one line, or nil when nothing is left of the value.
    private static func yamlString(_ value: String) -> String? {
        var cleaned = ""
        for character in value {
            if character.isNewline || character == "\t" { cleaned.append(" ") }
            else if !isControl(character) { cleaned.append(character) }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maximumValue { cleaned = String(cleaned.prefix(maximumValue)) }
        let escaped = cleaned.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The first line that holds more than spaces.
    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One line: control characters become spaces, runs of spaces one.
    private static func plain(_ text: String) -> String {
        collapsed(String(text.map { isControl($0) ? " " : $0 }))
    }

    /// At most `limit` characters, cut before the word the limit falls in when there is an earlier space.
    private static func cut(_ text: String, to limit: Int) -> (text: String, shortened: Bool) {
        guard text.count > limit else { return (text, false) }
        let prefix = text.prefix(limit)
        let next = text[text.index(text.startIndex, offsetBy: limit)]
        if next != " ", let space = prefix.lastIndex(of: " ") {
            return (String(prefix[..<space]).trimmingCharacters(in: .whitespaces), true)
        }
        return (String(prefix).trimmingCharacters(in: .whitespaces), true)
    }

    /// Newlines and tabs included; format characters such as the joiner inside an emoji are not.
    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func stamp(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
