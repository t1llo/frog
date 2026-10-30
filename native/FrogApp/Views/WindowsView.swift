import SwiftUI
import FrogCore

/// The Windows page: layout shortcuts in a compact grid, then snapping, panels and sizes.
struct WindowsView: View {
    @EnvironmentObject private var model: AppModel
    let plugin: WindowsPlugin
    /// What the last "Suggested shortcuts" did, until the page closes.
    @State private var suggestion: String?
    /// macOS's own window tiling, read when the page opens and whenever Frog comes to the front.
    @State private var macOS = MacWindowManagerSettings()

    private var settings: WindowsSettings { plugin.settings }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Windows", subtitle: "Snap and tile windows with keys.") {
                Button("Suggested shortcuts", action: useSuggestedShortcuts)
                    .help("Gives every layout without a shortcut one with ⌃⌥, where it is free.")
            }
            if !model.accessibilityGranted {
                FrogSection {
                    FrogRow("Accessibility", caption: "Needed to move and resize windows") {
                        Button("Allow") { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
                            .buttonStyle(.frog(.primary))
                    }
                }
            }
            layouts
            snap
            panels
            sizes
        }
        .onAppear { macOS = MacWindowManagerReader.read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            macOS = MacWindowManagerReader.read()
        }
    }

    // MARK: Sections

    private var layouts: some View {
        let rules = Dictionary(uniqueKeysWithValues: WindowAction.shortcutRows(configured: model.configuration.rules)
            .compactMap { rule in rule.action?.windowAction.map { ($0, rule) } })
        return FrogSection("Layouts") {
            if let suggestion { FrogRowNote(text: suggestion) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 0) {
                ForEach(Self.layoutOrder) { action in
                    if let rule = rules[action] { LayoutShortcutCell(rule: rule, issue: model.hotkeyErrors[rule.id], model: model) }
                }
            }
        }
    }

    private var snap: some View {
        FrogSection("Snap") {
            FrogRow("Drag to screen edges") { Toggle("Drag to screen edges", isOn: binding(\.dragToSnap)).labelsHidden().toggleStyle(.switch) }
            FrogRow("Restore size when dragged away") {
                Toggle("Restore size when dragged away", isOn: binding(\.restoreOnDrag)).labelsHidden().toggleStyle(.switch)
            }.disabled(!settings.dragToSnap)
            FrogRow("Zones while holding Shift") {
                FrogDropdown(selected: settings.zoneOverlay ? Optional(settings.zones) : nil,
                             options: [nil] + WindowsSettings.Zones.allCases.map(Optional.some), width: 180,
                             title: { $0.map(Self.zonesTitle) ?? "Off" }) { zones in
                    plugin.update { settings in
                        settings.zoneOverlay = zones != nil
                        if let zones { settings.zones = zones }
                    }
                }
            }
            if let note = nativeTilingNote {
                FrogRow(note) {
                    Button("Open Desktop & Dock") { MacWindowManagerReader.openDesktopAndDock() }.buttonStyle(.frog(.ghost))
                }
            }
        }
    }

    private var panels: some View {
        FrogSection("Panels") {
            FrogRow("Layout picker", caption: "Every layout as a picture") {
                HStack(spacing: 10) {
                    commandRecorder(.layoutPicker).disabled(!settings.layoutPicker)
                    Toggle("Layout picker", isOn: binding(\.layoutPicker)).labelsHidden().toggleStyle(.switch)
                }
            }
            FrogRow("Cheat sheet", caption: "Hold to see every window shortcut") { commandRecorder(.cheatSheet) }
        }
    }

    private var sizes: some View {
        FrogSection("Sizes") {
            FrogRow("Gap between windows") {
                FrogDropdown(selected: settings.gap, options: Self.gapChoices(including: settings.gap), width: 180,
                             title: { "\($0) pt" }) { gap in plugin.update { $0.gap = gap } }
            }
            FrogRow("Cycle sizes when pressed again", caption: "½, ⅔ and ⅓") {
                Toggle("Cycle sizes when pressed again", isOn: binding(\.cycleSizes)).labelsHidden().toggleStyle(.switch)
            }
            FrogRow("Thirds top to bottom on tall displays") {
                Toggle("Thirds top to bottom on tall displays", isOn: binding(\.portraitThirds)).labelsHidden().toggleStyle(.switch)
            }
            FrogRow("Leave room for Stage Manager") {
                Toggle("Leave room for Stage Manager", isOn: binding(\.respectStageManager)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: Pieces

    /// Halves, quarters, thirds, sizes, displays and Restore, as the cheat sheet groups them.
    static let layoutOrder: [WindowAction] = WindowAction.allCases.enumerated().sorted { first, second in
        let a = WindowCheatSheet.order.firstIndex(of: WindowCheatSheet.group(for: first.element)) ?? .max
        let b = WindowCheatSheet.order.firstIndex(of: WindowCheatSheet.group(for: second.element)) ?? .max
        return (a, first.offset) < (b, second.offset)
    }.map(\.element)

    static func zonesTitle(_ zones: WindowsSettings.Zones) -> String {
        ZoneGrid(rawValue: zones.rawValue)?.title ?? zones.rawValue
    }

    /// The gaps the menu offers, with the saved one when it is not among them.
    static func gapChoices(including current: Int) -> [Int] {
        Set([0, 2, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, current]).filter { WindowPreferences.gapRange.contains($0) }.sorted()
    }

    /// Why Frog's edges, or its top edge, are paused; nil while they are not.
    private var nativeTilingNote: String? {
        if macOS.edgeTiling { return settings.zoneOverlay ? "macOS tiles at the edges: hold Shift for Frog's zones" : "macOS tiles at the edges, so Frog's are paused" }
        if macOS.topEdgeTiling { return "macOS fills the screen at the top edge" }
        return nil
    }

    private func binding(_ field: WritableKeyPath<WindowsSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: field] }, set: { value in plugin.update { $0[keyPath: field] = value } })
    }

    /// A command's shortcut. One the window switcher uses is refused, so the switcher keeps working.
    private func commandRecorder(_ command: WindowCommand) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HotkeyRecorder(hotkey: Binding(get: { settings.shortcut(command)?.hotkey }, set: { value in
                if let value, WindowSwitcherPlugin.chords(model.configuration.preferences).contains(value) {
                    model.report(FrogError.message("The window shortcut for \(command.title) conflicts with another shortcut."))
                    return
                }
                do {
                    let shortcut = try value.map { try Shortcut($0) }
                    plugin.update { $0.setShortcut(shortcut, for: command) }
                } catch { model.report(error) }
            }))
            if let issue = model.hotkeyErrors[command.id] {
                Text(issue).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
            }
        }
    }

    private func useSuggestedShortcuts() {
        do {
            let result = try model.applySuggestedWindowShortcuts()
            suggestion = result.summary(display: HotkeyManager.display)
            // The suggestions write the preferences directly; config.toml follows.
            plugin.adoptLegacyCommands()
        } catch { model.report(error) }
    }
}

/// One layout in the grid: its picture, its name and its shortcut. Recording a shortcut turns the layout on,
/// clearing it turns it off.
private struct LayoutShortcutCell: View {
    let rule: Rule
    let issue: String?
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let action = rule.action?.windowAction { WindowLayoutGlyph(action: action).frame(width: 22, height: 22) }
            Text(L10n.text(rule.name)).font(FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1)
                .opacity(rule.hotkey != nil && !rule.enabled ? 0.5 : 1)
            if let issue {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(FrogStyle.warning).help(issue)
            }
            Spacer(minLength: 8)
            HotkeyRecorder(hotkey: Binding(get: { rule.hotkey }, set: { value in
                var updated = rule; updated.hotkey = value; updated.enabled = value != nil
                do { try model.saveRule(updated) } catch { model.report(error) }
            }), emptyTitle: "Add")
        }
        .frame(minHeight: FrogStyle.rowHeight)
    }
}
