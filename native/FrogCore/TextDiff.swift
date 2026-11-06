import Foundation

/// What a rewrite changed. Words are compared first; a word replaced by a similar one ("yesterday" by "yesterday.") is
/// then compared letter by letter, so only the letters that changed are marked. Spaces are never marked or counted.
public struct TextDiff: Equatable, Sendable {
    /// A run of text, marked when it was taken out (in the original) or put in (in the result).
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var changed: Bool

        public init(_ text: String, changed: Bool) {
            self.text = text
            self.changed = changed
        }
    }

    public let original: [Segment]
    public let result: [Segment]
    /// Words replaced by another word: each is marked on both sides, or on one side when only letters were added or
    /// only letters were taken out.
    public let changedWords: Int
    /// Words put in with nothing in their place.
    public let addedWords: Int
    /// Words taken out with nothing in their place.
    public let removedWords: Int

    public init(original: String, result: String) {
        let old = Self.tokens(original), new = Self.tokens(result)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var originalSegments = SegmentBuilder(), resultSegments = SegmentBuilder()
        var changed = 0, added = 0, taken = 0
        var i = 0, j = 0
        while i < old.count || j < new.count {
            guard (i < old.count && removed.contains(i)) || (j < new.count && inserted.contains(j)) else {
                // Unchanged tokens line up one for one between the hunks.
                if i < old.count { originalSegments.append(old[i], changed: false) }
                if j < new.count { resultSegments.append(new[j], changed: false) }
                i += 1; j += 1
                continue
            }
            var hunkOld: [String] = [], hunkNew: [String] = []
            while i < old.count, removed.contains(i) { hunkOld.append(old[i]); i += 1 }
            while j < new.count, inserted.contains(j) { hunkNew.append(new[j]); j += 1 }

            // Words in the hunk are paired in order; a pair is a changed word, the rest were added or removed.
            let oldWords = hunkOld.indices.filter { !Self.isSpace(hunkOld[$0]) }
            let newWords = hunkNew.indices.filter { !Self.isSpace(hunkNew[$0]) }
            let pairs = min(oldWords.count, newWords.count)
            changed += pairs
            taken += oldWords.count - pairs
            added += newWords.count - pairs
            var oldMarks: [Int: [Bool]] = [:], newMarks: [Int: [Bool]] = [:]
            for pair in 0..<pairs {
                let (a, b) = Self.letterMarks(hunkOld[oldWords[pair]], hunkNew[newWords[pair]])
                oldMarks[oldWords[pair]] = a
                newMarks[newWords[pair]] = b
            }
            Self.emit(hunkOld, marks: oldMarks, into: &originalSegments)
            Self.emit(hunkNew, marks: newMarks, into: &resultSegments)
        }
        self.original = originalSegments.segments
        self.result = resultSegments.segments
        changedWords = changed
        addedWords = added
        removedWords = taken
    }

    /// Whether anything at all was marked.
    public var isEmpty: Bool { changedWords == 0 && addedWords == 0 && removedWords == 0 }

    /// Words and the spaces between them, so spacing survives and only words are marked.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let space = character.isWhitespace
            if currentIsSpace != nil, space != currentIsSpace { tokens.append(current); current = "" }
            current.append(character); currentIsSpace = space
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func isSpace(_ token: String) -> Bool { token.allSatisfy(\.isWhitespace) }

    /// Which letters of a replaced word changed. Words that share most of their letters are marked letter by letter;
    /// different words are marked whole, as a scatter of single letters would be harder to read.
    static func letterMarks(_ a: String, _ b: String) -> ([Bool], [Bool]) {
        let old = Array(a), new = Array(b)
        var oldMarks = Array(repeating: false, count: old.count), newMarks = Array(repeating: false, count: new.count)
        let difference = new.difference(from: old)
        for change in difference {
            switch change {
            case .remove(let offset, _, _): oldMarks[offset] = true
            case .insert(let offset, _, _): newMarks[offset] = true
            }
        }
        let common = old.count - oldMarks.filter { $0 }.count
        if common * 2 < max(old.count, new.count) {
            return (Array(repeating: true, count: old.count), Array(repeating: true, count: new.count))
        }
        return (oldMarks, newMarks)
    }

    private static func emit(_ tokens: [String], marks: [Int: [Bool]], into builder: inout SegmentBuilder) {
        for (index, token) in tokens.enumerated() {
            if isSpace(token) { builder.append(token, changed: false); continue }
            guard let letters = marks[index] else { builder.append(token, changed: true); continue }
            for (character, mark) in zip(token, letters) { builder.append(String(character), changed: mark) }
        }
    }

    private struct SegmentBuilder {
        var segments: [Segment] = []

        mutating func append(_ text: String, changed: Bool) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.changed == changed {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(text, changed: changed))
            }
        }
    }
}
