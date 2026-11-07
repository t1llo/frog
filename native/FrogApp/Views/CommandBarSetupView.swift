import AppKit
import Carbon
import FrogCore
import SwiftUI

/// ⌘Space for Frog instead of Spotlight: two rows that sit in the Command bar page's Shortcut card.
struct CommandBarSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var issue: String?
    private let shortcut = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    private var plugin: CommandBarPlugin? { model.pluginHost.running[CommandBarPlugin.info.id] as? CommandBarPlugin }
    private var assigned: Bool { plugin?.settings.shortcut.hotkey == shortcut }

    var body: some View {
        Group {
            FrogRow("Free ⌘Space from Spotlight", caption: "In Keyboard Shortcuts → Spotlight, turn off “Show Spotlight search”.") {
                Button("Keyboard Settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") else { return }
                    if !NSWorkspace.shared.open(url) { issue = "Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight." }
                }.buttonStyle(.frog())
            }
            // Both rows carry a caption, so they are the same height; switching back is said where it happens.
            FrogRow("Give ⌘Space to Frog", caption: assigned && plugin?.shortcutIssue == nil
                    ? "Set. Press ⌘Space to try it. To switch back, choose another shortcut, then turn Spotlight’s on again."
                    : "Then ⌘Space opens Frog’s command bar.") {
                Button(assigned ? "Try again" : "Use ⌘Space") {
                    do { try model.useCommandBarShortcut(shortcut); issue = nil }
                    catch { issue = error.localizedDescription }
                }.buttonStyle(.frog())
            }
            if let error = issue ?? plugin?.shortcutIssue { FrogRowNote(text: error, tone: FrogStyle.warning) }
        }
    }
}
