import Foundation

/// Spells values the way Frog writes them: valid TOML 1.0, one setting per line, readable first.
enum TOMLWriter {
    /// Lists longer than this, or holding several tables, get one item per line.
    static let lineWidth = 80
    static let indentUnit = "  "

    static func isBare(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
        }
    }

    static func key(_ key: String) -> String { isBare(key) ? key : basicString(key) }

    static func header(_ path: [String]) -> String { "[" + path.map(key).joined(separator: ".") + "]" }

    /// `indent` is the indentation of the line the value starts on; items of a list that spans
    /// lines are indented one step further. `multilineList` keeps a list on several lines.
    static func value(_ value: ConfigValue, indent: String = "", multilineList: Bool = false) -> String {
        switch value {
        case .bool(let bool): return bool ? "true" : "false"
        case .integer(let integer): return String(integer)
        case .float(let double): return float(double)
        case .string(let string): return string.contains("\n") ? multilineString(string) : basicString(string)
        case .table(let table): return inlineTable(table)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let inline = "[" + items.map { self.value($0, indent: indent) }.joined(separator: ", ") + "]"
            let tables = items.filter { $0.tableValue != nil }.count
            if !multilineList, tables < 2, !inline.contains("\n"), inline.count + indent.count <= lineWidth { return inline }
            let inner = indent + indentUnit
            return "[\n" + items.map { inner + self.value($0, indent: inner) + ",\n" }.joined() + indent + "]"
        }
    }

    static func float(_ double: Double) -> String {
        if double.isNaN { return "nan" }
        if double.isInfinite { return double < 0 ? "-inf" : "inf" }
        // Swift's shortest spelling reads back exactly and is valid TOML: 0.15, 1.0, 1e-07, 1e+20.
        let text = String(double)
        return text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? text : text + ".0"
    }

    static func inlineTable(_ table: ConfigTable) -> String {
        guard !table.isEmpty else { return "{}" }
        // Inline tables stay on one line in TOML 1.0, so lists inside them do too.
        return "{ " + table.map { "\(key($0.key)) = \(inlineValue($0.value))" }.joined(separator: ", ") + " }"
    }

    private static func inlineValue(_ value: ConfigValue) -> String {
        if case .array(let items) = value { return "[" + items.map(inlineValue).joined(separator: ", ") + "]" }
        if case .string(let string) = value { return basicString(string) }
        return self.value(value)
    }

    static func basicString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default: out += escapedControl(scalar) ?? String(scalar)
            }
        }
        return out + "\""
    }

    /// A string with line breaks, such as a prompt, spelled over several lines.
    static func multilineString(_ string: String) -> String {
        let scalars = Array(string.unicodeScalars)
        // Quotes at the very end would run into the closing delimiter.
        var trailingQuotes = 0
        for scalar in scalars.reversed() { if scalar == "\"" { trailingQuotes += 1 } else { break } }
        var out = "\"\"\"\n", run = 0
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\"" {
                run += 1
                // Never three quotes in a row: that would close the string.
                if run == 3 || index >= scalars.count - trailingQuotes { out += "\\\""; run = 0 } else { out += "\"" }
                continue
            }
            run = 0
            switch scalar {
            case "\\": out += "\\\\"
            case "\n", "\t": out.unicodeScalars.append(scalar)
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default: out += escapedControl(scalar) ?? String(scalar)
            }
        }
        return out + "\"\"\""
    }

    private static func escapedControl(_ scalar: Unicode.Scalar) -> String? {
        guard scalar.value < 0x20 || scalar.value == 0x7F else { return nil }
        return String(format: "\\u%04X", scalar.value)
    }
}
