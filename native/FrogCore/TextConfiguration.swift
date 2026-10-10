import Foundation

/// A deliberately small key=value language. JSON remains the portable interchange format.
enum TextConfiguration {
    private enum Kind: Sendable {
        case bool, integer(ClosedRange<Int>), number(ClosedRange<Double>), string, choice([String]), color, shortcut, strings
    }
    private struct Field: Sendable {
        let key: String
        let path: [String]
        let kind: Kind
        init(_ key: String, _ path: String, _ kind: Kind) {
            self.key = key; self.path = path.split(separator: ".").map(String.init); self.kind = kind
        }
    }
    private static let fields: [Field] = {
        var fields: [Field] = [
            .init("history-enabled", "historyEnabled", .bool),
            .init("history-hide-text", "hideHistoryText", .bool),
            .init("history-limit", "historyLimit", .integer(1...200)),
            .init("history-retention-days", "historyRetentionDays", .integer(1...30)),
            .init("writing-indicator", "showProcessingIndicator", .bool),
            .init("feature.window-switcher", "windowSwitcherEnabled", .bool),
            .init("feature.application-shortcuts", "applicationShortcutsEnabled", .bool),
            .init("feature.clipboard", "workflows.clipboardHistoryEnabled", .bool),
            .init("language", "workflows.applicationLanguage", .choice(WorkflowPreferences.interfaceLanguages)),
            .init("transcription-language", "workflows.transcriptionLanguage", .choice(WorkflowPreferences.speechLanguages)),
            .init("audio-model", "workflows.audioModelID", .string),
            .init("cleanup-model", "workflows.cleanupModelID", .string),
            .init("text-model", "workflows.defaultLocalTextModelID", .string),
            .init("text-source", "workflows.textSource", .choice(["provider", "frog"])),
            .init("model-idle-seconds", "workflows.idleUnloadSeconds", .integer(0...3600)),
            .init("recording-mode", "workflows.recordingMode", .choice(["hold", "toggle"])),
            .init("recording-output", "workflows.output", .choice(["copy", "paste"])),
            .init("microphone", "workflows.microphoneID", .string),
            .init("recording-popup", "workflows.showDictationPopup", .bool),
            .init("recording-mute-audio", "workflows.muteWhileRecording", .bool),
            .init("shortcut.rules", "workflows.shortcutPanelHotkey", .shortcut),
            .init("shortcut.cancel-recording", "workflows.cancelRecordingHotkey", .shortcut),
            .init("shortcut.clipboard", "workflows.clipboardHistoryHotkey", .shortcut),
            .init("shortcut.command-bar", "toolkit.commandBarHotkey", .shortcut),
            .init("hidden-sidebar-items", "toolkit.hiddenSidebarItems", .strings),
            .init("usage.provider", "toolkit.usage.provider", .choice(["Claude", "OpenAI"])),
            .init("usage.range", "toolkit.usage.range", .choice(["24h", "7d", "30d"])),
            .init("usage.metric", "toolkit.usage.metric", .choice(["API cost", "Input", "Output", "Cache write", "Cache read"])),
            .init("usage.all-devices", "toolkit.usage.allDevices", .bool),
            .init("usage.login-source", "toolkit.usage.loginSource", .choice(["Automatic", "Claude Code", "OpenCode", "Pi"])),
            .init("menubar.auto-hide", "toolkit.menuBar.autoHide", .bool),
            .init("menubar.auto-hide-seconds", "toolkit.menuBar.autoHideSeconds", .number(1...3600)),
            .init("menubar.start-collapsed", "toolkit.menuBar.startCollapsed", .bool),
            .init("menubar.permanently-hidden-section", "toolkit.menuBar.permanentlyHiddenSection", .bool),
            .init("menubar.hover-to-reveal", "toolkit.menuBar.hoverToReveal", .bool),
            .init("menubar.hotkey", "toolkit.menuBar.hotkey", .shortcut),
            .init("appearance", "appearance.mode", .choice(AppearancePreferences.Mode.allCases.map(\.rawValue))),
            .init("theme", "appearance.theme", .choice(AppearancePreferences.Theme.allCases.map(\.rawValue))),
            .init("theme-accent", "appearance.useThemeAccent", .bool),
            .init("accent", "appearance.accentHex", .color),
            .init("transparency", "appearance.transparency", .number(0...1)),
            .init("popup-transparency", "appearance.popupTransparency", .number(0...1))
        ]
        for feature in FeatureID.allCases where ![.windowSwitcher, .applicationShortcuts, .clipboard].contains(feature) {
            fields.append(.init("feature.\(kebab(feature.rawValue))", "toolkit.enabled.\(feature.rawValue)", .bool))
        }
        for mode in ["light", "dark"] {
            for color in AppearancePreferences.paletteKeys {
                fields.append(.init("palette.\(mode).\(color)", "appearance.\(mode)Palette.\(color)", .color))
            }
        }
        return fields
    }()

    private static func kebab(_ text: String) -> String {
        text.reduce("") { $0 + ($1.isUppercase ? "-" + $1.lowercased() : String($1)) }
    }
    private struct Line {
        var raw: String
        var key: String?
        var value: String?
        var prefix = ""
        var suffix = ""
    }
    private static func parse(_ text: String) throws -> [Line] {
        var seen = Set<String>()
        return try text.components(separatedBy: "\n").enumerated().map { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return Line(raw: raw) }
            guard let equal = raw.firstIndex(of: "=") else { throw issue(index, "expected key = value") }
            let key = raw[..<equal].trimmingCharacters(in: .whitespaces)
            guard fields.contains(where: { $0.key == key }) else { throw issue(index, "unknown key '\(key)'; see docs/configuration.md") }
            guard seen.insert(key).inserted else { throw issue(index, "duplicate key '\(key)'; keep one assignment") }
            let start = raw.index(after: equal)
            let tail = String(raw[start...])
            var quoted = false, escaped = false
            var comment: String.Index?
            let first = tail.firstIndex(where: { !$0.isWhitespace })
            for i in tail.indices {
                let character = tail[i]
                if escaped { escaped = false; continue }
                if quoted && character == "\\" { escaped = true; continue }
                if character == "\"" { quoted.toggle(); continue }
                if !quoted && character == "#" {
                    // A leading #RRGGBB is a value, a subsequent # starts a comment.
                    if i == first { continue }
                    comment = i; break
                }
            }
            let content = String(tail[..<(comment ?? tail.endIndex)])
            let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw issue(index, "'\(key)' needs a value; remove the line to use its default") }
            let leading = content.prefix(while: \.isWhitespace)
            let trailing = content.reversed().prefix(while: \.isWhitespace).reversed()
            return Line(raw: raw, key: key, value: value, prefix: String(raw[...equal]) + leading,
                        suffix: String(trailing) + (comment.map { String(tail[$0...]) } ?? ""))
        }
    }
    private static func issue(_ index: Int, _ message: String) -> FrogError {
        .message("config:\(index + 1): \(message). Previous working settings were kept.")
    }

    /// Decodes the two-file representation; absent text keys use defaults, not stale JSON preferences.
    static func decode(_ text: String, companion: Data) throws -> Configuration {
        var root: [String: Any]
        do { root = try object(companion) }
        catch { throw FrogError.message("config.json: expected a valid JSON object containing rules and connections. Repair it or import a complete JSON export. Previous working settings were kept.") }
        var preferences = root["preferences"] as? [String: Any] ?? [:]
        for field in fields { set(nil, path: field.path, in: &preferences) }
        var defaults = try object(JSONEncoder().encode(Preferences()))
        defaults = merge(defaults, preferences)
        let lines = try parse(text)
        for (index, line) in lines.enumerated() {
            guard let key = line.key, let raw = line.value, let field = fields.first(where: { $0.key == key }) else { continue }
            do {
                let parsed = try value(raw, kind: field.kind)
                if case .shortcut = field.kind {
                    let hotkey = try JSONDecoder().decode(Hotkey.self, from: JSONSerialization.data(withJSONObject: parsed))
                    try ConfigShortcut.validate(hotkey, clipboard: key == "shortcut.clipboard")
                }
                set(parsed, path: field.path, in: &defaults)
            }
            catch { throw issue(index, "\(key): \(error.localizedDescription)") }
        }
        // Codable structs with required fields still support sparse text overrides.
        for (key, data) in [("workflows", try JSONEncoder().encode(WorkflowPreferences())),
                            ("appearance", try JSONEncoder().encode(AppearancePreferences())),
                            ("toolkit", try JSONEncoder().encode(ToolkitPreferences()))] {
            if let nested = defaults[key] as? [String: Any] { defaults[key] = merge(try object(data), nested) }
        }
        if var toolkit = defaults["toolkit"] as? [String: Any], let usage = toolkit["usage"] as? [String: Any] {
            toolkit["usage"] = merge(try object(JSONEncoder().encode(UsageDisplayPreferences())), usage)
            defaults["toolkit"] = toolkit
        }
        root["preferences"] = defaults
        let data = try JSONSerialization.data(withJSONObject: root)
        if let configuration = try? JSONDecoder().decode(Configuration.self, from: data) {
            for (index, line) in lines.enumerated() {
                guard let key = line.key, ["audio-model", "cleanup-model", "text-model"].contains(key),
                      let field = fields.first(where: { $0.key == key }), let id = get(field.path, in: defaults) as? String else { continue }
                let kind: LocalModelDescriptor.Kind = key == "audio-model" ? .audio : .text
                guard configuration.localModel(id)?.kind == kind else {
                    throw issue(index, "\(key): '\(id)' is not a configured \(kind.rawValue) model; choose a catalog ID or add its definition in config.json")
                }
            }
        }
        do { return try ConfigurationFile.decode(data) }
        catch {
            let assignments = lines.enumerated().compactMap { index, line in
                line.key.map { "\($0) (line \(index + 1))" }
            }.joined(separator: ", ")
            throw FrogError.message("config: \(error.localizedDescription) Check assignments: \(assignments). Previous working settings were kept.")
        }
    }

    static func companion(_ configuration: Configuration) throws -> Data {
        var root = try object(ConfigurationFile.encode(configuration))
        var preferences = root["preferences"] as? [String: Any] ?? [:]
        for field in fields { set(nil, path: field.path, in: &preferences) }
        // Empty dictionaries carry optional-container identity for exact JSON round trips.
        root["preferences"] = preferences
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func render(_ configuration: Configuration, preserving text: String? = nil) throws -> String {
        let prefs = try object(JSONEncoder().encode(configuration.preferences))
        var values: [String: String] = [:]
        for field in fields {
            if let value = get(field.path, in: prefs) { values[field.key] = try spelling(value, kind: field.kind) }
        }
        var lines = try parse(text ?? header)
        for index in lines.indices {
            guard let key = lines[index].key else { continue }
            if let value = values.removeValue(forKey: key) {
                // Preserve formatting and spelling of unchanged values, including inline comments.
                if let field = fields.first(where: { $0.key == key }), let old = lines[index].value,
                   let oldValue = try? self.value(old, kind: field.kind),
                   let newValue = get(field.path, in: prefs), NSDictionary(dictionary: ["v": oldValue]).isEqual(to: ["v": newValue]) { continue }
                lines[index].raw = lines[index].prefix + value + lines[index].suffix
            } else { lines[index].raw = "# " + lines[index].raw }
        }
        var result = lines.map(\.raw).joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        for field in fields { if let value = values[field.key] { result += "\(field.key) = \(value)\n" } }
        return result
    }

    private static let header = """
    # Frog — edit this file, then Settings → Configuration → Reload.
    # Basic settings live here; rules, connections and custom models live in config.json.
    # Sync both files with chezmoi. API keys and model downloads are stored separately.
    # Syntax: key = value   # comment. Strings with # or quotes use JSON double quotes.
    # Remove an assignment to use its default. Unknown/duplicate keys are errors.
    # Examples (uncomment to use):
    # theme = tokyoNight
    # appearance = system
    # feature.command-bar = true
    # shortcut.command-bar = ctrl+alt+space
    # palette.dark.background = #1A1B26
    # palette.dark.text = #C0CAF5
    # Palette names: background, sidebar, surface, inset, border, text, muted, accent, on-accent.
    # Use palette.light.<name> and palette.dark.<name>; omitted colors inherit the theme.
    # Full reference: https://github.com/t1llo/frog/blob/main/docs/configuration.md

    """

    private static func value(_ raw: String, kind: Kind) throws -> Any {
        let string: String
        if raw.hasPrefix("\"") {
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { throw FrogError.message("use a complete JSON double-quoted string") }
            string = decoded
        } else { string = raw }
        switch kind {
        case .bool:
            guard raw == "true" || raw == "false" else { throw FrogError.message("expected true or false") }; return raw == "true"
        case .integer(let range):
            guard let v = Int(raw), range.contains(v) else { throw FrogError.message("expected an integer in \(range.lowerBound)...\(range.upperBound)") }; return v
        case .number(let range):
            guard let v = Double(raw), v.isFinite, range.contains(v) else { throw FrogError.message("expected a number from \(range.lowerBound) to \(range.upperBound)") }; return v
        case .choice(let choices):
            guard choices.contains(string) else { throw FrogError.message("choose \(choices.joined(separator: ", "))") }; return string
        case .color:
            let hex = string.hasPrefix("#") ? String(string.dropFirst()) : string
            guard hex.count == 6, UInt32(hex, radix: 16) != nil else { throw FrogError.message("expected #RRGGBB (six hex digits)") }; return hex.uppercased()
        case .string:
            guard !string.isEmpty, string.utf8.count <= 256, !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw FrogError.message("expected 1–256 characters without control characters") }; return string
        case .strings:
            guard let strings = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)), strings.allSatisfy({ FeatureID(rawValue: $0) != nil }) else { throw FrogError.message("expected a JSON list of feature IDs, such as [\"usage\", \"scripts\"]") }; return strings
        case .shortcut:
            let key = try ConfigShortcut.parse(string)
            return ["keyCode": key.keyCode, "modifiers": key.modifiers]
        }
    }
    private static func spelling(_ value: Any, kind: Kind) throws -> String {
        switch kind {
        case .color: return "#" + (value as? String ?? "")
        case .shortcut:
            let data = try JSONSerialization.data(withJSONObject: value)
            return try ConfigShortcut.format(JSONDecoder().decode(Hotkey.self, from: data))
        case .string, .choice:
            let string = value as? String ?? ""
            if string.contains("#") || string.contains("\"") || string != string.trimmingCharacters(in: .whitespaces) {
                return String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
            }
            return string
        case .bool: return (value as? Bool) == true ? "true" : "false"
        case .strings:
            return String(decoding: try JSONEncoder().encode((value as? [String] ?? []).sorted()), as: UTF8.self)
        default: return String(describing: value)
        }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FrogError.message("Expected a configuration JSON object.") }; return value
    }
    private static func get(_ path: [String], in object: [String: Any]) -> Any? {
        guard let first = path.first else { return nil }
        if path.count == 1 { return object[first] }
        return (object[first] as? [String: Any]).flatMap { get(Array(path.dropFirst()), in: $0) }
    }
    private static func set(_ value: Any?, path: [String], in object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 { object[first] = value; return }
        if object[first] == nil && value == nil { return }
        var nested = object[first] as? [String: Any] ?? [:]
        set(value, path: Array(path.dropFirst()), in: &nested); object[first] = nested
    }
    private static func merge(_ base: [String: Any], _ overrides: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overrides {
            if let old = result[key] as? [String: Any], let new = value as? [String: Any] { result[key] = merge(old, new) }
            else { result[key] = value }
        }
        return result
    }
}

/// Physical macOS key names, independent of the current keyboard layout; numeric fallback is lossless.
enum ConfigShortcut {
    static let keys: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27,
        "8": 28, "0": 29, "right-bracket": 30, "o": 31, "u": 32, "left-bracket": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "quote": 39, "k": 40, "semicolon": 41, "backslash": 42,
        "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47, "tab": 48, "space": 49, "grave": 50,
        "delete": 51, "escape": 53, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "end": 119, "page-up": 116, "page-down": 121, "forward-delete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
    static let modifiers: [(String, UInt32)] = [("ctrl", 4096), ("alt", 2048), ("shift", 512), ("cmd", 256)]
    static func parse(_ text: String) throws -> Hotkey {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { throw FrogError.message("expected ctrl+alt+space") }
        let key = keys[last] ?? (last.hasPrefix("keycode-") ? UInt32(last.dropFirst(8)) : nil)
        var bits: UInt32 = 0
        for part in parts.dropLast() {
            guard let bit = modifiers.first(where: { $0.0 == part })?.1, bits & bit == 0 else { throw FrogError.message("use each of ctrl, alt, shift, cmd at most once, followed by a key") }; bits |= bit
        }
        let additional: Set<UInt32> = [10, 64, 65, 67, 69, 71, 75, 76, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 102, 104, 105, 106, 107, 113, 114]
        guard let key, keys.values.contains(key) || additional.contains(key) else { throw FrogError.message("unknown key; use space, a–z, f1–f12 or a supported macOS keycode") }
        guard bits & (4096 | 2048 | 256) != 0 else { throw FrogError.message("a global shortcut needs ctrl, alt or cmd") }
        guard !([8, 9, 7].contains(key) && bits == 256), !(key == 9 && bits == 256 | 2048 | 512) else {
            throw FrogError.message("Copy, Cut and Paste shortcuts are reserved for the focused app")
        }
        return Hotkey(keyCode: key, modifiers: bits)
    }
    static func format(_ key: Hotkey) throws -> String {
        let text = (modifiers.filter { key.modifiers & $0.1 != 0 }.map(\.0) + [keys.first(where: { $0.value == key.keyCode })?.key ?? "keycode-\(key.keyCode)"]).joined(separator: "+")
        guard try parse(text) == key else { throw FrogError.message("The saved shortcut contains unsupported modifier flags; record a new shortcut before migrating.") }
        return text
    }
    static func validate(_ key: Hotkey, clipboard: Bool = false) throws {
        _ = try format(key)
        if key.keyCode == 9, key.modifiers == 256 | 512, !clipboard {
            throw FrogError.message("cmd+shift+v is reserved for paste; use it only for shortcut.clipboard")
        }
    }
}
