import Foundation

/// fzf's v2 scoring: the best alignment of a pattern's characters, in order, inside a text. A match earns points
/// per character, more at the start of a word, after a separator, at a camelCase or digit change and for a run of
/// consecutive characters; gaps cost a little. Case and diacritics are folded by the caller.
public enum FuzzyMatch {
    public static let scoreMatch: Int32 = 16
    static let gapStart: Int32 = -3
    static let gapExtension: Int32 = -1
    static let bonusBoundary: Int32 = 8
    static let bonusNonWord: Int32 = 8
    static let bonusCamel: Int32 = 7
    static let bonusConsecutive: Int32 = 4
    static let bonusBoundaryWhite: Int32 = 10
    static let bonusBoundaryDelimiter: Int32 = 9
    static let firstCharMultiplier: Int32 = 2

    enum CharacterClass: UInt8 { case white, nonWord, delimiter, lower, upper, letter, number }

    /// The text as the scorer reads it: folded scalars and the bonus each position earns.
    public struct Text: Equatable, Sendable {
        let scalars: [UInt32]
        let bonuses: [Int8]
        public var isEmpty: Bool { scalars.isEmpty }

        /// `folded` is the searched form; `original` gives camelCase boundaries when it folds to the same length.
        public init(folded: String, original: String? = nil) {
            scalars = folded.unicodeScalars.map(\.value)
            let source = original.map { Array($0.unicodeScalars) }
            let classes = (source?.count == scalars.count ? source! : Array(folded.unicodeScalars)).map(FuzzyMatch.characterClass)
            var previous = CharacterClass.white
            bonuses = classes.map { current in
                defer { previous = current }
                return Int8(FuzzyMatch.bonus(previous, current))
            }
        }
    }

    static func characterClass(_ scalar: Unicode.Scalar) -> CharacterClass {
        if scalar.properties.isWhitespace { return .white }
        if "/,:;|-_.".unicodeScalars.contains(scalar) { return .delimiter }
        if scalar.properties.numericType != nil { return .number }
        if scalar.properties.isLowercase { return .lower }
        if scalar.properties.isUppercase { return .upper }
        if scalar.properties.isAlphabetic { return .letter }
        return .nonWord
    }

    static func bonus(_ previous: CharacterClass, _ current: CharacterClass) -> Int32 {
        let word = current.rawValue > CharacterClass.delimiter.rawValue
        if word {
            switch previous {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if previous == .lower && current == .upper || previous != .number && current == .number { return bonusCamel }
        switch current {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// Reused between calls so scoring a catalogue allocates once per keystroke, not once per row.
    public final class Scratch {
        var scores: [Int32] = []
        var runs: [Int16] = []
        public init() {}
    }

    /// The best score of `pattern` in `text`, or nil when its characters do not all appear in order.
    public static func score(_ pattern: [UInt32], in text: Text, scratch: Scratch = Scratch()) -> Int32? {
        let n = pattern.count, m = text.scalars.count
        guard n > 0, n <= m else { return n == 0 ? 0 : nil }
        // Where the first character can start and the last can end; nothing outside can be part of a match.
        var first = -1, index = 0
        for (position, scalar) in text.scalars.enumerated() where scalar == pattern[index] {
            if index == 0 { first = position }
            index += 1
            if index == n { break }
        }
        guard index == n else { return nil }
        var last = m - 1
        while text.scalars[last] != pattern[n - 1] { last -= 1 }
        let width = last - first + 1
        let size = n * width
        if scratch.scores.count < size { scratch.scores = [Int32](repeating: 0, count: size); scratch.runs = [Int16](repeating: 0, count: size) }
        return text.scalars.withUnsafeBufferPointer { scalars in
            text.bonuses.withUnsafeBufferPointer { bonuses in
                scratch.scores.withUnsafeMutableBufferPointer { scores in
                    scratch.runs.withUnsafeMutableBufferPointer { runs in
                        var best: Int32 = 0
                        for row in 0..<n {
                            let character = pattern[row]
                            var inGap = false
                            let base = row * width
                            for column in 0..<width {
                                let position = first + column
                                let left = column > 0 ? scores[base + column - 1] : 0
                                let gap = left > 0 ? left + (inGap ? gapExtension : gapStart) : 0
                                var match: Int32 = 0, run: Int16 = 0
                                let diagonal: Int32 = row == 0 ? 1 : (column > 0 ? scores[base - width + column - 1] : 0)
                                if scalars[position] == character, diagonal > 0, column >= row {
                                    var bonus = Int32(bonuses[position])
                                    run = row > 0 && column > 0 ? runs[base - width + column - 1] + 1 : 1
                                    if run > 1 {
                                        let start = Int32(bonuses[position - Int(run) + 1])
                                        if bonus >= bonusBoundary && bonus > start { run = 1 }
                                        else { bonus = max(bonus, max(bonusConsecutive, start)) }
                                    }
                                    match = (row == 0 ? 0 : diagonal) + scoreMatch + (row == 0 ? bonus * firstCharMultiplier : bonus)
                                    if match < gap { match = 0; run = 0 }
                                }
                                let value = max(match, gap)
                                inGap = match < gap || match == 0
                                scores[base + column] = value
                                runs[base + column] = match > 0 ? run : 0
                                if row == n - 1, match > 0, match > best { best = match }
                            }
                        }
                        return best > 0 ? best : nil
                    }
                }
            }
        }
    }

    public static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }
}
