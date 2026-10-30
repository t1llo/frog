import AppKit
import Carbon
import FrogCore

@MainActor
final class HotkeyManager {
    enum ShortcutPurpose { case rule, clipboardHistory, windowSwitcher, recordingCancel }
    private static let signature: OSType = 0x46524F47 // FROG
    private static var nextRegistrationID: UInt32 = 1
    /// One set of shortcuts that registers and unregisters on its own, so a plugin's keys come and go without
    /// touching the rest. Registering a group again would forget a key of that group held down right now.
    private struct Group {
        var references: [EventHotKeyRef] = []
        var onTrigger: ((UUID) -> Void)?
        var onPress: ((UUID) -> Void)?
        var pressed = Set<UUID>()
        var generation: UInt64 = 0
    }
    private var handler: EventHandlerRef?
    private var groups: [String: Group] = [:]
    /// Readable so that a test can drive the installed Carbon callback with a real registration.
    private(set) var rulesByID: [UInt32: UUID] = [:]
    private var groupByID: [UInt32: String] = [:]
    private var generation: UInt64 = 0
    /// What each group asked for, so a suspension can give every group its keys back.
    private struct Request {
        let rules: [Rule]
        let purposes: [UUID: ShortcutPurpose]
        let onPress: ((UUID) -> Void)?
        let onTrigger: (UUID) -> Void
    }
    private var requests: [String: Request] = [:]
    /// While a shortcut is being recorded no group holds a key, so the key being recorded reaches the recorder.
    private(set) var suspended = false

    /// Whether a shortcut of `group` is down; registering that group again now would lose its release.
    func isHolding(_ group: String = "") -> Bool { !(groups[group]?.pressed.isEmpty ?? true) }
    var isHolding: Bool { isHolding("") }

    /// Registers `rules` as `group`, replacing what that group held before. Other groups keep their shortcuts.
    func register(rules: [Rule], group: String = "", purposes: [UUID: ShortcutPurpose] = [:], onPress: ((UUID) -> Void)? = nil,
                  onTrigger: @escaping (UUID) -> Void) -> [UUID: String] {
        release(group)
        requests[group] = Request(rules: rules, purposes: purposes, onPress: onPress, onTrigger: onTrigger)
        guard !suspended else { return [:] }
        let candidates = rules.filter { $0.enabled && $0.hotkey != nil }
        guard !candidates.isEmpty else { return [:] }
        var errors: [UUID: String] = [:]
        guard installHandler() else {
            for rule in candidates { errors[rule.id] = "Could not install the keyboard handler." }
            return errors
        }
        generation &+= 1
        var entry = Group(onTrigger: onTrigger, onPress: onPress, generation: generation)
        let counts = Dictionary(grouping: candidates, by: { $0.hotkey! }).mapValues(\.count)
        let idCounts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        for rule in candidates {
            guard let hotkey = rule.hotkey else { continue }
            if let error = Self.validationError(hotkey, purpose: purposes[rule.id] ?? .rule) { errors[rule.id] = error; continue }
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
                entry.references.append(reference)
                rulesByID[id] = rule.id; groupByID[id] = group
            } else {
                errors[rule.id] = result == OSStatus(eventHotKeyExistsErr)
                    ? "This shortcut is already registered by another application or macOS."
                    : "macOS could not register this shortcut (\(result)). Choose another combination."
            }
        }
        groups[group] = entry
        if entry.references.isEmpty { release(group) }
        return errors
    }

    /// Unregisters one group; the handler goes when no group is left.
    func unregister(group: String = "") {
        requests[group] = nil
        release(group)
    }

    /// Unregisters every group, as Frog quits.
    func unregisterAll() {
        requests = [:]
        for group in Array(groups.keys) { release(group) }
    }

    /// Takes every group's keys away, or gives them back; a group registered meanwhile registers on resuming.
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value { for group in Array(groups.keys) { release(group) }; return }
        for (group, request) in requests {
            _ = register(rules: request.rules, group: group, purposes: request.purposes, onPress: request.onPress, onTrigger: request.onTrigger)
        }
    }

    private func release(_ group: String) {
        if let entry = groups.removeValue(forKey: group) { entry.references.forEach { UnregisterEventHotKey($0) } }
        for (id, owner) in groupByID where owner == group { groupByID[id] = nil; rulesByID[id] = nil }
        if groups.isEmpty, let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr, hotkeyID.signature == 0x46524F47 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                return manager.deliver(hotkeyID.id, down: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            }
        }
        return InstallEventHandler(GetApplicationEventTarget(), callback, 2, &eventTypes,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }

    private func deliver(_ id: UInt32, down: Bool) -> OSStatus {
        guard let ruleID = rulesByID[id], let name = groupByID[id], var entry = groups[name] else { return OSStatus(eventNotHandledErr) }
        if down && !entry.pressed.insert(ruleID).inserted { return noErr }
        // Carbon can deliver a release after registration/focus changes
        // without a corresponding press. Never treat that as a shortcut.
        if !down && entry.pressed.remove(ruleID) == nil { return noErr }
        groups[name] = entry
        let generation = entry.generation
        Task { @MainActor [weak self] in
            guard let self, let entry = self.groups[name], entry.generation == generation else { return }
            if down { entry.onPress?(ruleID) } else { entry.onTrigger?(ruleID) }
        }
        return noErr
    }

    isolated deinit {
        for entry in groups.values { entry.references.forEach { UnregisterEventHotKey($0) } }
        if let handler { RemoveEventHandler(handler) }
    }

    static func hotkey(from event: NSEvent, purpose: ShortcutPurpose = .rule) -> Hotkey? {
        guard let result = capture(event, purpose: purpose) else { return nil }
        return try? result.get()
    }

    static func capture(_ event: NSEvent, purpose: ShortcutPurpose = .rule) -> Result<Hotkey, FrogError>? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if let issue = validationError(hotkey, purpose: purpose) { return .failure(.message(issue)) }
        return .success(hotkey)
    }

    static func display(_ hotkey: Hotkey) -> String { keys(hotkey).joined() }

    /// The keys of a shortcut one by one, modifiers first in the order macOS menus show them.
    static func keys(_ hotkey: Hotkey) -> [String] {
        var result: [String] = []
        if hotkey.modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if hotkey.modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if hotkey.modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if hotkey.modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        return result + [specialKeys[hotkey.keyCode] ?? layoutLabel(hotkey.keyCode) ?? "Key \(hotkey.keyCode)"]
    }

    static func validationError(_ hotkey: Hotkey, purpose: ShortcutPurpose = .rule) -> String? {
        let command = UInt32(cmdKey)
        let clipboard = [UInt32(8), 9, 7].contains(hotkey.keyCode) && hotkey.modifiers == command
        let pasteStyle = hotkey.keyCode == 9 && [UInt32(cmdKey | shiftKey), UInt32(cmdKey | optionKey | shiftKey)].contains(hotkey.modifiers)
        let historyShortcut = purpose == .clipboardHistory && hotkey.keyCode == 9 && hotkey.modifiers == UInt32(cmdKey | shiftKey)
        guard !clipboard, !pasteStyle || historyShortcut else { return "Copy, Cut and Paste shortcuts are reserved for the focused app. Choose a different Frog shortcut." }
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard hotkey.modifiers & ~allowed == 0 else { return "The shortcut contains unsupported modifier flags." }
        // Escape alone is held only while a recording runs, where it cancels that recording.
        let cancelsRecording = purpose == .recordingCancel && hotkey.keyCode == 53
        guard cancelsRecording || hotkey.modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return "Use Command, Option, or Control with the shortcut key."
        }
        guard printableKeys.contains(hotkey.keyCode) || specialKeys[hotkey.keyCode] != nil else {
            return "This key cannot be used as a global shortcut."
        }
        if purpose == .windowSwitcher {
            guard hotkey.modifiers & UInt32(shiftKey) == 0 else {
                return "Shift is reserved for switching backward. Record the shortcut without Shift."
            }
            guard ![UInt32(36), 51, 53, 76, 123, 124, 125, 126].contains(hotkey.keyCode) else {
                return "Escape, Return, Delete, and arrow keys control the window switcher. Choose another shortcut key."
            }
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
