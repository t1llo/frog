import Foundation

/// Portable settings of the Windows feature. Later versions add their fields here; an older file
/// without them, or with fields this version does not know, decodes to the defaults.
public struct WindowPreferences: Codable, Equatable, Sendable {
    /// Points around the display edge and between windows that layouts place side by side.
    public var gap = 0
    /// A half shortcut pressed again cycles through ½, ⅔ and ⅓.
    public var cycleSizes = false
    /// Thirds run top to bottom on a display taller than wide.
    public var portraitThirds = true
    /// Layouts keep Stage Manager's strip free while it is on.
    public var respectStageManager = true
    /// Shortcuts of window commands, by `WindowCommand` raw value. Layout shortcuts stay on their rules.
    public var shortcuts: [String: Hotkey] = [:]
    /// The layout picker opens from its shortcut, the Frog menu and the command bar.
    public var layoutPicker = false
    /// A window dropped on a screen edge or corner fills that part of the screen.
    public var dragToSnap = false
    /// A snapped window gets its earlier size back when it is dragged away.
    public var restoreOnDrag = true
    /// Holding Shift while dragging a window shows zones to drop it into.
    public var zoneOverlay = false
    /// The zones the overlay shows, a `ZoneGrid` raw value.
    public var zoneGrid = ZoneGrid.default.rawValue
    /// What the first-run card recorded, a `WindowSetupChoice` raw value; nil while the card shows.
    /// A string, so a choice from a newer version still decodes and keeps the card hidden.
    public var setupChoice: String?

    public static let gapRange = 0...40

    public init() {}

    public var normalized: WindowPreferences {
        var value = self
        value.gap = min(Self.gapRange.upperBound, max(Self.gapRange.lowerBound, gap))
        if ZoneGrid(rawValue: zoneGrid) == nil { value.zoneGrid = ZoneGrid.default.rawValue }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case gap
        case cycleSizes
        case portraitThirds
        case respectStageManager
        case shortcuts
        case layoutPicker
        case dragToSnap
        case restoreOnDrag
        case zoneOverlay
        case zoneGrid
        case setupChoice
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gap = try values.decodeIfPresent(Int.self, forKey: .gap) ?? 0
        cycleSizes = try values.decodeIfPresent(Bool.self, forKey: .cycleSizes) ?? false
        portraitThirds = try values.decodeIfPresent(Bool.self, forKey: .portraitThirds) ?? true
        respectStageManager = try values.decodeIfPresent(Bool.self, forKey: .respectStageManager) ?? true
        shortcuts = try values.decodeIfPresent([String: Hotkey].self, forKey: .shortcuts) ?? [:]
        layoutPicker = try values.decodeIfPresent(Bool.self, forKey: .layoutPicker) ?? false
        dragToSnap = try values.decodeIfPresent(Bool.self, forKey: .dragToSnap) ?? false
        restoreOnDrag = try values.decodeIfPresent(Bool.self, forKey: .restoreOnDrag) ?? true
        zoneOverlay = try values.decodeIfPresent(Bool.self, forKey: .zoneOverlay) ?? false
        zoneGrid = try values.decodeIfPresent(String.self, forKey: .zoneGrid) ?? ZoneGrid.default.rawValue
        setupChoice = try values.decodeIfPresent(String.self, forKey: .setupChoice)
        self = normalized
    }

    /// Checks the Windows settings of a configuration and claims their global shortcuts in
    /// `usedShortcuts`. It checks whenever the settings exist, with the feature on or off,
    /// because a configuration that loads must stay valid when Windows is switched on.
    public static func validate(_ preferences: Preferences, usedShortcuts: inout Set<Hotkey>) throws {
        guard let windows = preferences.toolkitSettings.windows else { return }
        guard gapRange.contains(windows.gap) else {
            throw FrogError.message("The window gap must be between 0 and 40 points.")
        }
        // A command this version does not know is left alone, so a newer file still loads.
        for (name, key) in windows.shortcuts where WindowCommand(rawValue: name) != nil { try ConfigShortcut.validate(key) }
        for rule in WindowSwitches(preferences).shortcutRules {
            guard let command = WindowCommand.command(for: rule.id), let key = rule.hotkey else { continue }
            guard usedShortcuts.insert(key).inserted else {
                throw FrogError.message("The window shortcut for \(command.title) conflicts with another shortcut.")
            }
        }
    }
}

/// The switches the Windows feature reads, resolved once from the preferences.
public struct WindowSwitches: Equatable, Sendable {
    /// The Windows feature is on.
    public let feature: Bool
    /// Layout shortcuts and command bar layouts run.
    public let actionsEnabled: Bool
    /// The feature's settings, or their defaults when none are saved.
    public let settings: WindowPreferences

    public init(_ preferences: Preferences) {
        feature = preferences.featureEnabled(.windows)
        actionsEnabled = preferences.windowActionsEnabled
        settings = preferences.toolkitSettings.windows ?? WindowPreferences()
    }

    /// A window command runs: Windows is on, and so is the command's own switch if it has one.
    public func commandEnabled(_ command: WindowCommand) -> Bool {
        switch command {
        case .cheatSheet: feature
        case .layoutPicker: feature && settings.layoutPicker
        }
    }

    /// Windows dropped on a screen edge or corner snap: Windows is on, and so is the switch.
    public var dragToSnap: Bool { feature && settings.dragToSnap }

    /// A snapped window dragged away gets its earlier size back. Only while drag to snap runs.
    public var restoreOnDrag: Bool { dragToSnap && settings.restoreOnDrag }

    /// Holding Shift during a window drag shows Frog's zones: Windows is on, and so is the switch.
    public var zoneOverlay: Bool { feature && settings.zoneOverlay }

    /// The zones the overlay shows.
    public var zoneGrid: ZoneGrid { ZoneGrid(rawValue: settings.zoneGrid) ?? .default }

    /// Window drags are watched: for drag to snap, the zone overlay, or both.
    public var watchesDrags: Bool { dragToSnap || zoneOverlay }

    /// The window commands the command bar lists, in `allCases` order.
    public var commandBarCommands: [WindowCommand] {
        WindowCommand.allCases.filter { $0.showsInCommandBar && commandEnabled($0) }
    }

    /// The window commands that run and have a shortcut, as the rules Frog registers, in `allCases` order.
    public var shortcutRules: [Rule] {
        WindowCommand.allCases.compactMap { command in
            guard commandEnabled(command), let key = settings.shortcuts[command.rawValue] else { return nil }
            return command.rule(hotkey: key)
        }
    }

    /// How layouts use the displays. With Windows off they land where they always did.
    public func layoutOptions(_ macOS: MacWindowManagerSettings) -> WindowLayoutOptions {
        guard feature else { return .legacy }
        return WindowLayoutOptions(gap: CGFloat(settings.normalized.gap), portraitThirds: settings.portraitThirds,
                                   leadingInset: settings.respectStageManager && macOS.stageManager ? WindowLayoutOptions.stageManagerInset : 0,
                                   cycleSizes: settings.cycleSizes)
    }
}

extension Preferences {
    /// Window layouts run while Shortcuts or Windows is on, so either can be switched off alone.
    public var windowActionsEnabled: Bool { featureEnabled(.applicationShortcuts) || featureEnabled(.windows) }
}
