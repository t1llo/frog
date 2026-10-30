import FrogCore

/// Escape as a system-wide key for as long as a dictation runs. A global event monitor only sees
/// the key if Frog has Accessibility permission, and the focused app receives it as well; a
/// registered key needs no permission and goes to Frog alone.
@MainActor
protocol DictationCancelKey: AnyObject {
    /// `heldModifiers` are those of a hold-to-record shortcut, or 0. While that shortcut is down,
    /// Escape arrives together with them. `onPress` says which key cancelled: Escape or the person's own.
    func register(heldModifiers: UInt32, onPress: @escaping (HistoryEntry.Interruption) -> Void)
    func unregister()
}

@MainActor
final class EscapeHotkey: DictationCancelKey {
    /// Frog's shared shortcuts; Escape is a group of its own there, so it comes and goes without touching the others.
    private let manager: HotkeyManager
    static let group = "dictation.escape"
    /// The person's own cancel shortcut, registered beside Escape while a recording runs.
    var extraKey: () -> Hotkey? = { nil }
    /// Why the cancel shortcut could not be registered; said once for each shortcut.
    var onIssue: (String) -> Void = { _ in }
    private var reported: Hotkey?

    init(manager: HotkeyManager) { self.manager = manager }

    static func combinations(heldModifiers: UInt32) -> [Hotkey] {
        (heldModifiers == 0 ? [0] : [0, heldModifiers]).map { Hotkey(keyCode: 53, modifiers: $0) }
    }

    func register(heldModifiers: UInt32, onPress: @escaping (HistoryEntry.Interruption) -> Void) {
        let escapes = Self.combinations(heldModifiers: heldModifiers)
        let extra = extraKey().flatMap { escapes.contains($0) ? nil : Rule(name: "Cancel recording", hotkey: $0) }
        let keys = escapes.map { Rule(name: "Cancel recording", hotkey: $0) } + [extra].compactMap { $0 }
        // An Escape combination that macOS refuses stays with the controller's event monitors.
        let errors = manager.register(rules: keys, group: Self.group,
                                      purposes: Dictionary(uniqueKeysWithValues: keys.map { ($0.id, .recordingCancel) }),
                                      onPress: { onPress($0 == extra?.id ? .cancelled : .escape) }) { _ in }
        if let extra, let hotkey = extra.hotkey, let error = errors[extra.id], reported != hotkey {
            reported = hotkey
            onIssue("The cancel shortcut \(HotkeyManager.display(hotkey)) does not work: \(error)")
        } else if let extra, errors[extra.id] == nil { reported = nil }
    }

    func unregister() { manager.unregister(group: Self.group) }
}
