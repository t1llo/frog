import XCTest
@testable import FrogCore

final class ConfigDocumentTests: XCTestCase {
    private let tricky = """
    \u{FEFF}# Frog — settings ✓
    theme   =   "tokyoNight"   # spaced out
    transparency=0.15
    'quoted key' = 'C:\\no\\escapes'
    "ünï" = "\\u00e9t\\u00E9 \\t tab"

    [dictation]   # the dictation plugin
      mode = "hold"
      prompt = \"\"\"
    Clean up the transcript.
    Keep "quotes" and \\\\backslashes.\"\"\"
      literal = '''
    raw \\n stays'''
    languages = [
      "en",   # first
      "de",
    ]

    [dictation.recording]
    mute-audio = true
    inline = { a = 1, b = [1, 2], c = { d = "x" } }
    numbers = [0x1F, 0o17, 0b101, 1_000, -3, +4, 1e3, -2.5E-3, inf, -inf, nan]
    """

    func testAnUnchangedDocumentRendersItsExactBytes() throws {
        for text in [tricky, tricky.replacingOccurrences(of: "\n", with: "\r\n"), tricky + "\n", "", "\n\n", "# only a comment", "a = 1"] {
            let document = try ConfigDocument(parsing: text)
            XCTAssertEqual(document.text, text)
            XCTAssertEqual(document.data, Data(text.utf8))
        }
    }

    func testValuesReadAsTOML() throws {
        let document = try ConfigDocument(parsing: tricky)
        XCTAssertEqual(document.value(at: ["theme"]), "tokyoNight")
        XCTAssertEqual(document.value(at: ["transparency"]), .float(0.15))
        XCTAssertEqual(document.value(at: ["quoted key"]), "C:\\no\\escapes")
        XCTAssertEqual(document.value(at: ["ünï"]), "été \t tab")
        XCTAssertEqual(document.value(at: ["dictation", "prompt"]), "Clean up the transcript.\nKeep \"quotes\" and \\backslashes.")
        XCTAssertEqual(document.value(at: ["dictation", "literal"]), "raw \\n stays")
        XCTAssertEqual(document.value(at: ["dictation", "languages"]), ["en", "de"])
        XCTAssertEqual(document.value(at: ["dictation", "recording", "inline"]), ["a": 1, "b": [1, 2], "c": ["d": "x"]])
        guard case .array(let numbers)? = document.value(at: ["dictation", "recording", "numbers"]) else { return XCTFail() }
        XCTAssertEqual(Array(numbers.prefix(9)), [31, 15, 5, 1000, -3, 4, .float(1000), .float(-0.0025), .float(.infinity)])
        XCTAssertEqual(numbers[9], .float(-.infinity))
        XCTAssertTrue(numbers[10].doubleValue?.isNaN == true)
    }

    func testMultilineStringsWithCRLFReadAsLineFeeds() throws {
        let document = try ConfigDocument(parsing: "p = \"\"\"\r\none\r\ntwo\"\"\"\r\n")
        XCTAssertEqual(document.value(at: ["p"]), "one\ntwo")
        XCTAssertEqual(document.text, "p = \"\"\"\r\none\r\ntwo\"\"\"\r\n")
    }

    func testErrorsNameTheLineAndColumn() {
        let cases: [(String, Int, Int, String)] = [
            ("a = 1\nb =\n", 2, 4, "expected a value after '='"),
            ("a = 1\nb = # nothing\n", 2, 5, "expected a value after '='"),
            ("a = 1\na = 2\n", 2, 1, "duplicate key 'a'; it is already set on line 1"),
            ("[t]\n[t]\n", 2, 1, "duplicate table [t]; it is already on line 1"),
            ("mode = hold\n", 1, 8, "expected a value, found 'hold'; strings need quotes, such as \"hold\""),
            ("a = \"open\n", 1, 10, "the string is missing its closing quote"),
            ("a = 1 2\n", 1, 7, "unexpected text after the value; start a comment with '#'"),
            ("a.b = 1\n", 1, 2, "dotted keys such as 'a.…' are not supported; put the key under a [a] table"),
            ("[[items]]\n", 1, 2, "lists of tables ([[...]]) are not supported; use a list of inline tables, such as items = [{ name = \"a\" }]"),
            ("d = 2024-01-01\n", 1, 5, "dates and times are not supported; write them as a string"),
            ("a = [1, 2\n", 2, 1, "the list is missing its closing ']'"),
            ("a = { b = 1,\n", 1, 13, "an inline table must close on the line it opens; use a [table] for longer ones"),
            ("a = { b = 1, }\n", 1, 14, "an inline table takes no comma before '}'"),
            ("a = 1\n[a]\n", 2, 1, "'a' is already set to a value on line 1"),
            ("a = { b = 1 }\n[a.c]\n", 2, 1, "'a' is already set to a value on line 1, so it cannot hold a table"),
            ("a = \"\\q\"\n", 1, 6, "unknown escape '\\q'; use \\\\ for a backslash"),
            ("a = 012\n", 1, 5, "'012' is not a valid number"),
            ("a = 99999999999999999999\n", 1, 5, "'99999999999999999999' is too large for an integer"),
            ("\"ünï\" = = 1\n", 1, 9, "expected a value after '='"),
            ("ünï = 1\n", 1, 1, "unexpected 'ü'; keys use letters, digits, '-' and '_', or quotes"),
        ]
        for (text, line, column, message) in cases {
            XCTAssertThrowsError(try ConfigDocument(parsing: text), text) { error in
                guard let error = error as? ConfigError else { return XCTFail("\(error)") }
                XCTAssertEqual(error.kind, .syntax, text)
                XCTAssertEqual(error.message, message, text)
                XCTAssertEqual(error.line, line, text)
                XCTAssertEqual(error.column, column, text)
                XCTAssertEqual(error.description, "line \(line): \(message)", text)
            }
        }
    }

    func testSettingAnExistingValueRewritesOnlyThatValue() throws {
        var document = try ConfigDocument(parsing: "# head\n  theme   =   \"nord\"   # spaced out\r\nother = 1\n")
        try document.setValue("dracula", at: ["theme"])
        XCTAssertEqual(document.text, "# head\n  theme   =   \"dracula\"   # spaced out\r\nother = 1\n")
    }

    func testAMultilineValueIsReplacedWholeAndAListStaysMultiline() throws {
        var document = try ConfigDocument(parsing: tricky)
        try document.setValue(["fr", "it"], at: ["dictation", "languages"])
        try document.setValue("Short.", at: ["dictation", "prompt"])
        XCTAssertTrue(document.text.contains("languages = [\n  \"fr\",\n  \"it\",\n]\n\n[dictation.recording]"), document.text)
        XCTAssertTrue(document.text.contains("  prompt = \"Short.\"\n  literal = '''"), document.text)
        try document.setValue("Two\nlines", at: ["dictation", "prompt"])
        XCTAssertEqual(document.value(at: ["dictation", "prompt"]), "Two\nlines")
        XCTAssertTrue(document.text.contains("  prompt = \"\"\"\nTwo\nlines\"\"\"\n"), document.text)
    }

    func testNewKeysGoAfterTheLastKeyOfTheirTable() throws {
        var document = try ConfigDocument(parsing: """
        top = 1

        [a]
          x = 1   # kept

        # About b
        [b]
        y = 2

        """)
        try document.setValue(true, at: ["a", "new"])
        try document.setValue("v", at: ["top2"])
        try document.setValue(3, at: ["b", "z"])
        XCTAssertEqual(document.text, """
        top = 1
        top2 = "v"

        [a]
          x = 1   # kept
          new = true

        # About b
        [b]
        y = 2
        z = 3

        """)
    }

    func testNewTablesAreAppendedWithOneBlankLineBefore() throws {
        var document = try ConfigDocument(parsing: "a = 1")
        try document.setValue("hold", at: ["dictation", "mode"])
        XCTAssertEqual(document.text, "a = 1\n\n[dictation]\nmode = \"hold\"\n")
        try document.setValue(true, at: ["phone", "auto-send"])
        XCTAssertEqual(document.text, "a = 1\n\n[dictation]\nmode = \"hold\"\n\n[phone]\nauto-send = true\n")
        // A subtable joins its parent's family instead of going to the end.
        try document.setValue(true, at: ["dictation", "recording", "mute-audio"])
        XCTAssertEqual(document.text, "a = 1\n\n[dictation]\nmode = \"hold\"\n\n[dictation.recording]\nmute-audio = true\n\n[phone]\nauto-send = true\n")
        // A parent that only existed through its subtable gets its header before them.
        var parentless = try ConfigDocument(parsing: "[x.y]\nk = 1\n")
        try parentless.setValue(2, at: ["x", "k"])
        XCTAssertEqual(parentless.text, "[x]\nk = 2\n\n[x.y]\nk = 1\n")
    }

    func testRootKeysInAFileWithoutThemGoAfterItsHeading() throws {
        var document = try ConfigDocument(parsing: "# Frog settings\n\n[plugins]\nwriting = true\n")
        try document.setValue("nord", at: ["theme"])
        try document.setValue(0.2, at: ["transparency"])
        XCTAssertEqual(document.text, "# Frog settings\n\ntheme = \"nord\"\ntransparency = 0.2\n\n[plugins]\nwriting = true\n")
    }

    func testCRLFFilesGetCRLFLines() throws {
        var document = try ConfigDocument(parsing: "a = 1\r\n")
        try document.setValue(2, at: ["b"])
        try document.setValue(3, at: ["t", "c"])
        XCTAssertEqual(document.text, "a = 1\r\nb = 2\r\n\r\n[t]\r\nc = 3\r\n")
    }

    func testRemovingAKeyRemovesOnlyItsLine() throws {
        var document = try ConfigDocument(parsing: "# about a\na = 1 # one\nb = 2\n\n[t]\nc = 3\nd = 4\n")
        try document.removeValue(at: ["a"])
        try document.removeValue(at: ["t", "d"])
        try document.removeValue(at: ["missing"])
        XCTAssertEqual(document.text, "# about a\nb = 2\n\n[t]\nc = 3\n")
        try document.removeValue(at: ["t"])
        XCTAssertEqual(document.text, "# about a\nb = 2\n\n")
    }

    func testInlineTablesAreEditedAsOneValue() throws {
        var document = try ConfigDocument(parsing: "point = { x = 1, y = 2 } # where\n")
        try document.setValue(5, at: ["point", "x"])
        try document.setValue(7, at: ["point", "z"])
        try document.removeValue(at: ["point", "y"])
        XCTAssertEqual(document.text, "point = { x = 5, z = 7 } # where\n")
        XCTAssertThrowsError(try document.setValue(1, at: ["point", "x", "deeper"]))
    }

    func testCommentsAreWrittenAboveNewKeysAndTables() throws {
        var document = ConfigDocument()
        try document.setValue(["mode": "hold", "mute-audio": true], at: ["dictation"]) { path in
            ["dictation": "Dictation", "dictation.mode": "toggle or hold\nhold: while the key is down"][path.joined(separator: ".")]
        }
        XCTAssertEqual(document.text, "# Dictation\n[dictation]\n# toggle or hold\n# hold: while the key is down\nmode = \"hold\"\nmute-audio = true\n")
    }

    func testWrittenValuesReadBackAsTheSameValues() throws {
        let values: [ConfigValue] = [
            "plain", "with \"quotes\" and \\ and \t", "line\nbreaks \"\"\" and \"quotes\"\"", "ends with quote\n\"", "\u{01} control", "",
            "üñí 🐸", 0, -12, .float(0.15), .float(1), .float(1e-7), .float(1e300), .float(-.infinity),
            true, [], [1, "two", [3.5]], ["a": 1, "b c": ["d": false]], [["name": "x"], ["name": "y"]],
            .array(Array(repeating: "a long string value", count: 6)),
        ]
        for value in values {
            var document = ConfigDocument()
            try document.setValue(value, at: ["t", "key"])
            let reread = try ConfigDocument(parsing: document.text)
            XCTAssertEqual(reread.value(at: ["t", "key"]), value, document.text)
        }
        var document = ConfigDocument()
        try document.setValue("quoted key", at: ["a b", "c.d"])
        XCTAssertEqual(document.text, "[\"a b\"]\n\"c.d\" = \"quoted key\"\n")
    }
}
