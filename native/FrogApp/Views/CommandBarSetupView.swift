import AppKit
import Carbon
import FrogCore
import SwiftUI

/// Shared by first-run setup and Command bar settings so the walkthrough is repeatable.
struct CommandBarSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var issue: String?
    private let shortcut = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    private var assigned: Bool {
        model.configuration.preferences.featureEnabled(.commandBar)
            && model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey == shortcut
    }

    var body: some View {
        SettingsSection(title: "Use Frog instead of Spotlight") {
            Text("Apps, files and calculations — right under ⌘Space.")
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
            step(1, "Free the shortcut in macOS", detail: "Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight. Turn off “Show Spotlight search”, or give it another shortcut.") {
                Button("Open Keyboard Settings…") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") else { return }
                    if !NSWorkspace.shared.open(url) { issue = "Open System Settings manually, then choose Keyboard → Keyboard Shortcuts → Spotlight." }
                }
            }
            Divider()
            step(2, "Give ⌘Space to Frog", detail: "Enables the command bar and saves its shortcut. If another launcher uses ⌘Space, change its shortcut first too.") {
                Button(assigned ? "Retry ⌘Space" : "Use ⌘Space") {
                    do { try model.useCommandBarShortcut(shortcut); issue = nil }
                    catch { issue = error.localizedDescription }
                }
            }
            Divider()
            step(3, "Try it", detail: "Press ⌘Space, then type an app name or 25% * 200. Use ↑↓ and Return. Drag the top grip or footer to move the panel.") {
                Button("Open command bar") { model.showCommandBar() }
                    .disabled(!model.configuration.preferences.featureEnabled(.commandBar))
            }
            if let error = issue ?? model.hotkeyErrors[AppModel.commandBarID] {
                InlineIssue(message: error)
            } else if assigned {
                Label("Frog is set to ⌘Space. Try the shortcut to confirm.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(FrogStyle.accent)
            }
            Text("To switch back, choose another Frog shortcut, then re-enable Spotlight’s shortcut in Keyboard Settings.")
                .font(.caption).foregroundStyle(FrogStyle.muted)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, detail: String, @ViewBuilder action: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                .frame(width: 24, height: 24).background(FrogStyle.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                action()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
