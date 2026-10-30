import SwiftUI
import FrogCore

/// Hidden bar's page: the arrow's state, how long icons stay shown, and the shortcut.
struct HiddenBarPage: View {
    @ObservedObject var plugin: HiddenBarPlugin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Hidden bar", subtitle: "Hold ⌘ and drag icons left of the divider to hide them.")
            if let organizer = plugin.organizer {
                HiddenBarArrangement(organizer: organizer, alwaysHidden: plugin.settings.alwaysHiddenSection) {
                    organizer.configure(enabled: true, settings: plugin.settings.organizer)
                }
            }
            FrogSection {
                FrogRow("Hide again automatically") {
                    Toggle("Hide again automatically", isOn: binding(\.autoHide, reveal: true)).labelsHidden().toggleStyle(.switch)
                }
                if plugin.settings.autoHide {
                    FrogRow("After") {
                        FrogDropdown(selection: binding(\.autoHideSeconds), options: Set([5.0, 10, 15, 30, 60, plugin.settings.autoHideSeconds]).sorted(),
                                     width: 180, title: { "\($0.formatted(.number.precision(.fractionLength(0...1)))) seconds" })
                    }
                }
                FrogRow("Hide when Frog starts") {
                    Toggle("Hide when Frog starts", isOn: binding(\.startHidden)).labelsHidden().toggleStyle(.switch)
                }
                FrogRow("Show on hover") {
                    Toggle("Show on hover", isOn: binding(\.showOnHover)).labelsHidden().toggleStyle(.switch)
                }
                FrogRow("Always-hidden section", caption: "Icons left of a second divider stay hidden.") {
                    Toggle("Always-hidden section", isOn: binding(\.alwaysHiddenSection)).labelsHidden().toggleStyle(.switch)
                }
                FrogRow("Shortcut") {
                    HotkeyRecorder(hotkey: Binding(get: { plugin.settings.shortcut?.hotkey },
                                                   set: { hotkey in plugin.update { $0.shortcut = hotkey.flatMap { try? Shortcut($0) } } }))
                }
                if let error = plugin.shortcutError { InlineIssue(message: error).padding(.vertical, 6) }
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<HiddenBarSettings, Value>, reveal: Bool = false) -> Binding<Value> {
        Binding(get: { plugin.settings[keyPath: key] }, set: { value in
            withAnimation(reveal && !reduceMotion ? FrogMotion.reveal : nil) { plugin.update { $0[keyPath: key] = value } }
        })
    }
}

/// A picture of the menu bar with the arrow's state, and the two things the arrow does.
private struct HiddenBarArrangement: View {
    @ObservedObject var organizer: MenuBarOrganizer
    let alwaysHidden: Bool
    let retry: () -> Void

    var body: some View {
        FrogSection {
            VStack(alignment: .leading, spacing: 10) {
                preview
                HStack(spacing: 8) {
                    Button(organizer.isExpanded ? "Hide icons" : "Show icons") { organizer.toggle() }
                    Button(organizer.isEditingArrangement ? "Done" : "Arrange…") {
                        organizer.setEditingArrangement(!organizer.isEditingArrangement)
                    }
                    Spacer()
                    Text(organizer.isEditingArrangement ? "Arranging" : organizer.isExpanded ? "Shown" : "Hidden")
                        .font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }.disabled(!organizer.isInstalled)
                if let issue = organizer.issue {
                    InlineIssue(message: issue)
                    if !organizer.isInstalled { Button("Retry", action: retry) }
                }
            }.padding(.vertical, 10)
        }
        // A closed, minimised or covered settings window keeps this page, so appearing and
        // disappearing do not say whether it can be seen. Out of sight it must not hold the icons open.
        .background(FeatureVisibility { visible in
            // Leaving the page ends arranging, which the organizer publishes: never inside the update that removes the page.
            DispatchQueue.main.async { organizer.setSettingsVisible(visible) }
        })
    }

    private var preview: some View {
        HStack(spacing: 14) {
            if alwaysHidden {
                Image(systemName: "ellipsis").foregroundStyle(FrogStyle.muted)
                Text("‖").foregroundStyle(FrogStyle.muted)
            }
            HStack(spacing: 14) {
                Image(systemName: "cloud")
                Image(systemName: "externaldrive")
                Image(systemName: "headphones")
            }.frame(maxWidth: .infinity).opacity(organizer.isExpanded ? 1 : 0.25)
            Text("|").foregroundStyle(FrogStyle.muted)
            HStack(spacing: 14) {
                Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
                Image(nsImage: NativeOrganizerStatusItems.arrowImage(expanded: organizer.isExpanded))
            }.frame(maxWidth: .infinity)
        }.font(.system(size: 14)).padding(.vertical, 16).padding(.horizontal, 18).foregroundStyle(FrogStyle.ink)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(organizer.isExpanded ? "Menu bar: hidden icons shown" : "Menu bar: icons hidden")
    }
}
