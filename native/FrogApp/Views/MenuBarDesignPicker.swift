import AppKit
import SwiftUI
import FrogCore

/// One tile per design, each drawn as the menu bar will show it; the chosen one is highlighted.
struct MenuBarDesignTiles<Choice: Hashable>: View {
    let choices: [Choice]
    let selected: Choice
    let title: (Choice) -> String
    /// The design's image for a dark (true) or light menu bar.
    let image: (Choice, Bool) -> NSImage
    let choose: (Choice) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices, id: \.self) { choice in
                MenuBarDesignTile(title: L10n.text(title(choice)), image: image(choice, scheme == .dark), chosen: choice == selected) { choose(choice) }
            }
        }
    }
}

private struct MenuBarDesignTile: View {
    let title: String
    let image: NSImage
    let chosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 7) {
                MenuBarPreviewStrip(image: image)
                Text(title).font(chosen ? FrogType.label : FrogType.small)
                    .foregroundStyle(chosen ? FrogStyle.ink : FrogStyle.muted)
            }
            .padding(7).frame(maxWidth: .infinity)
            .frogRowHighlight(hovering: hovering, selected: chosen)
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(title).accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A strip of menu bar with one item on it, in the menu bar's light or dark look.
struct MenuBarPreviewStrip: View {
    let image: NSImage
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .frame(maxWidth: .infinity).frame(height: FrogStyle.controlHeight)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius))
            .accessibilityHidden(true)
    }
}

/// The colours of a meter, below its design tiles.
struct MenuBarPaletteRow: View {
    let selected: MenuBarMeterPalette
    let choose: (MenuBarMeterPalette) -> Void
    var body: some View {
        CompactRow(title: "Colors") {
            CompactSegments(values: MenuBarMeterPalette.allCases, selected: selected, width: 270, title: { $0.title }, choose: choose)
                .accessibilityLabel("Menu bar colors")
        }
    }
}

/// The CPU and GPU item's switch and looks, on the System monitor page.
struct SystemMonitorMenuBarSettings: View {
    @EnvironmentObject private var model: AppModel
    /// What the previews show, so that every design can be compared on the same load.
    private static let sample = SystemMonitorReading(cpu: .value(0.42), gpu: .value(0.78))
    private var settings: SystemMonitorPreferences {
        model.configuration.preferences.toolkitSettings.systemMonitor ?? SystemMonitorPreferences()
    }

    var body: some View {
        let settings = settings
        SettingsSection(title: "Menu bar") {
            CompactRow(title: "Show CPU and GPU in the menu bar") {
                Toggle("Show CPU and GPU in the menu bar", isOn: Binding(get: { settings.menuBarItem }, set: { on in save { $0.menuBarItem = on } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if settings.menuBarItem {
                MenuBarDesignTiles(choices: MenuBarMeterStyle.allCases, selected: MenuBarMeterStyle(choice: settings.menuBarStyle),
                                   title: { $0.title }, image: { style, dark in
                    var preview = settings; preview.menuBarStyle = style.rawValue
                    return MenuBarMeter.image(SystemMonitorStatusItemController.face(Self.sample, preferences: preview, dark: dark))
                }) { style in save { $0.menuBarStyle = style.rawValue } }
                MenuBarPaletteRow(selected: MenuBarMeterPalette(choice: settings.menuBarPalette)) { palette in
                    save { $0.menuBarPalette = palette.rawValue }
                }
            }
        }
    }

    private func save(_ change: (inout SystemMonitorPreferences) -> Void) {
        var preferences = model.configuration.preferences
        var value = settings
        change(&value)
        preferences.ensureToolkit()
        preferences.toolkit?.systemMonitor = value
        do { try model.savePreferences(preferences) } catch { model.report(error) }
    }
}

/// The Stay awake page's menu-bar choices.
struct StayAwakeMenuBarSettings: View {
    @EnvironmentObject private var model: AppModel
    private var settings: StayAwakePreferences {
        model.configuration.preferences.toolkitSettings.stayAwake ?? StayAwakePreferences()
    }

    var body: some View {
        let settings = settings
        SettingsSection(title: "Menu bar") {
            CompactRow(title: "Show a cup in the menu bar", detail: "While Stay awake is on, instead of the cup next to Frog's icon.") {
                Toggle("Show a cup in the menu bar", isOn: Binding(get: { settings.menuBarItem }, set: { on in save { $0.menuBarItem = on } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if settings.menuBarItem {
                // A session with two hours and twenty minutes of four left.
                let deadline = Date().addingTimeInterval(140 * 60 + 30)
                MenuBarDesignTiles(choices: StayAwakePreferences.menuBarStyles, selected: settings.menuBarStyle,
                                   title: { ["icon": "Cup", "ring": "Countdown ring", "time": "Time left"][$0] ?? $0 }, image: { style, _ in
                    StayAwakeIcon.image(StayAwakeIcon.Face(style: style, deadline: deadline, duration: 4 * 3600))
                }) { style in save { $0.menuBarStyle = style } }
            }
        }
    }

    private func save(_ change: (inout StayAwakePreferences) -> Void) {
        var preferences = model.configuration.preferences
        var value = settings
        change(&value)
        preferences.ensureToolkit()
        preferences.toolkit?.stayAwake = value
        do { try model.savePreferences(preferences) } catch { model.report(error) }
    }
}
