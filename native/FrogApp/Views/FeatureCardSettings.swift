import SwiftUI
import FrogCore

/// Inline settings shown under a feature's card in Features while it is on.
struct FeatureCardSettings: View {
    let feature: FeatureID
    static func hasSettings(_ feature: FeatureID) -> Bool {
        switch feature {
        case .windowSwitcher: true
        case .clipboard: true
        case .systemMonitor: true
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: emoji-picker
        // slot: processes
        // slot: color-picker
        // slot: quicklinks
        default: false
        }
    }
    var body: some View {
        switch feature {
        case .windowSwitcher: WindowSwitcherFeatureView()
        case .clipboard: ClipboardFeatureView()
        case .systemMonitor: SystemMonitorFeatureView()
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: emoji-picker
        // slot: processes
        // slot: color-picker
        // slot: quicklinks
        default: EmptyView()
        }
    }
}
