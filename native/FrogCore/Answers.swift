import Foundation

/// One completed question and answer. The first turn answers the selection and has an empty question.
public struct AnswerTurn: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// What an answer sends: the first message, the conversation, the reply language and the limits.
/// Only the selection, the optional surrounding text, the app name, the reply language and earlier
/// turns leave the Mac. The page address or document path is never part of a message.
public enum AnswerPrompt {
    public static let maximumFollowUps = 10
    /// Characters per follow-up question.
    public static let maximumQuestion = 2_000
    /// Characters across all messages and the instructions.
    public static let maximumConversation = 200_000

    public static func firstMessage(selection: String, context: String?, application: String?, replyLanguage: String) -> String {
        let selection = selection.trimmingCharacters(in: .newlines)
        var context = context?.trimmingCharacters(in: .newlines)
        if let text = context, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || text.trimmingCharacters(in: .whitespacesAndNewlines) == selection.trimmingCharacters(in: .whitespacesAndNewlines) {
            context = nil
        }
        let fence = fence(for: [selection] + (context.map { [$0] } ?? []))
        var header: [String] = []
        if let application = application?.trimmingCharacters(in: .whitespacesAndNewlines), !application.isEmpty {
            header.append("App: \(application)")
        }
        let language = replyLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty { header.append("Reply language: \(language)") }
        var sections: [String] = []
        if !header.isEmpty { sections.append(header.joined(separator: "\n")) }
        sections.append("Selected text:\n\(fence)\n\(selection)\n\(fence)")
        if let context { sections.append("Surrounding text:\n\(fence)\n\(context)\n\(fence)") }
        return sections.joined(separator: "\n\n")
    }

    /// The conversation for the next answer: the first message, then for each later turn the
    /// previous answer and its question, then the pending question after the last answer.
    /// Roles alternate, starting and ending with the user.
    public static func messages(firstMessage: String, turns: [AnswerTurn], pendingQuestion: String?) -> [ChatMessage] {
        var messages = [ChatMessage(role: .user, text: firstMessage)]
        for index in turns.indices.dropFirst() {
            messages.append(ChatMessage(role: .assistant, text: turns[index - 1].answer))
            messages.append(ChatMessage(role: .user, text: turns[index].question))
        }
        if let pendingQuestion, let last = turns.last {
            messages.append(ChatMessage(role: .assistant, text: last.answer))
            messages.append(ChatMessage(role: .user, text: pendingQuestion))
        }
        return messages
    }

    /// One text for coding tools, which take a single prompt.
    public static func transcript(_ messages: [ChatMessage]) -> String {
        if messages.count == 1 { return messages[0].text }
        guard !messages.isEmpty else { return "" }
        let parts = messages.map { ($0.role == .user ? "User:" : "Assistant:") + "\n" + $0.text }
        return "Conversation so far:\n\n" + parts.joined(separator: "\n\n") + "\n\nReply to the last User message only."
    }

    /// The Mac's first preferred language, named in English. `preferred` is `Locale.preferredLanguages`.
    public static func replyLanguage(preferred: [String]) -> String {
        guard let first = preferred.first,
              let code = Locale(identifier: first).language.languageCode?.identifier,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code),
              !name.isEmpty, name.lowercased() != code.lowercased()
        else { return "English" }
        return name
    }

    /// A Markdown fence one backtick longer than the longest backtick run in any of the texts, at least three.
    public static func fence(for texts: [String]) -> String {
        var longest = 0
        for text in texts {
            var run = 0
            for character in text {
                if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// The longest selection an answer accepts. Small local context windows truncate silently, so
    /// Frog-local models and local or compatible servers get the lower limit.
    public static func selectionLimit(local: Bool, kind: ProviderKind?) -> Int {
        if local { return 12_000 }
        switch kind {
        case .openAI, .anthropic, .gemini, .claudeCode, .codex, .opencode: return 100_000
        case .ollama, .lmStudio, .compatible, nil: return 12_000
        }
    }

    public static func selectionTooLong(limit: Int) -> String {
        let count = limit.formatted(.number.locale(Locale(identifier: "en")))
        return "Selection too long for this model. Select at most \(count) characters, or choose a model with a larger context in the rule."
    }

    /// "Qwen3 4B · Frog" for Frog-local models, "gpt-5-mini · OpenAI" otherwise.
    public static func modelLabel(modelName: String, providerName: String?, local: Bool) -> String {
        if local { return "\(modelName) · Frog" }
        guard let providerName, !providerName.isEmpty else { return modelName }
        return "\(modelName) · \(providerName)"
    }
}

/// Text around a selection that helps a model read it: the enclosing paragraph, line or sentences.
public enum SurroundingText {
    /// - Parameters:
    ///   - selection: The selected range in UTF-16 units of `window`, as Accessibility reports it.
    ///   - window: Text read around the selection.
    ///   - limit: The most characters returned, not counting the ellipses that mark dropped text.
    public static func around(selection: NSRange, in window: String, limit: Int = 1_000) -> String? {
        guard !window.isEmpty, selection.location != NSNotFound,
              let range = Range(selection, in: window) else { return nil }
        let selected = window[range].trimmingCharacters(in: .whitespacesAndNewlines)
        guard window[range].count < limit else { return nil }

        let lines = lineRanges(in: window)
        guard !lines.isEmpty else { return nil }
        let last = range.isEmpty ? range.lowerBound : window.index(before: range.upperBound)
        let firstLine = lineIndex(of: range.lowerBound, in: lines)
        let lastLine = max(firstLine, lineIndex(of: last, in: lines))

        var result: String
        var start = firstLine, end = lastLine
        while start > 0, !isBlank(window[lines[start - 1]]) { start -= 1 }
        while end < lines.count - 1, !isBlank(window[lines[end + 1]]) { end += 1 }
        result = trimmed(window[lines[start].lowerBound..<lines[end].upperBound])
        if result.count > limit {
            let scope = lines[firstLine].lowerBound..<lines[lastLine].upperBound
            result = trimmed(window[scope])
            if result.count > limit { result = sentences(around: range, in: window, scope: scope, limit: limit) }
        }
        guard !result.isEmpty, result != selected else { return nil }
        return result
    }

    /// The sentences touching the selection, widened alternately before and after while within the limit.
    private static func sentences(around range: Range<String.Index>, in text: String, scope: Range<String.Index>, limit: Int) -> String {
        var sentences: [Range<String.Index>] = []
        text.enumerateSubstrings(in: scope, options: [.bySentences, .substringNotRequired]) { _, sentence, _, _ in
            sentences.append(sentence)
        }
        let touching = sentences.indices.filter { index in
            let sentence = sentences[index]
            return range.isEmpty ? sentence.contains(range.lowerBound) || sentence.upperBound == range.lowerBound
                : sentence.overlaps(range)
        }
        guard let first = touching.first, let lastTouching = touching.last else {
            return clipped(around: range, in: text, scope: scope, limit: limit)
        }
        var low = first, high = lastTouching
        func length(_ low: Int, _ high: Int) -> Int { trimmed(text[sentences[low].lowerBound..<sentences[high].upperBound]).count }
        guard length(low, high) <= limit else { return clipped(around: range, in: text, scope: scope, limit: limit) }
        while true {
            var widened = false
            if low > 0, length(low - 1, high) <= limit { low -= 1; widened = true }
            if high < sentences.count - 1, length(low, high + 1) <= limit { high += 1; widened = true }
            if !widened { break }
        }
        return marked(text, sentences[low].lowerBound..<sentences[high].upperBound, scope: scope)
    }

    /// A single sentence longer than the limit: characters centred on the selection.
    private static func clipped(around range: Range<String.Index>, in text: String, scope: Range<String.Index>, limit: Int) -> String {
        let spare = max(0, limit - text[range].count)
        let lower = text.index(range.lowerBound, offsetBy: -(spare / 2), limitedBy: scope.lowerBound) ?? scope.lowerBound
        let upper = text.index(lower, offsetBy: limit, limitedBy: scope.upperBound) ?? scope.upperBound
        return marked(text, lower..<upper, scope: scope)
    }

    private static func marked(_ text: String, _ range: Range<String.Index>, scope: Range<String.Index>) -> String {
        let before = !trimmed(text[scope.lowerBound..<range.lowerBound]).isEmpty
        let after = !trimmed(text[range.upperBound..<scope.upperBound]).isEmpty
        return (before ? "…" : "") + trimmed(text[range]) + (after ? "…" : "")
    }

    /// Each line's content, without its terminator.
    private static func lineRanges(in text: String) -> [Range<String.Index>] {
        var lines: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            lines.append(line)
        }
        return lines
    }

    /// The line holding an index; an index on a terminator or past the end belongs to the line before.
    private static func lineIndex(of index: String.Index, in lines: [Range<String.Index>]) -> Int {
        guard let position = lines.firstIndex(where: { index < $0.upperBound }) else { return lines.count - 1 }
        return position > 0 && index < lines[position].lowerBound ? position - 1 : position
    }

    private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }
    private static func trimmed(_ text: Substring) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Hides one leading `<think>…</think>` block that some local and compatible models stream before
/// their answer. Tags may be split across chunks. Use one filter per answer turn.
public struct ReasoningFilter: Sendable {
    public static let onlyReasoning = "The model returned only its reasoning. Try again or choose another model."
    private static let open = "<think>"
    private static let close = "</think>"

    private enum State: Sendable { case undecided, thinking, leading, visible }
    private var state = State.undecided
    private var held = ""
    /// True once a reasoning block started; with no visible text, the answer was only reasoning.
    public private(set) var hidReasoning = false

    public init() {}

    public mutating func feed(_ chunk: String) -> (visible: String, thinking: Bool) {
        switch state {
        case .visible:
            return (chunk, false)
        case .leading:
            let text = String(chunk.drop { $0.isWhitespace })
            if !text.isEmpty { state = .visible }
            return (text, false)
        case .undecided:
            held += chunk
            let start = held.drop { $0.isWhitespace }
            if start.isEmpty || Self.open.hasPrefix(start) { return ("", false) }
            guard start.hasPrefix(Self.open) else {
                state = .visible
                defer { held = "" }
                return (held, false)
            }
            state = .thinking
            hidReasoning = true
            let rest = String(start.dropFirst(Self.open.count))
            held = ""
            return feed(rest)
        case .thinking:
            held += chunk
            guard let end = held.range(of: Self.close) else {
                held = String(held.suffix(Self.close.count - 1))
                return ("", true)
            }
            let rest = String(held[end.upperBound...])
            held = ""
            state = .leading
            return feed(rest)
        }
    }

    /// Text still held back at the end. An unclosed reasoning block yields nothing.
    public mutating func finish() -> String {
        defer { held = "" }
        return state == .undecided ? held : ""
    }
}
