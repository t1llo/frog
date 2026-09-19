import AppKit
import Carbon
import FrogCore

@MainActor
final class HotkeyManager {
    private static let signature: OSType = 0x46524F47 // FROG
    private static var nextRegistrationID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var rulesByID: [UInt32: UUID] = [:]
    private var onTrigger: ((UUID) -> Void)?
    private var generation: UInt64 = 0

    func register(rules: [Rule], onTrigger: @escaping (UUID) -> Void) -> [UUID: String] {
        unregister()
        self.onTrigger = onTrigger
        let candidates = rules.filter { $0.enabled && $0.hotkey != nil }
        guard !candidates.isEmpty else { return [:] }
        var errors: [UUID: String] = [:]
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr, hotkeyID.signature == 0x46524F47 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                guard let ruleID = manager.rulesByID[hotkeyID.id] else { return OSStatus(eventNotHandledErr) }
                let generation = manager.generation
                Task { @MainActor [weak manager] in
                    guard let manager, manager.generation == generation else { return }
                    manager.onTrigger?(ruleID)
                }
                return noErr
            }
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            for rule in candidates { errors[rule.id] = "Could not install the keyboard handler (\(status))." }
            return errors
        }
        let counts = Dictionary(grouping: candidates, by: { $0.hotkey! }).mapValues(\.count)
        let idCounts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        for rule in candidates {
            guard let hotkey = rule.hotkey else { continue }
            if let error = Self.validationError(hotkey) { errors[rule.id] = error; continue }
            guard counts[hotkey] == 1, idCounts[rule.id] == 1 else {
                errors[rule.id] = "This shortcut or rule ID is duplicated. Assign a unique shortcut to each enabled rule."
                continue
            }
            // IDs are process-wide so simultaneous managers cannot consume one another's events.
            let id = Self.nextRegistrationID
            Self.nextRegistrationID &+= 1
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference {
                registrations.append(reference)
                rulesByID[id] = rule.id
            } else {
                errors[rule.id] = result == OSStatus(eventHotKeyExistsErr)
                    ? "This shortcut is already registered by another application or macOS."
                    : "macOS could not register this shortcut (\(result)). Choose another combination."
            }
        }
        return errors
    }

    func unregister() {
        generation &+= 1
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        rulesByID.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        onTrigger = nil
    }

    isolated deinit {
        registrations.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func hotkey(from event: NSEvent) -> Hotkey? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        return validationError(hotkey) == nil ? hotkey : nil
    }

    static func display(_ hotkey: Hotkey) -> String {
        var result = ""
        if hotkey.modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if hotkey.modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if hotkey.modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if hotkey.modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (specialKeys[hotkey.keyCode] ?? layoutLabel(hotkey.keyCode) ?? "Key \(hotkey.keyCode)")
    }

    private static func validationError(_ hotkey: Hotkey) -> String? {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard hotkey.modifiers & ~allowed == 0 else { return "The shortcut contains unsupported modifier flags." }
        guard hotkey.modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return "Use Command, Option, or Control with the shortcut key."
        }
        guard printableKeys.contains(hotkey.keyCode) || specialKeys[hotkey.keyCode] != nil else {
            return "This key cannot be used as a global shortcut."
        }
        return nil
    }

    private static func layoutLabel(_ code: UInt32) -> String? {
        guard printableKeys.contains(code),
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let printableKeys: Set<UInt32> = Set(0...50).subtracting([36, 48, 49]).union([
        65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95, 102, 104
    ])
    private static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "Clear", 76: "⌤",
        79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "↖", 116: "⇞",
        117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑", 64: "F17"
    ]
}
