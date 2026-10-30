import AppKit
import SwiftUI
import FrogCore

final class CommunityPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "community", name: "Community plugins", symbol: "puzzlepiece.extension", tint: .purple,
                                 category: .community, summary: "Plugins you build or install")
    func page() -> AnyView? { legacyPage(PluginsView(plugins: model.plugins)) }
}
