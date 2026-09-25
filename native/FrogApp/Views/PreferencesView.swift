import SwiftUI
import AppKit
import FrogCore
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notificationRequested = false
    @State private var pendingConfiguration: Configuration?
    @State private var showingImportConfirmation = false

    var body: some View {
        PageScroll {
            PageHeader(title: "Settings", subtitle: "Startup, permissions, and local data.")
            SectionCaption(text: "Appearance")
            AppearanceSettingsView()
            SectionCaption(text: "Defaults & audio")
            WorkflowSettingsCard()
            WorkflowAdvancedSettings()
            SectionCaption(text: "General")
            FrogCard {
                VStack(spacing: 12) {
                    SettingRow(title: "Start at login", description: "Keep Frog available after sign-in.") {
                        Toggle("Start Frog at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    HStack {
                        Label(model.loginStatus, systemImage: "power").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                        Spacer()
                    }
                    ruleDivider
                    SettingRow(title: "Writing indicator", description: "Brief status for text actions.") {
                        Toggle("Show processing indicator", isOn: preference(\.showProcessingIndicator))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }
            SectionCaption(text: "Configuration")
            FrogCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Button("Export…", systemImage: "square.and.arrow.up") { exportConfiguration() }
                        Button("Import…", systemImage: "square.and.arrow.down") { chooseConfiguration() }
                            .disabled(model.isProcessing || model.isTestingProvider)
                    }
                    Text("JSON includes rules, providers and appearance. No keys, audio, model weights or history.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                }
            }
            SectionCaption(text: "History")
            FrogCard {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "History", description: "Save text and transcription results locally.") {
                        Toggle("Record successful transformations", isOn: preference(\.historyEnabled))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    ruleDivider
                    HStack(spacing: 24) {
                        historyLimit
                        Rectangle().fill(FrogStyle.border).frame(width: 1, height: 42)
                        historyRetention
                    }
                    Text("Turning off stops new entries. Retention limits apply to saved history.")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                }
            }
            SectionCaption(text: "Permissions")
            FrogCard {
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    Text(DictationController.microphoneGranted ? "Allowed" : "Needs access").font(.caption).foregroundStyle(.secondary)
                    Button("Configure") { Task { _ = await DictationController.requestMicrophone(); DictationController.openMicrophoneSettings(); model.objectWillChange.send() } }
                }
            }
            FrogCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Accessibility").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                FrogBadge(text: model.accessibilityGranted ? "Allowed" : "Needs access", active: model.accessibilityGranted)
                            }
                            Text("For writing, paste and window switching.")
                                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                        }
                    }
                    HStack(spacing: 10) {
                        if !model.accessibilityGranted {
                            Button("Allow access") { SelectionService.requestAccess(); model.refreshSystemStatus() }
                                .buttonStyle(FrogButtonStyle(primary: true))
                        }
                        Button("Open System Settings", systemImage: "arrow.up.right") { SelectionService.openAccessibilitySettings() }
                        Spacer()
                        Button { model.refreshSystemStatus() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh permission status").help("Refresh permission status")
                    }
                    if !model.accessibilityGranted {
                        DisclosureGroup("Troubleshoot access") {
                        Text("Already enabled but still denied? Quit Frog, remove its old entry with the minus button in Accessibility, then add /Applications/Frog.app and enable it again. Toggling an old entry may retain its old signature. Always quit Frog before moving or replacing the app, then reopen the installed copy.")
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                        }
                    }
                    ruleDivider
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notifications").font(.system(size: 14, weight: .semibold))
                            Text("Background results and errors.")
                                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Allow notifications…") {
                        DesktopNotifications.requestAuthorization()
                        notificationRequested = true
                    }
                    if notificationRequested {
                        Text("No prompt? Manage Frog in System Settings → Notifications.")
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    }
                }
            }
            FrogCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Privacy", systemImage: "lock.shield").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FrogStyle.accent)
                    Text("Built-in models run locally. Cloud rules send text to your chosen provider. No analytics or Frog account.")
                }.font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
            }
        }.onAppear { model.refreshSystemStatus() }
        .confirmationDialog("Import this configuration?", isPresented: $showingImportConfirmation, titleVisibility: .visible) {
            Button("Replace configuration") {
                guard let pendingConfiguration else { return }
                do { try model.importConfiguration(pendingConfiguration) } catch { model.report(error) }
                self.pendingConfiguration = nil
            }
            Button("Cancel", role: .cancel) { pendingConfiguration = nil }
        } message: {
            if let pendingConfiguration {
                Text("Replace your current setup with \(pendingConfiguration.rules.count) rules and \(pendingConfiguration.providers.count) providers. The current file is backed up first. Matching connections keep their saved keys; others need keys entered again. History recording will be \(pendingConfiguration.preferences.historyEnabled ? "on" : "off"), and imported retention limits apply to existing history.")
            }
        }
    }

    private var ruleDivider: some View { Rectangle().fill(FrogStyle.border).frame(height: 1) }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Frog-configuration.json"
        panel.title = "Export Frog configuration"
        panel.message = "API keys and text history are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportConfiguration(to: url) } catch { model.report(error) }
    }

    private func chooseConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Frog configuration"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingConfiguration = try ConfigurationFile.read(from: url)
            showingImportConfirmation = true
        } catch { model.report(error) }
    }

    private var historyLimit: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maximum entries").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            Stepper(value: preference(\.historyLimit), in: 1...200) {
                Text("\(model.configuration.preferences.historyLimit)").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            }.accessibilityLabel("Maximum history entries")
        }.frame(maxWidth: .infinity)
    }

    private var historyRetention: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep for").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            Stepper(value: preference(\.historyRetentionDays), in: 1...30) {
                Text("\(model.configuration.preferences.historyRetentionDays) days").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            }.accessibilityLabel("History retention in days")
        }.frame(maxWidth: .infinity)
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { model.configuration.preferences[keyPath: keyPath] }, set: { value in
            var preferences = model.configuration.preferences
            preferences[keyPath: keyPath] = value
            do { try model.savePreferences(preferences) } catch { model.report(error) }
        })
    }
}
