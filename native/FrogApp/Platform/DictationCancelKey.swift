import FrogCore

/// Escape as a system-wide key for as long as a dictation runs. A global event monitor only sees
/// the key if Frog has Accessibility permission, and the focused app receives it as well; a
/// registered key needs no permission and goes to Frog alone.
@MainActor
protocol DictationCancelKey: AnyObject {
    /// `heldModifiers` are those of a hold-to-record shortcut, or 0. While that shortcut is down,
    /// Escape arrives together with them.
    func register(heldModifiers: UInt32, onPress: @escaping () -> Void)
    func unregister()
}

@MainActor
final class EscapeHotkey: DictationCancelKey {
    /// Frog's shared shortcuts; Escape is a group of its own there, so it comes and goes without touching the others.
    private let manager: HotkeyManager
    static let group = "dictation.escape"
    /// The person's own cancel shortcut, registered beside Escape while a recording runs.
    var extraKey: () -> Hotkey? = { nil }

    init(manager: HotkeyManager) { self.manager = manager }

    static func combinations(heldModifiers: UInt32) -> [Hotkey] {
        (heldModifiers == 0 ? [0] : [0, heldModifiers]).map { Hotkey(keyCode: 53, modifiers: $0) }
    }

    func register(heldModifiers: UInt32, onPress: @escaping () -> Void) {
        let combinations = Self.combinations(heldModifiers: heldModifiers) + [extraKey()].compactMap { $0 }
        let keys = Set(combinations).map { Rule(name: "Cancel recording", hotkey: $0) }
        // A combination that macOS refuses stays with the controller's event monitors.
        _ = manager.register(rules: keys, group: Self.group,
                             purposes: Dictionary(uniqueKeysWithValues: keys.map { ($0.id, .recordingCancel) }),
                             onPress: { _ in onPress() }) { _ in }
    }

    func unregister() { manager.unregister(group: Self.group) }
}
