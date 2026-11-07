import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

/// What setup knows about the permissions the plugins that are on need. The setup step and its summary share it, so
/// both read the same system checks that Settings uses.
enum OnboardingPermissionSupport {
    /// The permissions macOS can report without asking. Local Network, Bluetooth and Full Disk Access are asked
    /// for, or noticed, the first time a feature uses them.
    static let checkable: Set<MacPermission> = [.accessibility, .microphone, .notifications]

    @MainActor static func wanted(_ model: AppModel) -> Set<MacPermission> {
        let on = model.pluginHost.descriptors.filter { model.pluginHost.enabled($0.id) }
        return Set(on.flatMap(\.info.permissions))
    }

    @MainActor static func needed(_ model: AppModel) -> [MacPermission] {
        let wanted = wanted(model)
        return MacPermission.allCases.filter { wanted.contains($0) && checkable.contains($0) }
    }

    /// The checkable permissions that are granted right now.
    @MainActor static func granted() async -> Set<MacPermission> {
        var now: Set<MacPermission> = []
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if DictationController.microphoneGranted { now.insert(.microphone) }
        if NotificationRouter.available {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional { now.insert(.notifications) }
        }
        return now
    }
}

/// The centrepiece of setup: one row per permission the chosen plugins need, with its state live. Accessibility is
/// granted in a list Frog has to be dragged into, so Grant opens that list and a small panel carries Frog's icon to
/// it. Microphone and Notifications use the system prompt.
struct OnboardingPermissions: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var granted: Set<MacPermission> = []
    /// False until the first check, which only records what is already granted.
    @State private var loaded = false
    /// Asked once and refused: the way on is System Settings.
    @State private var refused: Set<MacPermission> = []
    @FocusState private var focused: MacPermission?

    var body: some View {
        let needed = OnboardingPermissionSupport.needed(model)
        let later = Self.askedLater(OnboardingPermissionSupport.wanted(model))
        VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing - 6) {
            FrogSection("Needed by your features", footer: later) {
                if needed.isEmpty {
                    FrogRow("Nothing to allow", caption: "The features you chose need no permissions.")
                }
                ForEach(needed, id: \.self) { permission in
                    FrogRow(permission.title, caption: Self.reason(permission), icon: {
                        PluginIconTile(symbol: Self.symbol(permission), tint: Self.tint(permission).color, size: .list)
                    }, control: { control(for: permission) })
                    if refused.contains(permission), !granted.contains(permission) {
                        FrogRowNote(text: Self.refusedNote(permission), tone: FrogStyle.warning)
                    }
                }
            }
            if needed.contains(.accessibility), !granted.contains(.accessibility) {
                // How the one permission macOS cannot ask for is given, as three short steps.
                FrogSection("Allowing Accessibility") {
                    hint(1, "Grant opens Accessibility in System Settings.")
                    hint(2, "Drag Frog's icon from the small panel into the list.")
                    hint(3, "Switch Frog on. This step updates by itself.")
                }
            }
        }
        .animation(reduceMotion ? FrogMotion.reveal : FrogMotion.check, value: granted)
        .task {
            // Only while this step is open: a switch turned in System Settings shows here as soon as it flips.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { PermissionDragHelper.shared.hide() }
    }

    private func hint(_ number: Int, _ text: String) -> some View {
        HStack(spacing: FrogStyle.space10) {
            Text("\(number)").font(FrogType.label.monospacedDigit()).foregroundStyle(FrogStyle.muted)
                .frame(width: 20, height: 20).background(FrogStyle.control, in: Circle()).accessibilityHidden(true)
            Text(L10n.text(text)).font(FrogType.row).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.frame(minHeight: 32)
    }

    @ViewBuilder private func control(for permission: MacPermission) -> some View {
        if granted.contains(permission) {
            Label("Granted", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.good)
                .transition(.opacity)
        } else {
            Button("Grant") { request(permission) }.buttonStyle(.frog(.secondary))
                .focused($focused, equals: permission)
                .accessibilityLabel(Text(L10n.text("Grant \(permission.title)")))
        }
    }

    private static func reason(_ permission: MacPermission) -> String {
        switch permission {
        case .accessibility: "Read and replace selected text, and move and tile windows."
        case .microphone: "Record your voice while you dictate."
        case .notifications: "Show what arrives from your phone."
        default: ""
        }
    }

    private static func symbol(_ permission: MacPermission) -> String {
        switch permission {
        case .accessibility: "accessibility"
        case .microphone: "mic.fill"
        case .notifications: "bell.badge.fill"
        default: "lock.fill"
        }
    }

    private static func tint(_ permission: MacPermission) -> PluginTint {
        switch permission {
        case .accessibility: .blue
        case .microphone: .red
        case .notifications: .orange
        default: .gray
        }
    }

    private static func refusedNote(_ permission: MacPermission) -> String {
        "Turn Frog on in System Settings, then come back. This updates by itself."
    }

    private static func askedLater(_ wanted: Set<MacPermission>) -> String? {
        let names = MacPermission.allCases.filter { wanted.contains($0) && !OnboardingPermissionSupport.checkable.contains($0) }.map(\.title)
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: " and ")) \(names.count == 1 ? "is" : "are") asked for the first time \(names.count == 1 ? "it is" : "they are") needed."
    }

    private func refresh() async {
        let now = await OnboardingPermissionSupport.granted()
        if !loaded {
            // What was granted before the step opened is not news: no fade, no activation, no focus move.
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { granted = now; loaded = true }
            if now.contains(.accessibility) != model.accessibilityGranted { model.refreshSystemStatus() }
            return
        }
        guard now != granted else { return }
        let gained = now.subtracting(granted)
        granted = now
        if now.contains(.accessibility) != model.accessibilityGranted { model.refreshSystemStatus() }
        guard !gained.isEmpty else { return }
        // Bring Frog back after a switch turned in System Settings, and move focus to the next permission still missing.
        if gained.contains(.accessibility) { NSApp.activate() }
        focused = OnboardingPermissionSupport.needed(model).first { !now.contains($0) }
    }

    private func request(_ permission: MacPermission) {
        switch permission {
        case .accessibility:
            PermissionDragHelper.shared.present(.accessibility)
        case .microphone:
            Task {
                if !DictationController.microphoneGranted, !(await DictationController.requestMicrophone()) {
                    refused.insert(.microphone)
                    DictationController.openMicrophoneSettings()
                }
                await refresh()
            }
        case .notifications:
            guard NotificationRouter.available else { return }
            Task {
                let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                if !allowed {
                    refused.insert(.notifications)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                await refresh()
            }
        default: break
        }
    }
}
