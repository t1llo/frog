import SwiftUI
import FrogCore

/// The Windows page: layout shortcuts for the front window, and the way to the window switcher.
struct WindowsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let rows = WindowAction.shortcutRows(configured: model.configuration.rules)
        let lastRowID = rows.last?.id
        PageScroll {
            PageHeader(title: "Windows", subtitle: "Arrange windows your way: snap them in place, or let Frog tile them.")
            if !model.accessibilityGranted {
                InlineIssue(message: "Frog needs Accessibility access to move and resize windows.")
                Button("Allow Accessibility") { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
            }
            SettingsSection(title: "Sizes") {
                CompactRow(title: "Gap between windows") {
                    Stepper("\(settings.gap) pt", value: binding(\.gap), in: WindowPreferences.gapRange, step: 2).fixedSize()
                }
                CompactRow(title: "Cycle sizes when pressed again", detail: "Press a half shortcut again for ½, ⅔ and ⅓ of the screen.") {
                    Toggle("Cycle sizes when pressed again", isOn: binding(\.cycleSizes)).labelsHidden().toggleStyle(.switch)
                }
                CompactRow(title: "Thirds run top to bottom on tall displays") {
                    Toggle("Thirds run top to bottom on tall displays", isOn: binding(\.portraitThirds)).labelsHidden().toggleStyle(.switch)
                }
                CompactRow(title: "Leave room for Stage Manager", detail: "Keeps the left 190 points free while Stage Manager is on.") {
                    Toggle("Leave room for Stage Manager", isOn: binding(\.respectStageManager)).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsSection(title: "Layout shortcuts") {
                VStack(spacing: 0) {
                    ForEach(rows) { rule in
                        ShortcutRuleRow(rule: rule, model: model) { ShortcutRuleSymbol() }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if rule.id != lastRowID { Divider().opacity(0.5) }
                            }
                    }
                }
            }
            SettingsSection(title: "Related") {
                CompactRow(title: "Window switcher", detail: "Switch between individual windows with ⌘Tab.") {
                    Button("Open in Features") { model.openFeature(.windowSwitcher) }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.accent)
                }
            }
        }
    }

    /// The saved Windows settings, or their defaults.
    private var settings: WindowPreferences { model.configuration.preferences.toolkitSettings.windows ?? WindowPreferences() }

    private func binding<Value>(_ field: WritableKeyPath<WindowPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: field] }, set: { value in update { $0[keyPath: field] = value } })
    }

    /// Saves a change to the Windows settings. Every control on this page saves through it.
    private func update(_ change: (inout WindowPreferences) -> Void) {
        do {
            try model.updateToolkit { toolkit in
                var windows = toolkit.windows ?? WindowPreferences()
                change(&windows)
                toolkit.windows = windows.normalized
            }
        } catch { model.report(error) }
    }
}
