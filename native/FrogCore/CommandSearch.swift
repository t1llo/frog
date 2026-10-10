import Foundation

public struct SearchRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: String
    public let symbol: String
    fileprivate let searchTitle: String
    fileprivate let searchText: String
    public init(id: String, title: String, subtitle: String = "", keywords: String = "", symbol: String = "command") {
        self.id = id; self.title = title; self.subtitle = subtitle; self.keywords = keywords; self.symbol = symbol
        searchTitle = CommandSearch.normalized(title)
        searchText = searchTitle + " " + CommandSearch.normalized(subtitle + " " + keywords)
    }
}

public enum CommandSearch {
    public static func results(_ records: [SearchRecord], query: String, limit: Int = 80) -> [SearchRecord] {
        let query = normalized(query)
        guard limit > 0 else { return [] }
        if query.isEmpty { return Array(records.prefix(limit)) }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Four stable rank buckets avoid sorting the entire catalogue on every keystroke.
        var ranked = [[SearchRecord]](repeating: [], count: 4)
        for record in records {
            let title = record.searchTitle
            guard words.allSatisfy({ record.searchText.contains($0) }) else { continue }
            let rank = title == query ? 3 : title.hasPrefix(query) ? 2 : title.contains(query) ? 1 : 0
            if ranked[rank].count < limit { ranked[rank].append(record) }
        }
        return Array(ranked.reversed().joined().prefix(limit))
    }
    fileprivate static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A bounded arithmetic grammar, never a shell, JavaScript or Objective-C expression.
public enum QuickCalculation {
    public static func result(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 256 else { return nil }
        if let converted = convert(text) { return converted }
        guard text.contains(where: { "+-*/^%()".contains($0) }), text.contains(where: \.isNumber) else { return nil }
        var parser = Parser(Array(text))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return format(value)
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
            return Double(String(input[start..<index]))
        }
    }
}
