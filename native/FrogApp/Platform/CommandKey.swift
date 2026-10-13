import Carbon
import CoreGraphics

/// The key that types a letter together with Command in the keyboard layout in use. A virtual
/// key code names a position, not a letter: code 9 is V on QWERTY and K on Dvorak, so a synthetic
/// Command-V has to be sent from wherever the layout puts V.
@MainActor
enum CommandKey {
    /// `fallback` is the letter's QWERTY position, used when the layout cannot be read or lacks the letter.
    static func code(for letter: String, fallback: CGKeyCode) -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        // `source` owns the layout data and outlives every translation below.
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboard = UInt32(LMGetKbdType())
        return code(for: letter, fallback: fallback) { key, command in
            var deadKey: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), command ? UInt32(cmdKey >> 8) : 0,
                                        keyboard, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKey, characters.count, &length, &characters)
            return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length) : nil
        }
    }

    /// `character` gives what a key types with or without Command held, or nil for nothing.
    /// Apps match a shortcut against the Command layer, which "Dvorak – QWERTY ⌘" and the layouts
    /// of other scripts fill with QWERTY letters, so that layer decides and plain typing is second.
    nonisolated static func code(for letter: String, fallback: CGKeyCode,
                                 character: (_ key: CGKeyCode, _ command: Bool) -> String?) -> CGKeyCode {
        // The usual position first: where several keys type the letter, it is the expected one.
        let keys = [fallback] + (0...50 as ClosedRange<CGKeyCode>).filter { $0 != fallback }
        let letter = letter.lowercased()
        for command in [true, false] {
            if let key = keys.first(where: { character($0, command)?.lowercased() == letter }) { return key }
        }
        return fallback
    }
}
