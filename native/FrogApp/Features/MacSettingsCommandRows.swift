import AppKit
import FrogCore

/// The System Settings panes. The built-in catalogue is listed at once; the panes this Mac has are discovered once
/// and replace it in place, each with its own icon. Discovery survives closing the bar until the bar stops.
@MainActor final class MacSettingsCommandRows: CommandBarRowProviding {
    private let load: @Sendable () async -> [SystemSetting]
    private let openSetting: @MainActor (SystemSetting) throws -> Void
    private(set) var settings = SystemSettingsCatalog.defaults
    private(set) var loaded = false
    private var discovery: Task<Void, Never>?
    /// Told when discovery finishes, while the bar lists rows.
    private var changed: (@MainActor () -> Void)?
    /// By row ID: the key of the pane's own icon.
    private(set) var iconKeys: [String: String] = [:]

    init(load: @escaping @Sendable () async -> [SystemSetting], open: @escaping @MainActor (SystemSetting) throws -> Void) {
        self.load = load; openSetting = open
    }

    /// Starts discovery once; rows already listed take the panes' names and icons where they are.
    func discover() {
        guard !loaded, discovery == nil else { return }
        discovery = Task { [weak self] in
            guard let self else { return }
            let found = await self.load()
            guard !Task.isCancelled else { return }
            self.settings = found; self.loaded = true; self.discovery = nil
            self.iconKeys = Dictionary(found.compactMap { setting in setting.icon.map { (setting.record.id, $0.key) } }, uniquingKeysWith: { first, _ in first })
            self.changed?()
        }
    }

    /// A pane shows its own icon once discovery found it, and the System Settings icon until then.
    func iconPath(for id: String) -> String { iconKeys[id] ?? MacSettingsDiscovery.fallbackIconPath }

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let open = openSetting
        return settings.map { setting in
            CommandBarRow(record: setting.record, primary: CommandRowAction(title: "Open") { try open(setting) }, iconPath: iconPath(for: setting.record.id))
        }
    }

    func open(in context: CommandBarContext, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        discover()
    }

    func close() { changed = nil }

    func reset() {
        discovery?.cancel(); discovery = nil; loaded = false; changed = nil
        settings = SystemSettingsCatalog.defaults; iconKeys = [:]
    }
}

/// The windows open on this Mac, while the window switcher is on. The last snapshot is listed at once and a new
/// one replaces it when it arrives.
@MainActor final class WindowSwitchCommandRows: CommandBarRowProviding {
    private let windows = WindowCatalog()
    private var cached: [SwitcherWindow] = []
    private var snapshot: Task<Void, Never>?

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        guard context.model.configuration.preferences.featureEnabled(.windowSwitcher) else { return [] }
        let catalog = windows, toolUse = context.toolUse
        return cached.map { item in
            CommandBarRow(record: SearchRecord(id: "window:\(item.id)", title: item.title, subtitle: item.appName, keywords: "window switch", symbol: "macwindow"),
                          primary: CommandRowAction(title: "Switch") {
                try Task.checkCancellation()
                guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated else {
                    throw FrogError.message("That window is no longer available.")
                }
                if app.isHidden { app.unhide() }
                let activated = await WindowActivation.perform(
                    raise: { await catalog.raise(id: item.id) },
                    request: { app.activate(options: []) },
                    bringForward: { await catalog.bringApplicationForward(id: item.id) },
                    isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == item.pid })
                try Task.checkCancellation()
                guard activated else { throw FrogError.message("Could not bring that window to the front. Try again.") }
                toolUse(.windowCommand)
            }, iconPath: NSRunningApplication(processIdentifier: item.pid)?.bundleURL?.path)
        }
    }

    func open(in context: CommandBarContext, changed: @escaping @MainActor () -> Void) {
        guard context.model.configuration.preferences.featureEnabled(.windowSwitcher) else { return }
        let applications = NSWorkspace.shared.runningApplications.compactMap(SwitcherApplication.running)
        let catalog = windows, frontPID = context.frontPID
        snapshot = Task { [weak self] in
            let snapshot = await catalog.snapshot(applications: applications, frontPID: frontPID)
            guard let self, !Task.isCancelled, snapshot.isPublishable else { return }
            self.cached = snapshot.windows
            changed()
        }
    }

    func close() { snapshot?.cancel(); snapshot = nil }
    func clear() { close(); cached = [] }
}
