import AppKit
import SwiftUI
import FrogCore

final class PhonePlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "phone", name: "Phone", symbol: "iphone", tint: .green, category: .devices,
                                 summary: "Share the clipboard with your phone",
                                 permissions: [.localNetwork, .bluetooth, .notifications])
    func page() -> AnyView? { legacyPage(PhoneView()) }
    var menu: [MenuContribution] {
        [MenuContribution(id: "phone.status", order: 30) { [model, context] in
            guard let phone = model.phone else { return AnyView(EmptyView()) }
            return AnyView(PhoneMenuRow(phone: phone) { context.openPage() })
        }]
    }
}
