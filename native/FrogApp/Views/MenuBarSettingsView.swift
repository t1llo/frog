import SwiftUI
import FrogCore

struct MenuBarSettingsView: View {
    @ObservedObject var organizer: MenuBarOrganizer
    @Binding var settings: MenuBarPreferences

    var body: some View {
        PageScroll {
            PageHeader(title: "Menu bar")
            SettingsSection(title: "Your menu bar") {
                arrangementPreview
                Text("Hold ⌘ and drag icons left of the divider to hide them.")
                    .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(organizer.isExpanded ? "Hide icons" : "Show hidden icons") { organizer.toggle() }
                        .disabled(!organizer.isInstalled)
                    Button(organizer.isEditingArrangement ? "Done arranging" : "Show all & arrange…") {
                        organizer.setEditingArrangement(!organizer.isEditingArrangement)
                    }.disabled(!organizer.isInstalled)
                    Spacer()
                    Text(organizer.isEditingArrangement ? "Arranging" : organizer.isExpanded ? "Shown" : "Hidden")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                if let issue = organizer.issue {
                    InlineIssue(message: issue)
                    if !organizer.isInstalled {
                        Button("Retry") { organizer.configure(enabled: organizer.isEnabled, settings: settings) }
                    }
                }
            }
            SettingsSection(title: "Behavior") {
                CompactRow(title: "Automatically hide icons") {
                    Toggle("Automatically hide icons", isOn: $settings.autoHide).labelsHidden().toggleStyle(.switch)
                }
                if settings.autoHide {
                    CompactRow(title: "Hide after") {
                        CompactMenu(value: "\(settings.autoHideSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds", width: 180) {
                            ForEach([5.0, 10, 15, 30, 60], id: \.self) { seconds in
                                Button("\(Int(seconds)) seconds") { settings.autoHideSeconds = seconds }.accessibilityAddTraits(settings.autoHideSeconds == seconds ? .isSelected : [])
                            }
                        }
                    }
                }
                Divider()
                CompactRow(title: "Hide icons when Frog starts") {
                    Toggle("Hide icons when Frog starts", isOn: $settings.startCollapsed).labelsHidden().toggleStyle(.switch)
                }
                CompactRow(title: "Show on hover") {
                    Toggle("Show on hover", isOn: $settings.hoverToReveal).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                CompactRow(title: "Show / hide shortcut") { HotkeyRecorder(hotkey: $settings.hotkey) }
                if let error = organizer.hotkeyError { InlineIssue(message: error) }
            }
            SettingsSection(title: "Always-hidden icons") {
                CompactRow(title: "Use a second divider", detail: "Icons left of it stay hidden when you click the arrow.") {
                    Toggle("Use a second divider", isOn: $settings.permanentlyHiddenSection).labelsHidden().toggleStyle(.switch)
                }
            }
            Text("Icon out of reach? Open Frog from Applications and choose Show all & arrange.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        // A closed, minimised or covered settings window keeps this page, so appearing and
        // disappearing do not say whether it can be seen. Out of sight it must not hold the icons open.
        .background(FeatureVisibility { visible in
            // Leaving the page ends arranging, which the organizer publishes: never inside the update that removes the page.
            DispatchQueue.main.async { organizer.setSettingsVisible(visible) }
        })
    }

    private var arrangementPreview: some View {
        HStack(spacing: 14) {
            if settings.permanentlyHiddenSection {
                Image(systemName: "ellipsis").foregroundStyle(FrogStyle.muted)
                Text("‖").foregroundStyle(FrogStyle.muted)
            }
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: "cloud")
                    Image(systemName: "externaldrive")
                    Image(systemName: "headphones")
                }.font(.system(size: 14)).opacity(organizer.isExpanded ? 1 : 0.25)
                Text("Hidden icons").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity)
            Rectangle().fill(FrogStyle.muted).frame(width: 1, height: 34)
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100percent")
                    Image(nsImage: NativeOrganizerStatusItems.arrowImage(expanded: organizer.isExpanded))
                }.font(.system(size: 14))
                Text("Always visible").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity)
        }.padding(18).foregroundStyle(FrogStyle.ink)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Menu bar layout: hidden icons, divider, visible icons and arrow. Command-drag to arrange.")
    }
}
