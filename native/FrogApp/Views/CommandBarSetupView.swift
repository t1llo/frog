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
            step(1, "Free the shortcut in macOS", detail: "Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight. Turn off “Show Spotlight search”, or give it another shortcut.") {
                Button("Open Keyboard Settings…") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") else { return }
                    if !NSWorkspace.shared.open(url) { issue = "Open System Settings manually, then choose Keyboard → Keyboard Shortcuts → Spotlight." }
                }
            }
            step(2, "Give ⌘Space to Frog", detail: "Enables the command bar and saves its shortcut. If another launcher uses ⌘Space, change its shortcut first too.") {
                Button(assigned ? "Retry ⌘Space" : "Use ⌘Space") {
                    do { try model.useCommandBarShortcut(shortcut); issue = nil }
                    catch { issue = error.localizedDescription }
                }
            }
            step(3, "Try it", detail: "Press ⌘Space, then type an app, file name or 25% * 200.") {
                Button("Open command bar") { model.showCommandBar() }
                    .disabled(!model.configuration.preferences.featureEnabled(.commandBar))
            }
            if let error = issue ?? model.hotkeyErrors[AppModel.commandBarID] {
                InlineIssue(message: error)
            } else if assigned {
                Label("Frog is set to ⌘Space. Try the shortcut to confirm.", systemImage: "checkmark.circle")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.accent)
            }
            Text("To switch back, choose another Frog shortcut, then re-enable Spotlight’s shortcut in Keyboard Settings.")
                .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, detail: String, @ViewBuilder action: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(FrogType.label).foregroundStyle(FrogStyle.accent)
                .frame(width: FrogStyle.compactHeight, height: FrogStyle.compactHeight).background(FrogStyle.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(FrogType.bodyMedium)
                Text(detail).font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                action()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
