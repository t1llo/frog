import Combine
import Foundation
import FrogCore
import FrogUsage

/// One projection for the sidebar, command palette and optional module lifetimes.
@MainActor final class Toolkit: ObservableObject {
    @Published private(set) var preferences = Preferences()
    @Published private(set) var route: ToolkitRoute = .feature(.writing)
    @Published private(set) var featureSettingsSelection: FeatureID?
    private var usageModel: UsageDashboardModel?
    private let makeUsage: @MainActor () -> UsageDashboardModel
    private let showsUsageStatusItem: Bool
    private let showsMenuBarOrganizer: Bool
    let menuBarOrganizer: MenuBarOrganizer
    private(set) var usageStatusItem: UsageStatusItemController?
    private var usagePreferences: UsageDashboardPreferences?
    var onDisable: ((FeatureID) -> Void)?
    var onOpenUsage: (() -> Void)?
    var onOpenMenuBar: (() -> Void)?
    var onUsagePreferencesChange: ((UsageDashboardPreferences) -> Void)?

    init(makeUsage: @escaping @MainActor () -> UsageDashboardModel = { UsageDashboardModel() }, showsUsageStatusItem: Bool = true,
         showsMenuBarOrganizer: Bool = false, menuBarOrganizer: MenuBarOrganizer? = nil) {
        self.makeUsage = makeUsage; self.showsUsageStatusItem = showsUsageStatusItem
        self.showsMenuBarOrganizer = showsMenuBarOrganizer
        self.menuBarOrganizer = menuBarOrganizer ?? MenuBarOrganizer()
        self.menuBarOrganizer.onShowSettings = { [weak self] in
            self?.select(.feature(.menuBar)); self?.onOpenMenuBar?()
        }
    }
    var sidebar: [FeatureID] { preferences.sidebarFeatures }
    func apply(_ preferences: Preferences) {
        let disabled = FeatureID.allCases.filter { self.preferences.featureEnabled($0) && !preferences.featureEnabled($0) }
        self.preferences = preferences
        if !route.available(in: preferences) { route = .features }
        for feature in disabled { onDisable?(feature) }
        menuBarOrganizer.configure(enabled: showsMenuBarOrganizer && preferences.featureEnabled(.menuBar),
                                   settings: preferences.toolkitSettings.menuBar ?? MenuBarPreferences())
        if preferences.featureEnabled(.usage), let usage = usage() {
            usage.setAvailable(true)
            if showsUsageStatusItem, usageStatusItem == nil {
                usageStatusItem = UsageStatusItemController(usage: usage) { [weak self] in
                    self?.select(.feature(.usage)); self?.onOpenUsage?()
                }
            }
        } else {
            usageStatusItem?.stop(); usageStatusItem = nil
            usageModel?.setAvailable(false)
        }
    }
    func select(_ route: ToolkitRoute) {
        if case .feature(let feature) = route, !feature.hasPage { featureSettingsSelection = feature }
        else { featureSettingsSelection = nil }
        self.route = route.available(in: preferences) ? route : .features
    }
    func usage() -> UsageDashboardModel? {
        guard preferences.featureEnabled(.usage) else { return nil }
        if usageModel == nil {
            let usage = makeUsage()
            if let usagePreferences { usage.applyPreferences(usagePreferences) }
            usage.onPreferencesChange = { [weak self] value in
                self?.usagePreferences = value
                self?.onUsagePreferencesChange?(value)
            }
            usageModel = usage
        }
        return usageModel
    }
    /// Call before apply(_:) at launch/import so the first read uses the imported login choice.
    func applyUsagePreferences(_ preferences: UsageDashboardPreferences) {
        usagePreferences = preferences
        usageModel?.applyPreferences(preferences)
    }
    func stop() {
        menuBarOrganizer.stop()
        usageStatusItem?.stop(); usageStatusItem = nil
        usageModel?.setAvailable(false)
        for id in FeatureID.allCases { onDisable?(id) }
    }
    isolated deinit { usageStatusItem?.stop(); usageModel?.setAvailable(false) }
}
