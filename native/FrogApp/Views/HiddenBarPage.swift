import SwiftUI
import FrogCore

/// Hidden bar's page: the arrow's state, how long icons stay shown, and the shortcut.
struct HiddenBarPage: View {
    @ObservedObject var plugin: HiddenBarPlugin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Hidden bar", subtitle: "Hold ⌘ and drag icons left of the divider to hide them.")
            // Like every feature page: where things stand at the top, as a picture of the menu bar, then the settings.
            HiddenBarArrangement(organizer: plugin.organizer, alwaysHidden: plugin.settings.alwaysHiddenSection) {
                plugin.organizer?.configure(enabled: true, settings: plugin.settings.organizer)
            }
            FrogSection("Hiding") {
                FrogRow("Show or hide icons") {
                    HotkeyRecorder(hotkey: Binding(get: { plugin.settings.shortcut?.hotkey },
                                                   set: { hotkey in plugin.update { $0.shortcut = hotkey.flatMap { try? Shortcut($0) } } }))
                }
                if let error = plugin.shortcutError { FrogRowNote(text: error, tone: FrogStyle.warning) }
                // The delay gets its own row under the switch, shown only while it is on.
                FrogRow("Hide again automatically") {
                    Toggle("Hide again automatically", isOn: binding(\.autoHide, reveal: true)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
                if plugin.settings.autoHide {
                    FrogRow("Hide again after") {
                        FrogDropdown(selection: binding(\.autoHideSeconds), options: Set([5.0, 10, 15, 30, 60, plugin.settings.autoHideSeconds]).sorted(),
                                     width: 140, title: { "\($0.formatted(.number.precision(.fractionLength(0...1)))) seconds" })
                    }
                }
                FrogRow("Hide when Frog starts") {
                    Toggle("Hide when Frog starts", isOn: binding(\.startHidden)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
                FrogRow("Show on hover") {
                    Toggle("Show on hover", isOn: binding(\.showOnHover)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
                FrogRow("Always-hidden section", caption: "Icons left of a second divider stay hidden.") {
                    Toggle("Always-hidden section", isOn: binding(\.alwaysHiddenSection)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<HiddenBarSettings, Value>, reveal: Bool = false) -> Binding<Value> {
        Binding(get: { plugin.settings[keyPath: key] }, set: { value in
            withAnimation(reveal && !reduceMotion ? FrogMotion.reveal : nil) { plugin.update { $0[keyPath: key] = value } }
        })
    }
}

/// Where Hidden bar stands, as a picture of the menu bar: the items packed to the trailing edge as the menu bar
/// packs them, the hidden ones faded while the arrow hides them, and each section named under its own items, the
/// arrow's state ("Hidden", "Shown", "Arranging") under the icons it hides. The two things the arrow does follow.
private struct HiddenBarArrangement: View {
    /// Nil only where Frog runs without the menu bar (tests): the picture then shows the icons hidden, with no actions.
    let organizer: MenuBarOrganizer?
    let alwaysHidden: Bool
    let retry: () -> Void

    var body: some View {
        FrogSection("Menu bar") {
            VStack(alignment: .leading, spacing: FrogStyle.space10) {
                if let organizer {
                    ObservingArrangement(organizer: organizer, alwaysHidden: alwaysHidden, retry: retry)
                } else {
                    HiddenBarPreview(expanded: false, arranging: false, alwaysHidden: alwaysHidden)
                }
            }.padding(.vertical, FrogStyle.space10)
        }
    }
}

private struct ObservingArrangement: View {
    @ObservedObject var organizer: MenuBarOrganizer
    let alwaysHidden: Bool
    let retry: () -> Void

    var body: some View {
        HiddenBarPreview(expanded: organizer.isExpanded, arranging: organizer.isEditingArrangement, alwaysHidden: alwaysHidden)
        HStack(spacing: FrogStyle.space8) {
            Button(organizer.isExpanded ? "Hide icons" : "Show icons") { organizer.toggle() }
            Button(organizer.isEditingArrangement ? "Done" : "Arrange…") {
                organizer.setEditingArrangement(!organizer.isEditingArrangement)
            }
        }.disabled(!organizer.isInstalled)
            // A closed, minimised or covered settings window keeps this page, so appearing and
            // disappearing do not say whether it can be seen. Out of sight it must not hold the icons open.
            .background(FeatureVisibility { visible in
                // Leaving the page ends arranging, which the organizer publishes: never inside the update that removes the page.
                DispatchQueue.main.async { organizer.setSettingsVisible(visible) }
            })
        if let issue = organizer.issue {
            InlineIssue(message: issue)
            if !organizer.isInstalled { Button("Retry", action: retry) }
        }
    }
}

/// The menu bar in small: the Apple menu leading, then the bar's items packed to the trailing edge with the menu
/// bar's even spacing, and the clock last. The dividers are the organizer's own marks.
private struct HiddenBarPreview: View {
    let expanded: Bool
    let arranging: Bool
    let alwaysHidden: Bool
    /// The menu bar's height in the picture, and the room under it for the sections' names.
    private static let barHeight: CGFloat = 30
    private static let itemSpacing: CGFloat = 14

    var body: some View {
        let shown = expanded || arranging
        HStack(spacing: Self.itemSpacing) {
            Image(systemName: "apple.logo")
            Spacer(minLength: Self.itemSpacing)
            if alwaysHidden {
                group(caption: "Always hidden", emphasised: false, faded: !arranging) {
                    Image(systemName: "ellipsis")
                    Image(nsImage: OrganizerMark.dividerImage(double: true))
                }
            }
            group(caption: arranging ? "Arranging" : shown ? "Shown" : "Hidden", emphasised: true, faded: !shown) {
                Image(systemName: "cloud")
                Image(systemName: "externaldrive")
                Image(systemName: "headphones")
            }
            Image(nsImage: OrganizerMark.dividerImage(double: false))
            Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
            Image(nsImage: NativeOrganizerStatusItems.arrowImage(expanded: expanded))
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
            Text(Self.clock(FrogClock.now)).font(FrogType.row).monospacedDigit()
        }
        .font(.system(size: 14)).foregroundStyle(FrogStyle.ink)
        .frame(height: Self.barHeight)
        .padding(.horizontal, FrogStyle.space12)
        .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
        // The sections' names hang under the bar, so they never push its items apart.
        .padding(.bottom, FrogStyle.space16 + FrogStyle.space4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(arranging ? "Menu bar: arranging, every icon shown" : shown ? "Menu bar: hidden icons shown" : "Menu bar: icons hidden")
    }

    /// The menu bar's clock: "Sat Nov 7 13:40", without the "at" a date and time formatted together would add.
    static func clock(_ now: Date) -> String {
        [now.formatted(.dateTime.weekday(.abbreviated)), now.formatted(.dateTime.month(.abbreviated).day()),
         now.formatted(date: .omitted, time: .shortened)].joined(separator: " ")
    }

    /// A section of the bar, faded while hidden, with its name centred under it below the bar, never faded.
    private func group<Content: View>(caption: String, emphasised: Bool, faded: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Self.itemSpacing, content: content)
            .opacity(faded ? 0.35 : 1)
            .frame(height: Self.barHeight)
            .overlay(alignment: .top) {
                Text(L10n.text(caption)).font(FrogType.label).foregroundStyle(emphasised ? FrogStyle.ink : FrogStyle.muted)
                    .fixedSize().offset(y: Self.barHeight + FrogStyle.space4)
            }
    }
}
