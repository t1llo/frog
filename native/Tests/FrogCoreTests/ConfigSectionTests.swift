import XCTest
@testable import FrogCore

private struct DictationSettings: ConfigSection {
    enum Mode: String, Codable, CaseIterable, Sendable { case toggle, hold }
    struct Recording: ConfigSection {
        var muteAudio = false
        var popup = true
    }
    struct Rule: ConfigSection {
        var name = ""
        var languageCode = "en"
    }
    var mode = Mode.toggle
    var muteAudio = false
    var maxSeconds = 300
    var gain = 1.0
    var microphoneID: String?
    var languages = ["en"]
    var shortcut = try! Shortcut("ctrl+alt+d")
    var recording = Recording()
    var rules: [Rule] = []
    var extra: [String: Bool] = [:]

    static let comments = [
        "": "Dictation: speak, and Frog types it.",
        "mode": "toggle: press once to start, again to stop\nhold: record while the shortcut is held",
        "recording": "While recording",
        "recording.mute-audio": "Mutes other audio",
    ]
}

private struct CoreSettings: ConfigSection {
    struct Palette: ConfigSection {
        var dark: [String: String] = [:]
    }
    var theme = "minimal"
    var transparency = 0.0
    var palette = Palette()
}

final class ConfigSectionTests: XCTestCase {
    func testKebabCaseSpelling() {
        XCTAssertEqual(ConfigKeys.kebab("muteAudio"), "mute-audio")
        XCTAssertEqual(ConfigKeys.kebab("llmURL"), "llm-url")
        XCTAssertEqual(ConfigKeys.kebab("URLPath"), "url-path")
        XCTAssertEqual(ConfigKeys.kebab("f1Key"), "f1-key")
        XCTAssertEqual(ConfigKeys.kebab("mode"), "mode")
        XCTAssertEqual(ConfigKeys.kebab("command-bar"), "command-bar")
        XCTAssertEqual(ConfigKeys.camel("mute-audio"), "muteAudio")
    }

    func testMissingKeysTakeTheDefaults() throws {
        let document = try ConfigDocument(parsing: "[dictation]\nmode = \"hold\"\n\n[dictation.recording]\npopup = false\n")
        let (settings, warnings) = try document.section("dictation", as: DictationSettings.self)
        var expected = DictationSettings()
        expected.mode = .hold
        expected.recording.popup = false
        XCTAssertEqual(settings, expected)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(try ConfigDocument().section("dictation", as: DictationSettings.self).value, DictationSettings())
    }

    func testEveryKindOfValueDecodes() throws {
        let document = try ConfigDocument(parsing: """
        [dictation]
        mode = "hold"
        mute-audio = true
        max-seconds = 60
        gain = 2
        microphone-id = "BuiltInMic"
        languages = ["de", "fr"]
        shortcut = "Cmd+Shift+Space"
        rules = [{ name = "a" }, { name = "b", language-code = "de" }]
        recording = { mute-audio = true }
        extra = { command-bar = true, Mixed = false }
        """)
        let settings = try document.section("dictation", as: DictationSettings.self).value
        XCTAssertEqual(settings.mode, .hold)
        XCTAssertTrue(settings.muteAudio)
        XCTAssertEqual(settings.maxSeconds, 60)
        XCTAssertEqual(settings.gain, 2)
        XCTAssertEqual(settings.microphoneID, "BuiltInMic")
        XCTAssertEqual(settings.languages, ["de", "fr"])
        XCTAssertEqual(settings.shortcut.description, "shift+cmd+space")
        XCTAssertEqual(settings.rules, [.init(name: "a", languageCode: "en"), .init(name: "b", languageCode: "de")])
        XCTAssertEqual(settings.recording, .init(muteAudio: true, popup: true))
        XCTAssertEqual(settings.extra, ["command-bar": true, "Mixed": false])
    }

    func testUnknownKeysAreWarningsWithTheirLines() throws {
        let document = try ConfigDocument(parsing: """
        theme = "nord"
        future-core = 1

        [dictation]
        mode = "hold"
        new-option = true

        [dictation.recording]
        later = "x"

        [dictation.future]
        a = 1

        [other-plugin]
        b = 2
        """)
        let dictation = try document.section("dictation", as: DictationSettings.self)
        XCTAssertEqual(dictation.value.mode, .hold)
        XCTAssertEqual(dictation.warnings.map(\.description), [
            "line 6: [dictation] new-option: unknown key, ignored by this version of Frog",
            "line 9: [dictation.recording] later: unknown key, ignored by this version of Frog",
            "line 11: [dictation.future]: unknown key, ignored by this version of Frog",
        ])
        // Top-level tables are other sections; only unknown top-level keys are warned about.
        let core = try document.core(as: CoreSettings.self)
        XCTAssertEqual(core.value.theme, "nord")
        XCTAssertEqual(core.warnings.map(\.description), ["line 2: future-core: unknown key, ignored by this version of Frog"])
    }

    func testTypeMismatchesNameTheKeyAndLine() throws {
        let cases: [(String, String)] = [
            ("[dictation]\n\nmode = \"loud\"\n", "line 3: [dictation] mode: expected one of toggle, hold"),
            ("[dictation]\nmode = 1\n", "line 2: [dictation] mode: expected one of toggle, hold"),
            ("[dictation]\nmax-seconds = \"a\"\n", "line 2: [dictation] max-seconds: expected an integer, found a string"),
            ("[dictation]\nmax-seconds = 1.5\n", "line 2: [dictation] max-seconds: expected an integer, found a number"),
            ("[dictation.recording]\nmute-audio = \"yes\"\n", "line 2: [dictation.recording] mute-audio: expected true or false, found a string"),
            ("[dictation]\nlanguages = [\n  \"en\",\n  3,\n]\n", "line 4: [dictation] languages[1]: expected a string, found an integer"),
            ("[dictation]\nrules = [{ language-code = \"de\" }, { name = 5 }]\n", "line 2: [dictation] rules[1].name: expected a string, found an integer"),
            ("[dictation]\nshortcut = \"shift+a\"\n", "line 2: [dictation] shortcut: expected a shortcut such as \"ctrl+alt+space\": a global shortcut needs ctrl, alt or cmd"),
            ("dictation = 5\n", "line 1: dictation: expected a table, found an integer"),
        ]
        for (text, message) in cases {
            let document = try ConfigDocument(parsing: text)
            XCTAssertThrowsError(try document.section("dictation", as: DictationSettings.self), text) { error in
                XCTAssertEqual((error as? ConfigError)?.kind, .value, text)
                XCTAssertEqual("\(error)", message, text)
            }
        }
    }

    func testUpdateWritesOnlyWhatDiffersFromTheDefaults() throws {
        var document = ConfigDocument()
        try document.update("dictation", DictationSettings())
        XCTAssertEqual(document.text, "", "defaults need no table")
        var settings = DictationSettings()
        settings.mode = .hold
        settings.recording.muteAudio = true
        settings.microphoneID = "Mic"
        try document.update("dictation", settings)
        XCTAssertEqual(document.text, """
        # Dictation: speak, and Frog types it.
        [dictation]
        # toggle: press once to start, again to stop
        # hold: record while the shortcut is held
        mode = "hold"
        microphone-id = "Mic"

        # While recording
        [dictation.recording]
        # Mutes other audio
        mute-audio = true

        """)
        XCTAssertEqual(try ConfigDocument(parsing: document.text).section("dictation", as: DictationSettings.self).value, settings)
    }

    func testUpdateKeepsKeysTheFileHasEvenAtTheirDefault() throws {
        var document = try ConfigDocument(parsing: """
        [dictation]
        mode = "toggle"   # I like it explicit
        max-seconds = 60
        microphone-id = "Mic"
        newer-key = 1
        extra = { a = true, b = true }

        """)
        var settings = try document.section("dictation", as: DictationSettings.self).value
        settings.maxSeconds = 300   // back to the default, but the file has the key
        settings.microphoneID = nil
        settings.extra = ["a": true]
        settings.gain = 1.5
        try document.update("dictation", settings)
        XCTAssertEqual(document.text, """
        [dictation]
        mode = "toggle"   # I like it explicit
        max-seconds = 300
        newer-key = 1
        extra = { a = true }
        gain = 1.5

        """)
    }

    func testUpdatingWithUnchangedValuesKeepsTheirSpelling() throws {
        let text = "[dictation]\nmax-seconds = 0x3C\ngain = 1.50\nlanguages = [ 'en' ]\n"
        var document = try ConfigDocument(parsing: text)
        let settings = try document.section("dictation", as: DictationSettings.self).value
        try document.update("dictation", settings)
        XCTAssertEqual(document.text, text)
    }

    func testRenderAllWritesEveryKeyForAStarterFile() throws {
        var document = ConfigDocument()
        try document.update("dictation", DictationSettings(), all: true)
        let text = document.text
        for line in ["mode = \"toggle\"", "mute-audio = false", "max-seconds = 300", "gain = 1.0", "languages = [\"en\"]",
                     "shortcut = \"ctrl+alt+d\"", "rules = []", "[dictation.recording]", "popup = true", "# Mutes other audio"] {
            XCTAssertTrue(text.contains(line + "\n"), "\(line) in\n\(text)")
        }
        XCTAssertFalse(text.contains("microphone-id"))
        XCTAssertEqual(try ConfigDocument(parsing: text).section("dictation", as: DictationSettings.self).warnings, [])
    }

    func testCoreSectionUsesTopLevelKeysAndTables() throws {
        var document = try ConfigDocument(parsing: "# Frog\n\n[plugins]\nwriting = true\n")
        var core = CoreSettings()
        core.theme = "nord"
        core.palette.dark = ["background": "#1A1B26"]
        try document.updateCore(core)
        XCTAssertEqual(document.text, "# Frog\n\ntheme = \"nord\"\n\n[plugins]\nwriting = true\n\n[palette.dark]\nbackground = \"#1A1B26\"\n")
        XCTAssertEqual(try document.core(as: CoreSettings.self).value, core)
    }

    func testPluginSwitches() throws {
        var document = try ConfigDocument(parsing: "[plugins]\nwriting = true\ncommand-bar = false\n")
        XCTAssertEqual(try document.pluginSwitches(), ["writing": true, "command-bar": false])
        try document.setPlugin("command-bar", enabled: true)
        try document.setPlugin("phone", enabled: true)
        XCTAssertEqual(document.text, "[plugins]\nwriting = true\ncommand-bar = true\nphone = true\n")
        XCTAssertThrowsError(try ConfigDocument(parsing: "[plugins]\n\nwriting = 1\n").pluginSwitches()) {
            XCTAssertEqual("\($0)", "line 3: [plugins] writing: expected true or false, found an integer")
        }
    }
}
