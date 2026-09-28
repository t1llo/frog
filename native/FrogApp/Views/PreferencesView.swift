import SwiftUI
import AppKit
import FrogCore
import UniformTypeIdentifiers

struct PreferencesView: View {
    var permissionsRequest: UUID? = nil
    @EnvironmentObject private var model: AppModel
    @State private var pendingConfiguration: Configuration?
    @State private var confirmingImport = false
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings", subtitle: "")
                SettingsSection(title: "General") {
                    CompactRow(title: "Start at login") { Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: model.setStartAtLogin)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Writing indicator") { Toggle("Writing indicator", isOn: preference(\.showProcessingIndicator)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Show rule shortcuts", detail: "Hold the shortcut to see your rules; release to dismiss.") {
                        HotkeyRecorder(hotkey: Binding(get: { prefs.shortcutPanelHotkey }, set: { value in update { $0.shortcutPanelHotkey = value } }))
                    }
                    if let issue = model.hotkeyErrors[AppModel.shortcutPanelID] { Text(issue).font(.caption).foregroundStyle(.orange) }
                    Divider()
                    CompactRow(title: "Application shortcuts", detail: "Application launch shortcuts and the Command–Tab switcher.") {
                        Toggle("Application shortcuts", isOn: Binding(get: { model.configuration.preferences.shortcutsEnabled }, set: { value in
                            var preferences = model.configuration.preferences; preferences.applicationShortcutsEnabled = value
                            do { try model.savePreferences(preferences) } catch { model.report(error) }
                        })).labelsHidden()
                    }
                }
                SettingsSection(title: "Appearance") { AppearanceSettingsView() }
                SettingsSection(title: "Internal models") {
                    CompactRow(title: "Unload idle models", detail: "Applies to models running inside Frog.") {
                        CompactMenu(value: prefs.idleUnloadSeconds == 0 ? "Immediately" : "\(prefs.idleUnloadSeconds / 60) min") {
                            Button("Immediately") { update { $0.idleUnloadSeconds = 0 } }
                            ForEach([120, 300, 900], id: \.self) { seconds in Button("\(seconds / 60) min") { update { $0.idleUnloadSeconds = seconds } } }
                        }
                    }
                    Divider()
                    CompactRow(title: model.localModels.loaded.isEmpty ? "No models loaded" : "Models in memory") {
                        Button("Unload now") { Task { await model.localModels.unload() } }.disabled(model.localModels.loaded.isEmpty || model.localModels.busy || model.dictation.active)
                    }
                }
                SettingsSection(title: "Model storage") {
                    Text(model.localModels.root.path).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                    Text("Existing downloads stay in their current folder.").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    HStack {
                        Button("Choose folder…") { chooseModelFolder() }
                        Button("Use default") { setModelFolder(model.localModels.defaultDirectory) }.disabled(model.localModels.root == model.localModels.defaultDirectory)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.localModels.root.path) }
                    }.disabled(model.localModels.busy || !model.localModels.progress.isEmpty || model.dictation.active)
                }
                SettingsSection(title: "Recording") {
                    CompactRow(title: "Microphone") {
                        CompactMenu(value: DictationController.devices.first { String($0.id) == prefs.microphoneID }?.name ?? "System default") {
                            Button { update { $0.microphoneID = nil } } label: { Label("System default", systemImage: prefs.microphoneID == nil ? "checkmark" : "mic") }
                            ForEach(DictationController.devices, id: \.id) { device in
                                Button { update { $0.microphoneID = String(device.id) } } label: { Label(device.name, systemImage: prefs.microphoneID == String(device.id) ? "checkmark" : "mic") }
                            }
                        }
                    }
                    Divider()
                    CompactRow(title: "Mute Mac audio while recording") { Toggle("Mute Mac audio while recording", isOn: Binding(get: { prefs.muteWhileRecording ?? false }, set: { value in update { $0.muteWhileRecording = value } })).labelsHidden() }
                    Divider()
                    CompactRow(title: "Cancel recording", detail: "Escape always cancels.") {
                        HotkeyRecorder(hotkey: Binding(get: { prefs.cancelRecordingHotkey }, set: { value in update { $0.cancelRecordingHotkey = value } }))
                    }
                    if let issue = model.hotkeyErrors[AppModel.cancelRecordingID] { Text(issue).font(.caption).foregroundStyle(.orange) }
                }
                SettingsSection(title: "Permissions") {
                    permission("Accessibility", allowed: model.accessibilityGranted) { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
                    Divider()
                    permission("Microphone", allowed: DictationController.microphoneGranted) {
                        Task { if !DictationController.microphoneGranted { _ = await DictationController.requestMicrophone() }; DictationController.openMicrophoneSettings(); model.objectWillChange.send() }
                    }
                    Divider()
                    CompactRow(title: "Notifications") { Button("Allow…") { DesktopNotifications.requestAuthorization() } }
                }.id("permissions")
                SettingsSection(title: "History") {
                    CompactRow(title: "Save history on this Mac") { Toggle("Save history on this Mac", isOn: preference(\.historyEnabled)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Maximum entries") { Stepper("\(model.configuration.preferences.historyLimit)", value: preference(\.historyLimit), in: 1...200).fixedSize() }
                    Divider()
                    CompactRow(title: "Retention") { Stepper("\(model.configuration.preferences.historyRetentionDays) days", value: preference(\.historyRetentionDays), in: 1...30).fixedSize() }
                    Divider()
                    Text(model.historyFileURL.path).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                }
                SettingsSection(title: "Configuration") {
                    CompactRow(title: "Import / export", detail: "Rules, models and preferences. API keys stay in Keychain.") {
                        HStack {
                            Button("Import…") { chooseConfiguration() }.disabled(model.isProcessing || model.isTestingProvider || model.dictation.active)
                            Button("Export…") { exportConfiguration() }
                        }
                    }
                }
                SettingsSection(title: "Updates") { UpdateSettingsView() }
                SettingsSection(title: "About") {
                    CompactRow(title: "Frog") { Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))").foregroundStyle(FrogStyle.muted) }
                    CompactRow(title: "Source code") { Link("GitHub ↗", destination: URL(string: "https://github.com/t1llo/frog")!) }
                    Text("Internal models run on your Mac. External providers receive the text or audio you send. No analytics.").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
            }.toggleStyle(.switch).controlSize(.small).padding(20).frame(maxWidth: 630).frame(maxWidth: .infinity)
        }.onAppear { model.refreshSystemStatus() }
            .task(id: permissionsRequest) {
                guard permissionsRequest != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation { proxy.scrollTo("permissions", anchor: .top) }
            }
            .confirmationDialog("Replace configuration?", isPresented: $confirmingImport) {
                Button("Replace configuration") { if let pendingConfiguration { do { try model.importConfiguration(pendingConfiguration) } catch { model.report(error) } }; pendingConfiguration = nil }
                Button("Cancel", role: .cancel) { pendingConfiguration = nil }
            } message: { Text("The current settings are backed up. Provider keys may need to be re-entered.") }
        }
    }
    private func permission(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        CompactRow(title: title) {
            HStack(spacing: 10) {
                Label(allowed ? "Allowed" : "Permission needed", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(allowed ? FrogStyle.accent : .orange)
                Button(allowed ? "Manage…" : "Allow…", action: action)
            }
        }
    }
    private func update(_ body: (inout WorkflowPreferences) -> Void) { var value = prefs; body(&value); do { try model.saveWorkflowPreferences(value) } catch { model.report(error) } }
    private func preference<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> { Binding(get: { model.configuration.preferences[keyPath: key] }, set: { value in var preferences = model.configuration.preferences; preferences[keyPath: key] = value; do { try model.savePreferences(preferences) } catch { model.report(error) } }) }
    private func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Frog-configuration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportConfiguration(to: url) } catch { model.report(error) }
    }
    private func chooseConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pendingConfiguration = try ConfigurationFile.read(from: url); confirmingImport = true } catch { model.report(error) }
    }
    private func chooseModelFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = model.localModels.root; panel.title = "Model download folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }; setModelFolder(url)
    }
    private func setModelFolder(_ url: URL) { guard !model.dictation.active else { return }; Task { do { try await model.localModels.changeDirectory(to: url) } catch { model.report(error) } } }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 7) { content }.padding(12).frame(maxWidth: .infinity).frogTableSurface()
        }
    }
}
