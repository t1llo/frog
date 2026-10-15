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
}
