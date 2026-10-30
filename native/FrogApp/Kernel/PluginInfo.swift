import SwiftUI

/// Where a plugin sits in the sidebar. The order of the cases is the sidebar's order.
enum PluginCategory: String, CaseIterable, Sendable {
    case write, navigate, windows, system, devices, community

    var title: String {
        switch self {
        case .write: "Write"
        case .navigate: "Find & launch"
        case .windows: "Windows"
        case .system: "Mac"
        case .devices: "Devices"
        case .community: "Community"
        }
    }
}

/// A macOS permission a plugin needs to work. Setup asks only for the ones of plugins that are on.
enum MacPermission: String, CaseIterable, Sendable {
    case accessibility, microphone, notifications, fullDiskAccess, localNetwork, bluetooth

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .notifications: "Notifications"
        case .fullDiskAccess: "Full Disk Access"
        case .localNetwork: "Local Network"
        case .bluetooth: "Bluetooth"
        }
    }
}

/// What the sidebar, the Plugins page, setup and `frog plugins` know about a plugin without creating it.
struct PluginInfo: Identifiable, Sendable {
    /// Kebab-case and stable: the key in `[plugins]`, the name of its config table and the prefix of its actions.
    let id: String
    let name: String
    let symbol: String
    /// The colour of its icon tile.
    let tint: PluginTint
    let category: PluginCategory
    /// One short line for the Plugins page and setup, under 50 characters.
    let summary: String
    var enabledByDefault = false
    var permissions: [MacPermission] = []
    /// Shown above the others in setup: the plugins most people want.
    var recommended = false
}

/// Icon tile colours: soft enough to sit together in the sidebar, distinct enough to find a plugin by colour.
enum PluginTint: String, CaseIterable, Sendable {
    case green, teal, blue, indigo, purple, pink, red, orange, yellow, gray

    var color: Color {
        switch self {
        case .green: Color(red: 0.20, green: 0.70, blue: 0.40)
        case .teal: Color(red: 0.16, green: 0.64, blue: 0.70)
        case .blue: Color(red: 0.20, green: 0.48, blue: 0.95)
        case .indigo: Color(red: 0.36, green: 0.38, blue: 0.90)
        case .purple: Color(red: 0.62, green: 0.38, blue: 0.90)
        case .pink: Color(red: 0.92, green: 0.32, blue: 0.56)
        case .red: Color(red: 0.92, green: 0.30, blue: 0.28)
        case .orange: Color(red: 0.96, green: 0.56, blue: 0.18)
        case .yellow: Color(red: 0.92, green: 0.70, blue: 0.10)
        case .gray: Color(red: 0.50, green: 0.52, blue: 0.56)
        }
    }
}
