import Combine
import Foundation
import FrogCore
import FrogUsage

/// One projection for the sidebar, command palette and optional module lifetimes.
@MainActor final class Toolkit: ObservableObject {
    @Published private(set) var preferences = Preferences()
    @Published private(set) var route: ToolkitRoute = .feature(.writing)
    /// Makes LLM usage's model when that plugin starts; tests pass one reading fixtures.
    let makeUsage: @MainActor () -> UsageDashboardModel
    /// Whether plugins may add items to the real menu bar: in the app, not in tests.
    let showsStatusItems: Bool
    private let showsMenuBarOrganizer: Bool
    let menuBarOrganizer: MenuBarOrganizer
    var onDisable: ((FeatureID) -> Void)?
    var onOpenMenuBar: (() -> Void)?

    init(makeUsage: @escaping @MainActor () -> UsageDashboardModel = { UsageDashboardModel() }, showsUsageStatusItem: Bool = true,
         showsMenuBarOrganizer: Bool = false, menuBarOrganizer: MenuBarOrganizer? = nil) {
        self.makeUsage = makeUsage; self.showsStatusItems = showsUsageStatusItem
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
    }
    /// A feature that is off has no page; asking for it opens Features, where it is turned on.
    func select(_ route: ToolkitRoute) {
        self.route = route.available(in: preferences) ? route : .features
    }
    func stop() {
        menuBarOrganizer.stop()
        for id in FeatureID.allCases { onDisable?(id) }
    }
}
