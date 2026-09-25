import SwiftUI
import FrogCore

struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScroll {
            PageHeader(title: "Window switcher", subtitle: "Every window, one shortcut. Switch directly to the document you need.")
            FrogCard {
                VStack(alignment: .leading, spacing: 18) {
                    SettingRow(title: "Switch windows with ⌘Tab", description: "Replace the macOS app switcher while Frog is running. Turn this off to restore the standard app switcher.") {
                        Toggle("Enable window switcher", isOn: Binding(get: { model.configuration.preferences.windowSwitcherEnabled }, set: { enabled in
                            var preferences = model.configuration.preferences
                            preferences.windowSwitcherEnabled = enabled
                            do { try model.savePreferences(preferences) } catch { model.report(error) }
                        })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    Divider()
                    Label(model.windowSwitcherStatus, systemImage: model.windowSwitcherReady ? "checkmark.circle.fill" : "info.circle")
                        .font(.system(size: 12)).foregroundStyle(model.windowSwitcherReady ? FrogStyle.accent : FrogStyle.muted)
                    if !model.accessibilityGranted {
                        Button("Allow Accessibility", systemImage: "arrow.up.right") {
                            SelectionService.requestAccess()
                            SelectionService.openAccessibilitySettings()
                        }
                    }
                }
            }
            SectionCaption(text: "Keyboard controls")
            FrogCard {
                VStack(spacing: 14) {
                    shortcut("⌘ Tab", title: "Next window", detail: "Keep holding Command and tap Tab to cycle.")
                    Divider()
                    shortcut("⇧ ⌘ Tab", title: "Previous window", detail: "Add Shift to move backwards.")
                    Divider()
                    shortcut("Release ⌘", title: "Switch", detail: "Bring the selected window to the front.")
                    Divider()
                    shortcut("esc", title: "Cancel", detail: "Stay in your current window.")
                }
            }
            FrogCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Windows, not just apps", systemImage: "macwindow.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Each accessible window gets its own row with its title and app icon. Recently used windows appear first. Minimized windows and windows in hidden apps are included and restored when selected.")
                    Text("Use the arrow keys or click a row to select a window. Windows on other Spaces are included when the app exposes them to macOS Accessibility. No screen recording permission is needed.")
                }.font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
            }
        }
    }

    private func shortcut(_ keys: String, title: String, detail: String) -> some View {
        HStack(spacing: 20) {
            ShortcutBadge(text: keys).frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(FrogStyle.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
            }
            Spacer(minLength: 0)
        }
    }
}
