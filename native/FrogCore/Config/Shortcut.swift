import Foundation

/// A global shortcut as config.toml spells it: `"ctrl+alt+space"`, `"cmd+shift+v"`.
///
/// Key names are physical US-layout positions (see `ConfigShortcut`), so a shortcut means the same
/// keys on every keyboard layout. It converts to and from `Hotkey`, the virtual key code and
/// Carbon modifier bits the app registers. Reserved combinations a single feature allows, such as
/// cmd+shift+v for the clipboard, are that feature's own check (`ConfigShortcut.validate`).
public struct Shortcut: Codable, Hashable, Sendable, CustomStringConvertible {
    public let hotkey: Hotkey

    /// Reads `ctrl+alt+space`; modifiers in any order and case.
    public init(_ text: String) throws {
        hotkey = try ConfigShortcut.parse(text)
    }

    /// Refuses a hotkey with modifier bits or a key the text form cannot name.
    public init(_ hotkey: Hotkey) throws {
        _ = try ConfigShortcut.format(hotkey)
        self.hotkey = hotkey
    }

    public var keyCode: UInt32 { hotkey.keyCode }
    public var modifiers: UInt32 { hotkey.modifiers }

    /// Modifiers in the order ctrl, alt, shift, cmd, then the key: `ctrl+alt+space`.
    public var description: String {
        // Both initializers checked that the hotkey formats.
        (try? ConfigShortcut.format(hotkey)) ?? "keycode-\(hotkey.keyCode)"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do { try self.init(text) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected a shortcut such as \"ctrl+alt+space\": \(error.localizedDescription)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Physical macOS key names, independent of the current keyboard layout; numeric fallback is lossless.
/// Shared by config.toml's `Shortcut` and the v1 text file's `shortcut.*` keys.
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
