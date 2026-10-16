import SwiftUI
import FrogCore

/// The Windows page: layout shortcuts for the front window, and the way to the window switcher.
struct WindowsView: View {
    @EnvironmentObject private var model: AppModel
    /// What the last "Use suggested shortcuts" did, until the page closes.
    @State private var suggestion: String?
    @State private var voiceOverNote = false
    /// macOS's own window tiling, read when the page opens and whenever Frog comes to the front.
    @State private var macOS = MacWindowManagerSettings()

    var body: some View {
        let rows = WindowAction.shortcutRows(configured: model.configuration.rules)
        let lastRowID = rows.last?.id
        PageScroll {
            PageHeader(title: "Windows", subtitle: "Arrange windows your way: snap them in place, or let Frog tile them.")
            if !model.accessibilityGranted {
                InlineIssue(message: "Frog needs Accessibility access to move and resize windows.")
                Button("Allow Accessibility") { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
            }
            WindowSetupCard(macOS: macOS)
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
            SettingsSection(title: "Snap") {
                CompactRow(title: "Drag to screen edges", detail: "Drop a window on an edge or corner to fill that part of the screen.") {
                    Toggle("Drag to screen edges", isOn: binding(\.dragToSnap)).labelsHidden().toggleStyle(.switch)
                }
                if macOS.edgeTiling || macOS.topEdgeTiling {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nativeTilingNote)
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Desktop & Dock") { MacWindowManagerReader.openDesktopAndDock() }.buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                }
                CompactRow(title: "Restore size when dragged away", detail: "A snapped window gets its earlier size back when you drag it out.") {
                    Toggle("Restore size when dragged away", isOn: binding(\.restoreOnDrag)).labelsHidden().toggleStyle(.switch)
                        .disabled(!settings.dragToSnap)
                }
                CompactRow(title: "Show zones while holding Shift", detail: "Hold Shift while dragging a window to drop it into a zone.") {
                    Toggle("Show zones while holding Shift", isOn: binding(\.zoneOverlay)).labelsHidden().toggleStyle(.switch)
                }
                CompactRow(title: "Zones") {
                    CompactMenu(value: WindowSwitches(model.configuration.preferences).zoneGrid.title, width: 180) {
                        ForEach(ZoneGrid.allCases, id: \.self) { grid in
                            Button(grid.title) { update { $0.zoneGrid = grid.rawValue } }
                        }
                    }.disabled(!settings.zoneOverlay)
                }
                CompactRow(title: "Layout picker", detail: "Choose a layout from a small panel, from a shortcut, the Frog menu or the command bar.") {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .trailing, spacing: 4) {
                            HotkeyRecorder(hotkey: commandShortcut(.layoutPicker)).disabled(!settings.layoutPicker)
                            if let issue = model.hotkeyErrors[WindowCommand.layoutPicker.id] {
                                Text(issue).font(.caption2).foregroundStyle(FrogStyle.warning)
                            }
                        }
                        Toggle("Layout picker", isOn: binding(\.layoutPicker)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            SettingsSection(title: "Layout shortcuts") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Use suggested shortcuts", action: useSuggestedShortcuts).buttonStyle(FrogButtonStyle())
                    if let suggestion {
                        Text(suggestion).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if voiceOverNote {
                        Text("VoiceOver uses Control-Option. These shortcuts work, but VoiceOver users may prefer others.")
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                VStack(spacing: 0) {
                    ForEach(rows) { rule in
                        ShortcutRuleRow(rule: rule, model: model) {
                            if let action = rule.action?.windowAction {
                                WindowLayoutGlyph(action: action).frame(width: 28, height: 28)
                            } else { ShortcutRuleSymbol() }
                        }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if rule.id != lastRowID { Divider().opacity(0.5) }
                            }
                    }
                }
            }
            SettingsSection(title: "Cheat sheet") {
                CompactRow(title: "Show window shortcuts while holding", detail: "Hold the shortcut to see your window shortcuts. Release it to close.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorder(hotkey: commandShortcut(.cheatSheet))
                        if let issue = model.hotkeyErrors[WindowCommand.cheatSheet.id] {
                            Text(issue).font(.caption2).foregroundStyle(FrogStyle.warning)
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
        .onAppear { macOS = MacWindowManagerReader.read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            macOS = MacWindowManagerReader.read()
        }
    }

    /// Why Frog's edges, or only its top edge and corners, are paused, and the ways around it.
    private var nativeTilingNote: String {
        let fill = "\"Drag windows to menu bar to fill screen\""
        guard macOS.edgeTiling else {
            return "macOS fills the screen with a window dragged to the menu bar, so Frog's top edge and corners are paused. To use them, turn off \(fill) in Desktop & Dock."
        }
        let zones = settings.zoneOverlay ? "Hold Shift while dragging to use Frog's zones,"
            : "Turn on \"Show zones while holding Shift\" to use Frog's zones,"
        let tile = "\"Drag windows to screen edges to tile\""
        let off = macOS.topEdgeTiling ? "\(tile), and for the top edge \(fill)," : tile
        return "macOS already tiles windows dragged to screen edges, so Frog's edges are paused. \(zones) or turn off \(off) in Desktop & Dock."
    }

    /// The saved Windows settings, or their defaults.
    private var settings: WindowPreferences { model.configuration.preferences.toolkitSettings.windows ?? WindowPreferences() }

    private func binding<Value>(_ field: WritableKeyPath<WindowPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: field] }, set: { value in update { $0[keyPath: field] = value } })
    }

    /// A command's shortcut. One the window switcher uses is refused, so the switcher keeps working.
    private func commandShortcut(_ command: WindowCommand) -> Binding<Hotkey?> {
        Binding(get: { settings.shortcuts[command.rawValue] }, set: { value in
            if let value, AppModel.windowSwitcherChords(model.configuration.preferences).contains(value) {
                model.report(FrogError.message("The window shortcut for \(command.title) conflicts with another shortcut."))
                return
            }
            update { $0.shortcuts[command.rawValue] = value }
        })
    }

    private func useSuggestedShortcuts() {
        do {
            let result = try model.applySuggestedWindowShortcuts()
            suggestion = result.summary(display: HotkeyManager.display)
            voiceOverNote = NSWorkspace.shared.isVoiceOverEnabled
        } catch { model.report(error) }
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
