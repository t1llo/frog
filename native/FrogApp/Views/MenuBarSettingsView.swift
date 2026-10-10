import SwiftUI
import FrogCore

struct MenuBarSettingsView: View {
    @ObservedObject var organizer: MenuBarOrganizer
    @Binding var settings: MenuBarPreferences

    var body: some View {
        PageScroll {
            PageHeader(title: "Menu bar", subtitle: "A quieter menu bar, with your everyday icons still in reach.")
            SettingsSection(title: "Your menu bar") {
                arrangementPreview
                Text("Hold ⌘ and drag icons left of the divider to hide them. Keep Frog and the icons you use most on the right.")
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
                Text("Click the arrow to show or hide. Right-click it for options. Option-click to show all and arrange.")
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection(title: "Behavior") {
                CompactRow(title: "Automatically hide icons", detail: "Waits until you finish using the menu bar or arranging icons.") {
                    Toggle("Automatically hide icons", isOn: $settings.autoHide).labelsHidden().toggleStyle(.switch)
                }
                if settings.autoHide {
                    CompactRow(title: "Hide after") {
                        CompactMenu(value: "\(settings.autoHideSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds", width: 180) {
                            ForEach([5.0, 10, 15, 30, 60], id: \.self) { seconds in
                                Button("\(Int(seconds)) seconds") { settings.autoHideSeconds = seconds }
                            }
                        }
                    }
                }
                Divider()
                CompactRow(title: "Hide icons when Frog starts") {
                    Toggle("Hide icons when Frog starts", isOn: $settings.startCollapsed).labelsHidden().toggleStyle(.switch)
                }
                CompactRow(title: "Show on hover", detail: "Pause the pointer over the menu bar to reveal hidden icons.") {
                    Toggle("Show on hover", isOn: $settings.hoverToReveal).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                CompactRow(title: "Show / hide shortcut") { HotkeyRecorder(hotkey: $settings.hotkey) }
                if let error = organizer.hotkeyError { InlineIssue(message: error) }
            }
            SettingsSection(title: "Always-hidden icons") {
                CompactRow(title: "Use a second divider", detail: "Icons left of the double divider stay hidden when you click the arrow. Option-click to arrange them.") {
                    Toggle("Use a second divider", isOn: $settings.permanentlyHiddenSection).labelsHidden().toggleStyle(.switch)
                }
            }
            Text("macOS remembers where you drag each icon. If something is out of reach, open Frog from Applications and choose Show all & arrange. A notch can limit the space available for revealed icons.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { organizer.setSettingsVisible(true) }
        .onDisappear { organizer.setSettingsVisible(false) }
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
