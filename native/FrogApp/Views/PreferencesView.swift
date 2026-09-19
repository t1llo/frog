import SwiftUI
import FrogCore

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notificationRequested = false

    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: "Settings", subtitle: "Control startup, local history, and macOS permissions.")
            Form {
                Section("Startup") {
                    Toggle("Start Frog at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                    Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Frog stays in the menu bar when its window is closed.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Local history") {
                    Toggle("Record successful transformations", isOn: preference(\.historyEnabled))
                    Text("History includes original and processed text. Turning recording off stops new records, including requests in progress, and preserves existing entries until deletion or expiry.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(value: preference(\.historyLimit), in: 1...200, step: 1) {
                        Text("Keep up to \(model.configuration.preferences.historyLimit) entries")
                    }
                    Stepper(value: preference(\.historyRetentionDays), in: 1...30, step: 1) {
                        Text("Keep entries for \(model.configuration.preferences.historyRetentionDays) days")
                    }
                    Text("Changes to these limits also apply to existing history.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Accessibility") {
                    Label(model.accessibilityGranted ? "Accessibility access is granted" : "Accessibility access is needed for in-place replacement",
                          systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "hand.raised")
                        .foregroundStyle(model.accessibilityGranted ? .green : .secondary)
                    Text("Allow Frog in System Settings → Privacy & Security → Accessibility. This lets Frog read the selected text and replace it in supported editable fields. You can use Try text without this permission.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Request access") { SelectionService.requestAccess(); model.refreshSystemStatus() }
                            .disabled(model.accessibilityGranted)
                        Button("Open Accessibility settings") { SelectionService.openAccessibilitySettings() }
                        Button("Refresh status") { model.refreshSystemStatus() }
                    }
                }
                Section("Notifications") {
                    Text("Allow notifications for background results and errors. Frog also displays status in its menu and window.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow notifications…") {
                        DesktopNotifications.requestAuthorization()
                        notificationRequested = true
                    }
                    if notificationRequested {
                        Text("If macOS does not show a prompt, manage Frog in System Settings → Notifications.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Using Frog") {
                    Text("1. Add a provider and choose it as the default.\n2. Enable a rule and record its global shortcut.\n3. Select text in an editable field in another app and press the shortcut.")
                    Text("Successful output is copied to the clipboard. If the original target changes or cannot be safely edited, paste the copied result yourself. Cloud providers receive the selected text and rule instructions; local endpoints keep processing on your own server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.onAppear { model.refreshSystemStatus() }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { model.configuration.preferences[keyPath: keyPath] }, set: { value in
            var preferences = model.configuration.preferences
            preferences[keyPath: keyPath] = value
            do { try model.savePreferences(preferences) } catch { model.report(error) }
        })
    }
}
