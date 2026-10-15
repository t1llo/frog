import Foundation

/// Portable settings of the Windows feature. Later versions add their fields here; an older file
/// without them, or with fields this version does not know, decodes to the defaults.
public struct WindowPreferences: Codable, Equatable, Sendable {
    public init() {}

    public var normalized: WindowPreferences { self }
}

/// The switches the Windows feature reads, resolved once from the preferences.
public struct WindowSwitches: Equatable, Sendable {
    /// The Windows feature is on.
    public let feature: Bool
    /// Layout shortcuts and command bar layouts run.
    public let actionsEnabled: Bool

    public init(_ preferences: Preferences) {
        feature = preferences.featureEnabled(.windows)
        actionsEnabled = preferences.windowActionsEnabled
    }
}

extension Preferences {
    /// Window layouts run while Shortcuts or Windows is on, so either can be switched off alone.
    public var windowActionsEnabled: Bool { featureEnabled(.applicationShortcuts) || featureEnabled(.windows) }
}
