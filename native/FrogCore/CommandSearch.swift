import Foundation

public struct SearchRecord: Identifiable, Equatable, Sendable {
    public enum QueryStyle: Sendable { case literal, command }
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: String
    public let symbol: String
    fileprivate let searchTitle: String
    fileprivate let searchText: String
    fileprivate let aliases: [String]
    fileprivate let fuzzyTitle: FuzzyMatch.Text
    fileprivate let fuzzyAliases: [FuzzyMatch.Text]
    fileprivate let queryStyle: QueryStyle
    /// Applications: what a search is usually for, so a title match ranks one tier higher. Their subtitle names
    /// the kind they all share and is not searched, or two of its letters would list every one of them.
    fileprivate let prominent: Bool
    public init(id: String, title: String, subtitle: String = "", keywords: String = "", symbol: String = "command", aliases: [String] = [], queryStyle: QueryStyle = .literal, prominent: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.keywords = keywords; self.symbol = symbol
        self.prominent = prominent
        self.aliases = aliases.map {
            let normalized = CommandSearch.normalized($0)
            return queryStyle == .command ? CommandSearch.commandSubject(normalized).joined(separator: " ") : normalized
        }.filter { !$0.isEmpty }
        self.queryStyle = queryStyle
        searchTitle = CommandSearch.normalized(title)
        fuzzyTitle = FuzzyMatch.Text(folded: searchTitle, original: title.trimmingCharacters(in: .whitespacesAndNewlines))
        fuzzyAliases = self.aliases.map { FuzzyMatch.Text(folded: $0) }
        searchText = searchTitle + " " + CommandSearch.normalized((prominent ? "" : subtitle + " ") + keywords) + (aliases.isEmpty ? "" : " " + self.aliases.joined(separator: " "))
    }
}

public enum CommandSearch {
    /// How the parts of a row's score add up. Each tier of title match is worth more than any fuzzy difference
    /// within one, applications rank a tier higher, and frecency moves a row at most a tier and a half.
    public enum Weights {
        public static let tier: [Double] = [0, 100, 200, 300]
        public static let application = 120.0
        public static let leading = 5.0
        public static let trailing = 15.0
        public static let frecency = 15.0
        public static let frecencyCap = 150.0
        /// A word found only in a row's keywords, subtitle or aliases' text, per character.
        public static let keyword: Int32 = 8
    }

    /// Rows that match every typed word, best first. A word matches a title or alias fuzzily (fzf v2 scoring) or the
    /// rest of the row's text as written. Within the score, `preferred` rows win ties and are never `trailing`,
    /// `trailing` rows lose them, and `boosts` (frecency, in learned strength) add up to `Weights.frecencyCap`.
    /// A `latched` record that matches leads every other; one that does not match is not listed.
    /// Without text, `preferred` rows lead in their order, then the catalogue.
    public static func results(_ records: [SearchRecord], query: String, limit: Int = 80, preferred: [SearchRecord] = [], trailing: [SearchRecord] = [], latched: String? = nil, boosts: [String: Double] = [:]) -> [SearchRecord] {
        let query = normalized(query)
        guard limit > 0 else { return [] }
        var preferredIDs = Set<String>()
        let preferred = preferred.filter { preferredIDs.insert($0.id).inserted }
        if query.isEmpty {
            var result = Array(preferred.prefix(limit))
            for record in records {
                if result.count == limit { break }
                if !preferredIDs.contains(record.id) { result.append(record) }
            }
            return result
        }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let subject = commandSubject(query)
        let canMatchCommand = !subject.isEmpty || words.contains { ["settings", "preferences", "system", "macos"].contains($0) }
        let commandWords = subject.isEmpty && canMatchCommand ? ["settings"] : subject
        let commandQuery = commandWords.joined(separator: " ")
        // "open safari" asks for Safari. Alone, such a word is looked for in the names.
        let named = words.filter { !applicationContext.contains($0) }
        let applicationWords = named.isEmpty ? words : named
        let applicationQuery = applicationWords.joined(separator: " ")
        let patterns = Dictionary((words + commandWords + applicationWords).map { ($0, FuzzyMatch.scalars($0)) }, uniquingKeysWith: { first, _ in first })
        let scratch = FuzzyMatch.Scratch()
        var scored: [(record: SearchRecord, score: Double)] = []
        var listed = Set<String>()
        func consider(_ record: SearchRecord, leading: Bool = false, trailing: Bool = false) {
            guard listed.insert(record.id).inserted else { return }
            if record.queryStyle == .command && !canMatchCommand { return }
            let words = record.queryStyle == .command ? commandWords : record.prominent ? applicationWords : words
            let effectiveQuery = record.queryStyle == .command ? commandQuery : record.prominent ? applicationQuery : query
            var fuzzy: Int32 = 0
            for word in words {
                guard let found = match(word, patterns[word] ?? FuzzyMatch.scalars(word), in: record, scratch: scratch) else { return }
                fuzzy += found
            }
            let title = record.searchTitle
            let tier = title == query || title == effectiveQuery || record.aliases.contains(effectiveQuery) ? 3
                : title.hasPrefix(effectiveQuery) || record.aliases.contains(where: { $0.hasPrefix(effectiveQuery) }) ? 2
                : title.contains(effectiveQuery) ? 1 : 0
            var score = Double(fuzzy) + Weights.tier[tier]
            // An app leads equal letters elsewhere; a scattered match earns it half the lift.
            if record.prominent { score += tier > 0 ? Weights.application : Weights.application / 2 }
            if leading { score += Weights.leading } else if trailing { score -= Weights.trailing }
            if let boost = boosts[record.id] { score += min(boost * Weights.frecency, Weights.frecencyCap) }
            if record.id == latched { score = .infinity }
            scored.append((record, score))
        }
        for record in preferred { consider(record, leading: true) }
        for record in records { consider(record) }
        for record in trailing { consider(record, trailing: true) }
        // A stable sort: equal scores keep the order the rows were offered in.
        let order = scored.indices.sorted { scored[$0].score != scored[$1].score ? scored[$0].score > scored[$1].score : $0 < $1 }
        return order.prefix(limit).map { scored[$0].record }
    }

    /// The best score of one typed word in a row: fuzzily in its title or aliases, else as written in the rest.
    private static func match(_ word: String, _ pattern: [UInt32], in record: SearchRecord, scratch: FuzzyMatch.Scratch) -> Int32? {
        var best = FuzzyMatch.score(pattern, in: record.fuzzyTitle, scratch: scratch)
        for alias in record.fuzzyAliases {
            if let score = FuzzyMatch.score(pattern, in: alias, scratch: scratch), score > (best ?? 0) { best = score }
        }
        // Scattered letters in a long title are noise: each character must earn most of a plain match.
        if let found = best, found >= Int32(pattern.count) * (FuzzyMatch.scoreMatch - 4) { return found }
        return record.searchText.contains(word) ? Int32(pattern.count) * Weights.keyword : nil
    }

    private static let applicationContext: Set<String> = ["open", "launch", "app"]
    private static let commandContext: Set<String> = ["change", "set", "adjust", "configure", "open", "show", "find", "enable", "disable", "turn", "on", "off", "my", "the", "a", "an", "please", "how", "do", "i", "to", "me", "mac", "macos", "system", "settings", "preferences", "and", "can", "where", "is", "are", "all"]
    fileprivate static func commandSubject(_ query: String) -> [String] {
        query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !commandContext.contains($0) }
    }
    /// The text the bar compares: case and diacritics folded, outer whitespace trimmed.
    public static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    fileprivate static func normalized(_ value: String) -> String { searchKey(value) }
}

/// A bounded arithmetic grammar, never a shell, JavaScript or Objective-C expression.
public enum QuickCalculation {
    public static func result(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 256 else { return nil }
        if let converted = convert(text) { return converted }
        guard text.contains(where: { "+-*/^%()".contains($0) }), text.contains(where: \.isNumber), !namesADay(text) else { return nil }
        var parser = Parser(Array(text))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return format(value)
    }
    /// `2025-1-15` and `15/1/2025`: two short groups and a year at one end, joined without spaces by one sign.
    /// That is a day, and usually a file named after it, so no answer may stand above the matches.
    private static func namesADay(_ text: String) -> Bool {
        ["-", "/"].contains { (sign: Character) in
            let groups = text.split(separator: sign, omittingEmptySubsequences: false)
            guard groups.count == 3, groups.joined().allSatisfy({ ("0"..."9").contains($0) }) else { return false }
            let lengths = groups.map(\.count)
            return (1...2).contains(lengths[1]) && (lengths[0] == 4 && (1...2).contains(lengths[2]) || (1...2).contains(lengths[0]) && lengths[2] == 4)
        }
    }
    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 10; formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    private static func convert(_ text: String) -> String? {
        let parts = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 4, ["to", "in"].contains(parts[2]), let value = Double(parts[0]), value.isFinite,
              let from = units[parts[1]], let to = units[parts[3]], type(of: from) == type(of: to) else { return nil }
        let converted = Measurement(value: value, unit: from).converted(to: to).value
        return converted.isFinite ? "\(format(converted)) \(parts[3])" : nil
    }
    private static let units: [String: Dimension] = [
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
        "in": UnitLength.inches, "ft": UnitLength.feet, "yd": UnitLength.yards, "mi": UnitLength.miles,
        "g": UnitMass.grams, "kg": UnitMass.kilograms, "oz": UnitMass.ounces, "lb": UnitMass.pounds,
        "c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
        "s": UnitDuration.seconds, "min": UnitDuration.minutes, "h": UnitDuration.hours,
        "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons,
        "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes,
        "mb": UnitInformationStorage.megabytes, "gb": UnitInformationStorage.gigabytes,
        "kib": UnitInformationStorage.kibibytes, "mib": UnitInformationStorage.mebibytes, "gib": UnitInformationStorage.gibibytes
    ]
    private struct Parser {
        let input: [Character]
        var index = 0
        var depth = 0
        init(_ input: [Character]) { self.input = input }
        mutating func skip() { while index < input.count, input[index].isWhitespace { index += 1 } }
        var atEnd: Bool { mutating get { skip(); return index == input.count } }
        mutating func take(_ token: Character) -> Bool {
            skip(); guard index < input.count, input[index] == token else { return false }; index += 1; return true
        }
        mutating func expression() -> Double? {
            guard var value = product() else { return nil }
            while true {
                if take("+") { guard let next = product() else { return nil }; value += next }
                else if take("-") { guard let next = product() else { return nil }; value -= next }
                else { return value }
            }
        }
        mutating func product() -> Double? {
            guard var value = unary() else { return nil }
            while true {
                if take("*") { guard let next = unary() else { return nil }; value *= next }
                else if take("/") { guard let next = unary(), next != 0 else { return nil }; value /= next }
                else { return value }
            }
        }
        mutating func unary() -> Double? {
            depth += 1; defer { depth -= 1 }; guard depth <= 32 else { return nil }
            if take("-") { return unary().map { -$0 } }
            if take("+") { return unary() }
            return power()
        }
        mutating func power() -> Double? {
            guard var value = atom() else { return nil }
            if take("%") { value /= 100 }
            if take("^") { guard let exponent = unary() else { return nil }; value = pow(value, exponent) }
            return value
        }
        mutating func atom() -> Double? {
            depth += 1; defer { depth -= 1 }; guard depth <= 32 else { return nil }
            if take("(") { guard let value = expression(), take(")") else { return nil }; return value }
            skip(); let start = index
            while index < input.count, input[index].isNumber || input[index] == "." { index += 1 }
            // No written number starts with a spare zero. `01` belongs to a date or a file name.
            if index - start > 1, input[start] == "0", input[start + 1] != "." { return nil }
            return Double(String(input[start..<index]))
        }
    }
}
