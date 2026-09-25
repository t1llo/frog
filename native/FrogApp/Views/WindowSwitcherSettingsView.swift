import SwiftUI
import FrogCore

struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Windows", subtitle: "Switch directly between open windows.")
            FrogCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use ⌘Tab to switch windows", isOn: Binding(get: { model.configuration.preferences.windowSwitcherEnabled }, set: { enabled in
                        var preferences = model.configuration.preferences
                        preferences.windowSwitcherEnabled = enabled
                        do { try model.savePreferences(preferences) } catch { model.report(error) }
                    })).toggleStyle(.switch).controlSize(.small)
                    Label(model.windowSwitcherStatus, systemImage: model.windowSwitcherReady ? "checkmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.accessibilityGranted {
                        Button("Allow Accessibility") { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
                    }
                }
            }
            FrogCard {
                VStack(spacing: 10) {
                    row("⌘Tab / ⇧⌘Tab", "Next / previous window")
                    row("Release ⌘", "Switch to selection")
                    row("esc", "Cancel")
                    row("Hold ⌘ + type", "Find a window")
                }
            }
            Text("Turn off to restore the macOS app switcher. Includes minimized windows and accessible windows on other Spaces.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func row(_ key: String, _ action: String) -> some View {
        HStack { Text(action); Spacer(); ShortcutBadge(text: key) }.font(.system(size: 12))
    }
}
