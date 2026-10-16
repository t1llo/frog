import Foundation

/// What the command bar learned from the rows picked for typed text. Strengths are stored as of their `last`
/// pick and decayed when read; time is always passed in.
public struct CommandChoices: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    /// A row picked after typing `text`, which is already cut and folded by `key`.
    public struct Pair: Codable, Equatable, Sendable {
        public var text: String
        public var id: String
        public var strength: Double
        public var last: Date
        public init(text: String, id: String, strength: Double, last: Date) {
            self.text = text; self.id = id; self.strength = strength; self.last = last
        }
    }
    /// A row picked for any text, the opening list included.
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var strength: Double
        public var last: Date
        public init(id: String, strength: Double, last: Date) {
            self.id = id; self.strength = strength; self.last = last
        }
    }
    public var pairs: [Pair] = []
    public var items: [Item] = []

    public init() {}

    public enum Tuning {
        public static let halfLife: TimeInterval = 14 * 86_400
        public static let pairCap = 5.0, itemCap = 10.0, competitorFactor = 0.5, dropBelow = 0.1
        public static let prefixWeight = 0.5, latchThreshold = 2.0
        /// Two picks a minute apart give a little less than 2, because the first faded in between. Up to this
        /// much less still latches, so two picks in one sitting latch as two at the same instant do; alternating
        /// picks, which approach 2 from below, would need about fifteen in a row.
        public static let latchTolerance = 0.01
        public static let textLength = 32, maxPairs = 500, maxItems = 300, maxFileBytes = 512 * 1024, maxIDBytes = 1_024
    }

    /// The bar's search key with runs of whitespace collapsed, in one canonical form so equal text has equal
    /// bytes, cut to its first 32 characters without splitting one.
    public static func key(_ typed: String) -> String {
        let collapsed = CommandSearch.searchKey(typed).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.precomposedStringWithCanonicalMapping.prefix(Tuning.textLength))
    }

    /// Clipboard rows may hold secrets, windows are minted per snapshot and calculations are answers, not rows.
    public static func isRememberable(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= Tuning.maxIDBytes
            && !["clipboard:", "window:", "calculation:"].contains { id.utf8.starts(with: $0.utf8) }
    }

    public static func decayed(_ strength: Double, since last: Date, now: Date) -> Double {
        strength * pow(0.5, max(0, now.timeIntervalSince(last)) / Tuning.halfLife)
    }

    /// A pick of `id` after typing `typed`. Other rows picked for the same text lose half their strength, so
    /// picking a new row twice replaces an old habit.
    public mutating func record(typed: String, id: String, now: Date) {
        guard Self.isRememberable(id) else { return }
        let text = Self.key(typed)
        if !text.isEmpty {
            var found = false
            for index in pairs.indices where pairs[index].text.utf8.elementsEqual(text.utf8) {
                let value = Self.decayed(pairs[index].strength, since: pairs[index].last, now: now)
                if pairs[index].id == id {
                    pairs[index].strength = min(value + 1, Tuning.pairCap); found = true
                } else {
                    pairs[index].strength = value * Tuning.competitorFactor
                }
                pairs[index].last = now
            }
            if !found { pairs.append(Pair(text: text, id: id, strength: 1, last: now)) }
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].strength = min(Self.decayed(items[index].strength, since: items[index].last, now: now) + 1, Tuning.itemCap)
            items[index].last = now
        } else {
            items.append(Item(id: id, strength: 1, last: now))
        }
        prune(now: now)
    }

    /// Drops what has faded below 0.1 and keeps the strongest 500 pairs and 300 items. Values a file should
    /// never hold (no finite strength, a date ahead of `now`, a row that is never remembered) are mended or dropped.
    public mutating func prune(now: Date) {
        pairs = Self.strongest(pairs.compactMap { pair in
            var pair = pair
            guard Self.mend(&pair.strength, &pair.last, cap: Tuning.pairCap, now: now), Self.isRememberable(pair.id),
                  !pair.text.isEmpty else { return nil }
            return pair
        }, limit: Tuning.maxPairs, now: now, strength: \.strength, last: \.last)
        items = Self.strongest(items.compactMap { item in
            var item = item
            guard Self.mend(&item.strength, &item.last, cap: Tuning.itemCap, now: now), Self.isRememberable(item.id) else { return nil }
            return item
        }, limit: Tuning.maxItems, now: now, strength: \.strength, last: \.last)
    }

    /// Forgets one row everywhere, such as a learned file that no longer exists.
    public mutating func forget(id: String) {
        pairs.removeAll { $0.id == id }
        items.removeAll { $0.id == id }
    }

    /// Drops the `count` weakest pairs, or items once no pair is left; keeps a file inside its size limit.
    mutating func dropWeakest(_ count: Int, now: Date) {
        if !pairs.isEmpty {
            pairs = Self.strongest(pairs, limit: max(0, pairs.count - count), now: now, strength: \.strength, last: \.last)
        } else {
            items = Self.strongest(items, limit: max(0, items.count - count), now: now, strength: \.strength, last: \.last)
        }
    }

    /// "Frog remembers N choices": each typed text with its row, and each row picked only from the opening
    /// list, which leads that list as well and must be something Forget can be pressed for.
    public var count: Int {
        let paired = Set(pairs.map(\.id))
        return pairs.count + items.reduce(0) { $0 + (paired.contains($1.id) ? 0 : 1) }
    }

    public func index(now: Date) -> CommandChoiceIndex { CommandChoiceIndex(self, now: now) }

    private static func mend(_ strength: inout Double, _ last: inout Date, cap: Double, now: Date) -> Bool {
        guard strength.isFinite, last.timeIntervalSinceReferenceDate.isFinite else { return false }
        strength = min(strength, cap)
        if last > now { last = now }
        return decayed(strength, since: last, now: now) >= Tuning.dropBelow
    }

    /// Keeps the strongest `limit` entries in their stored order; weakest out first, the older pick on a tie.
    private static func strongest<T>(_ entries: [T], limit: Int, now: Date, strength: KeyPath<T, Double>, last: KeyPath<T, Date>) -> [T] {
        guard entries.count > limit else { return entries }
        let kept = entries.indices.sorted { a, b in
            let left = decayed(entries[a][keyPath: strength], since: entries[a][keyPath: last], now: now)
            let right = decayed(entries[b][keyPath: strength], since: entries[b][keyPath: last], now: now)
            return left != right ? left > right : entries[a][keyPath: last] > entries[b][keyPath: last]
        }.prefix(limit).sorted()
        return kept.map { entries[$0] }
    }
}

/// The learned choices decayed once and sorted by the bytes of their text, so each keystroke is one binary search.
public struct CommandChoiceIndex: Sendable {
    public static let empty = CommandChoiceIndex(CommandChoices(), now: .distantPast)
    public let builtAt: Date
    private struct Entry: Sendable { let text: String; let id: String; let value: Double; let last: Date }
    private struct Ranked: Sendable { let id: String; let value: Double; let last: Date }
    private let entries: [Entry]
    private let items: [Ranked]

    init(_ choices: CommandChoices, now: Date) {
        builtAt = now
        entries = choices.pairs.map {
            Entry(text: $0.text, id: $0.id, value: CommandChoices.decayed($0.strength, since: $0.last, now: now), last: $0.last)
        }.sorted { $0.text.utf8.lexicographicallyPrecedes($1.text.utf8) }
        items = choices.items.map {
            Ranked(id: $0.id, value: CommandChoices.decayed($0.strength, since: $0.last, now: now), last: $0.last)
        }.sorted(by: Self.stronger)
    }

    /// Leading ids for the typed text, strongest first; `latched` is the one row allowed to lead everything.
    /// Text picked after typing more counts half: "calendar" helps "cal", less than "cal" itself would.
    public func suggestions(for typed: String) -> (leading: [String], latched: String?) {
        let query = Array(CommandChoices.key(typed).utf8)
        guard !query.isEmpty else { return ([], nil) }
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].text.utf8.lexicographicallyPrecedes(query) { low = middle + 1 } else { high = middle }
        }
        var best: [String: Ranked] = [:]
        var order: [String] = []
        for entry in entries[low...] {
            guard entry.text.utf8.starts(with: query) else { break }
            let value = entry.value * (entry.text.utf8.count == query.count ? 1 : CommandChoices.Tuning.prefixWeight)
            guard value > 0 else { continue }
            if let current = best[entry.id] {
                best[entry.id] = Ranked(id: entry.id, value: max(current.value, value), last: max(current.last, entry.last))
            } else {
                best[entry.id] = Ranked(id: entry.id, value: value, last: entry.last); order.append(entry.id)
            }
        }
        let ranked = order.compactMap { best[$0] }.sorted(by: Self.stronger)
        guard let top = ranked.first else { return ([], nil) }
        let threshold = CommandChoices.Tuning.latchThreshold - CommandChoices.Tuning.latchTolerance
        let latched = top.value >= threshold && (ranked.count == 1 || top.value > ranked[1].value)
        return (ranked.map(\.id), latched ? top.id : nil)
    }

    /// Item ids by decayed strength, then latest pick; for the opening list.
    public func frequentItems(limit: Int) -> [String] {
        items.prefix(max(0, limit)).map(\.id)
    }

    /// Item ids that start with `prefix`, strongest first, such as `file:` for learned files.
    public func items(withPrefix prefix: String) -> [String] {
        items.filter { $0.id.utf8.starts(with: prefix.utf8) }.map(\.id)
    }

    private static func stronger(_ a: Ranked, _ b: Ranked) -> Bool {
        a.value != b.value ? a.value > b.value : a.last > b.last
    }
}
