import SwiftUI
import FrogCore

/// The Window switcher page: its shortcut, and what stops it when something does.
struct WindowSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    let plugin: WindowSwitcherPlugin

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Window switcher", subtitle: "Every window, not every app. Type to search.")
            FrogSection {
                FrogRow("Shortcut", caption: "Hold to keep switching, add Shift to go back") {
                    HotkeyRecorder(hotkey: Binding(get: { plugin.settings.shortcut.hotkey }, set: { value in
                        guard let value else { return }
                        do { try plugin.setShortcut(value) } catch { model.report(error) }
                    }), showsClearButton: false, purpose: .windowSwitcher)
                }
                if plugin.status == .needsAccessibility {
                    FrogRow("Accessibility", caption: "Needed to read and switch windows") {
                        Button("Allow") { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
                    }
                } else if plugin.status.isIssue {
                    FrogRowNote(text: plugin.status.text, tone: FrogStyle.warning)
                }
            }
        }
    }
}
