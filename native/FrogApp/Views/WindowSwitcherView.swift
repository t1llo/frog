import AppKit
import SwiftUI
import FrogCore

/// The Window switcher page: its shortcut, what stops it when something does, how the panel looks and the keys
/// it answers to while it is open.
struct WindowSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    let plugin: WindowSwitcherPlugin

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Window switcher", subtitle: "Every window, not every app. Type to search.")
            FrogSection("Switching") {
                FrogRow("Shortcut", caption: "Hold to keep switching; add Shift to go back.") {
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
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                FrogSectionHeader("Preview")
                WindowSwitcherPreview()
            }
            FrogSection("While it's open") {
                ForEach(WindowSwitcherKey.all) { key in
                    FrogRow(key.title) { KeyCaps(key.keys) }
                }
            }
        }
    }
}

/// One key the open panel answers to, as the page lists them.
struct WindowSwitcherKey: Identifiable {
    let title: String
    let keys: [String]
    var id: String { title }

    static let all = [
        WindowSwitcherKey(title: "Next or previous window", keys: ["↑", "↓"]),
        WindowSwitcherKey(title: "Go back while holding the shortcut", keys: ["⇧"]),
        WindowSwitcherKey(title: "Search windows", keys: ["A–Z"]),
        WindowSwitcherKey(title: "Delete a typed letter", keys: ["⌫"]),
        WindowSwitcherKey(title: "Switch to the window", keys: ["↩"]),
        WindowSwitcherKey(title: "Close without switching", keys: ["esc"]),
    ]
}

/// The real panel with a few sample windows of apps every Mac has, drawn as it opens over other apps.
/// It only shows what the switcher looks like; it takes no clicks.
struct WindowSwitcherPreview: View {
    @StateObject private var display = Self.sample()

    var body: some View {
        WindowSwitcherOverlay(model: display, choose: { _ in }, hover: { _ in })
            .frame(height: WindowSwitcherLayout.size(windowCount: display.windows.count).height)
            .allowsHitTesting(false)
            .padding(.vertical, FrogStyle.space16 + FrogStyle.space8)
            .frame(maxWidth: .infinity)
            .frogTableSurface()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Preview of the window switcher"))
    }

    private static func sample() -> WindowSwitcherDisplay {
        let display = WindowSwitcherDisplay()
        let apps: [(pid: pid_t, name: String, title: String, path: String, minimized: Bool)] = [
            (1, "Notes", "Weekend plans", "/System/Applications/Notes.app", false),
            (2, "Safari", "Start Page", "/Applications/Safari.app", false),
            (3, "Finder", "Downloads", "/System/Library/CoreServices/Finder.app", false),
            (4, "Terminal", "~ — zsh", "/System/Applications/Utilities/Terminal.app", true),
        ]
        display.windows = apps.map {
            SwitcherWindow(id: UUID(), pid: $0.pid, appName: $0.name, title: $0.title, minimized: $0.minimized, hidden: false)
        }
        display.icons = Dictionary(uniqueKeysWithValues: apps.compactMap { app in
            FileManager.default.fileExists(atPath: app.path) ? (app.pid, NSWorkspace.shared.icon(forFile: app.path)) : nil
        })
        display.selected = display.windows.dropFirst().first?.id
        return display
    }
}
