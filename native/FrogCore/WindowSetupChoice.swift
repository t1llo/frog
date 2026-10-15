import Foundation

/// How someone chose to arrange windows on the Windows page the first time. Saved as its raw
/// value, so a choice a later version adds never breaks decoding here.
public enum WindowSetupChoice: String, CaseIterable, Sendable {
    case snap
    /// "Set up myself": the card goes away and nothing else changes.
    case manual

    /// The choices the card offers as options, in order. `manual` is its plain button.
    public static var options: [WindowSetupChoice] { allCases.filter { $0 != .manual } }

    public var title: String {
        switch self {
        case .snap: "Snap"
        case .manual: "Set up myself"
        }
    }

    public var detail: String {
        switch self {
        case .snap: "Drag windows to screen edges, or pick a layout. Nothing moves by itself."
        case .manual: "Change nothing and choose the settings below."
        }
    }

    /// The preferences with the choice applied and recorded. Every choice but `manual` turns
    /// Windows on; `snap` turns on drag to snap, restore on drag, the zone overlay and the
    /// layout picker. Shortcuts are added separately.
    public static func apply(_ choice: Self, to preferences: Preferences) -> Preferences {
        var preferences = preferences
        preferences.ensureToolkit()
        var windows = preferences.toolkit?.windows ?? WindowPreferences()
        windows.setupChoice = choice.rawValue
        switch choice {
        case .snap:
            preferences.setFeature(.windows, enabled: true)
            windows.dragToSnap = true
            windows.restoreOnDrag = true
            windows.zoneOverlay = true
            windows.layoutPicker = true
        case .manual:
            break
        }
        preferences.toolkit?.windows = windows.normalized
        return preferences
    }

    /// Undo of a choice: `current` with the Windows switch and settings of `previous` again.
    /// Shortcuts added since stay: layout shortcuts are rules, and command shortcuts are kept.
    public static func undo(to previous: Preferences, from current: Preferences) -> Preferences {
        var preferences = current
        preferences.setFeature(.windows, enabled: previous.featureEnabled(.windows))
        var windows = previous.toolkitSettings.windows
        if let shortcuts = current.toolkitSettings.windows?.shortcuts, !shortcuts.isEmpty {
            windows = windows ?? WindowPreferences()
            windows?.shortcuts = shortcuts
        }
        preferences.toolkit?.windows = windows
        return preferences
    }
}
