import AppKit
import FrogCore

/// Owns what Windows runs: its commands and the panels they show. It creates nothing while it is
/// inactive or Windows is off, so a switched-off feature costs nothing.
@MainActor
final class WindowLayoutController: ObservableObject {
    let manager: WindowManager
    let access: WindowAccess
    let displays: @MainActor () -> [WindowDisplay]
    let readMacOS: () -> MacWindowManagerSettings
    var onError: ((Error) -> Void)?
    /// Window moves count as `.windowCommand`.
    var onToolUse: ((ActivityToolKind) -> Void)?

    private(set) var configuration = Configuration()
    private(set) var active = false
    private var cheatSheet: WindowCheatSheetPanel?

    init(manager: WindowManager, access: WindowAccess = AXWindowAccess(),
         displays: @escaping @MainActor () -> [WindowDisplay] = WindowDisplays.current,
         readMacOS: @escaping () -> MacWindowManagerSettings = MacWindowManagerReader.read) {
        self.manager = manager
        self.access = access
        self.displays = displays
        self.readMacOS = readMacOS
    }

    /// Windows is on and the app registers shortcuts.
    var running: Bool { active && WindowSwitches(configuration.preferences).feature }

    func configure(_ configuration: Configuration, active: Bool) {
        let previous = WindowSwitches(self.configuration.preferences).shortcutRules
        self.configuration = configuration
        self.active = active
        guard running else { stop(); return }
        // Registering the shortcuts again forgets one that is held, so its release never comes.
        if WindowSwitches(configuration.preferences).shortcutRules != previous { cheatSheet?.hide() }
    }

    func handle(_ command: WindowCommand, pressed: Bool) {
        guard running, WindowSwitches(configuration.preferences).commandEnabled(command) else { return }
        switch command {
        case .cheatSheet: if pressed { showCheatSheet() } else { cheatSheet?.hide() }
        }
    }

    /// Hides every panel and ends what runs. Synchronous: it is called while Frog quits and while a
    /// feature is switched off, and neither waits.
    func stop() {
        cheatSheet?.hide()
    }

    private func showCheatSheet() {
        let switches = WindowSwitches(configuration.preferences)
        let commands = switches.shortcutRules.compactMap { rule in
            WindowCommand.command(for: rule.id).flatMap { command in rule.hotkey.map { (command, $0) } }
        }
        let rules = configuration.rules.filter { configuration.preferences.ruleFeatureEnabled($0) }
        let panel = cheatSheet ?? WindowCheatSheetPanel()
        cheatSheet = panel
        panel.show(sections: WindowCheatSheet.sections(rules: rules, commands: commands))
    }
}
