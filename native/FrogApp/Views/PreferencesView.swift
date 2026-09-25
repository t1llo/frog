import SwiftUI
import AppKit
import FrogCore
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingConfiguration: Configuration?
    @State private var confirmingImport = false
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }
    private var provider: ProviderConfiguration? { model.configuration.providers.first { $0.id == model.configuration.defaultProviderID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings", subtitle: "")
                SettingsSection(title: "General") {
                    CompactRow(title: "Application language") {
                        CompactMenu(value: prefs.applicationLanguage == "de" ? "Deutsch" : prefs.applicationLanguage == "en" ? "English" : "System language") {
                            Button("System language") { update { $0.applicationLanguage = "system" } }
                            Button("English") { update { $0.applicationLanguage = "en" } }
                            Button("Deutsch") { update { $0.applicationLanguage = "de" } }
                        }
                    }
                    Divider()
                    CompactRow(title: "Start at login") { Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: model.setStartAtLogin)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Writing indicator") { Toggle("Writing indicator", isOn: preference(\.showProcessingIndicator)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Show rule shortcuts") {
                        HotkeyRecorder(hotkey: Binding(get: { prefs.shortcutPanelHotkey }, set: { value in update { $0.shortcutPanelHotkey = value } }))
                    }
                    if let issue = model.hotkeyErrors[AppModel.shortcutPanelID] { Text(issue).font(.caption).foregroundStyle(.orange) }
                }
                SettingsSection(title: "Appearance") { AppearanceSettingsView() }
                SettingsSection(title: "Defaults") {
                    CompactRow(title: "Text rules use") {
                        CompactMenu(value: prefs.effectiveTextSource == .frog ? "Inside Frog" : "Provider") {
                            Button("Provider") { update { $0.textSource = .provider } }
                            Button("Inside Frog") { update { $0.textSource = .frog } }
                        }
                    }
                    Divider()
                    CompactRow(title: "Default provider") {
                        CompactMenu(value: provider?.name ?? "Not configured") {
                            ForEach(model.configuration.providers) { item in
                                Button(item.name) { do { try model.setDefaultProvider(id: item.id, activate: false) } catch { model.report(error) } }
                            }
                        }
                    }
                    if let provider {
                        Divider()
                        CompactRow(title: "Provider model") {
                            CompactMenu(value: provider.modelName(provider.model)) {
                                ForEach(provider.models) { item in
                                    Button(item.name) { var updated = provider; updated.model = item.id; do { try model.saveProvider(updated, apiKey: nil, clearKey: false) } catch { model.report(error) } }
                                }
                            }
                        }
                    }
                    Divider()
                    localChoice("Inside Frog text model", selected: prefs.defaultLocalTextModelID ?? "qwen-0.6b", kind: .text) { value in update { $0.defaultLocalTextModelID = value } }
                    Divider()
                    localChoice("Speech model", selected: prefs.audioModelID, kind: .audio) { value in update { $0.audioModelID = value } }
                    Divider()
                    localChoice("Transcript cleanup", selected: prefs.cleanupModelID, kind: .text) { value in update { $0.cleanupModelID = value } }
                    Divider()
                    CompactRow(title: "Unload idle models") {
                        CompactMenu(value: prefs.idleUnloadSeconds == 0 ? "Immediately" : "\(prefs.idleUnloadSeconds / 60) min") {
                            Button("Immediately") { update { $0.idleUnloadSeconds = 0 } }
                            ForEach([120, 300, 900], id: \.self) { seconds in Button("\(seconds / 60) min") { update { $0.idleUnloadSeconds = seconds } } }
                        }
                    }
                }
                SettingsSection(title: "Model storage") {
                    Text(model.localModels.root.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Changing folders keeps existing downloads in their original location. Choose that folder again to reuse them.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose folder…") { chooseModelFolder() }
                        Button("Use default") { setModelFolder(model.localModels.defaultDirectory) }
                            .disabled(model.localModels.root == model.localModels.defaultDirectory)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.localModels.root.path) }
                    }.disabled(model.localModels.busy || !model.localModels.progress.isEmpty || model.dictation.active)
                }
                SettingsSection(title: "Recording") {
                    CompactRow(title: "Microphone") {
                        CompactMenu(value: DictationController.devices.first { String($0.id) == prefs.microphoneID }?.name ?? "System default") {
                            Button("System default") { update { $0.microphoneID = nil } }
                            ForEach(DictationController.devices, id: \.id) { device in Button(device.name) { update { $0.microphoneID = String(device.id) } } }
                        }
                    }
                    Divider()
                    CompactRow(title: "Speech language") {
                        CompactMenu(value: speechLanguageName(prefs.transcriptionLanguage ?? "auto")) {
                            ForEach(WorkflowPreferences.speechLanguages, id: \.self) { code in Button(speechLanguageName(code)) { update { $0.transcriptionLanguage = code } } }
                        }
                    }
                    Divider()
                    CompactRow(title: "Recording mode") {
                        CompactMenu(value: prefs.recordingMode.title) {
                            ForEach(RecordingMode.allCases, id: \.self) { mode in Button(L10n.text(mode.title)) { update { $0.recordingMode = mode } } }
                        }
                    }
                    Divider()
                    CompactRow(title: "Output") {
                        CompactMenu(value: prefs.output.title) {
                            ForEach(TranscriptOutput.allCases, id: \.self) { output in Button(L10n.text(output.title)) { update { $0.output = output } } }
                        }
                    }
                    Divider()
                    CompactRow(title: "Mute Mac audio while recording") { Toggle("Mute Mac audio while recording", isOn: workflowBool(\.muteWhileRecording)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Live transcription popup") { Toggle("Live transcription popup", isOn: Binding(get: { prefs.showDictationPopup }, set: { value in update { $0.showDictationPopup = value } })).labelsHidden() }
                    Divider()
                    CompactRow(title: "Cancel recording", detail: "Escape always cancels.") {
                        HotkeyRecorder(hotkey: Binding(get: { prefs.cancelRecordingHotkey }, set: { value in update { $0.cancelRecordingHotkey = value } }))
                    }
                    if let issue = model.hotkeyErrors[AppModel.cancelRecordingID] { Text(issue).font(.caption).foregroundStyle(.orange) }
                    if model.dictation.active {
                        Divider()
                        CompactRow(title: model.dictation.phase.rawValue.capitalized) {
                            HStack { Button("Stop") { model.dictation.requestStop() }; Button("Cancel") { model.dictation.cancel() } }
                        }
                    }
                }
                SettingsSection(title: "Window switcher") {
                    CompactRow(title: "Switch windows with ⌘Tab") { Toggle("Switch windows with ⌘Tab", isOn: preference(\.windowSwitcherEnabled)).labelsHidden() }
                    Text(L10n.text(model.windowSwitcherStatus)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Hold ⌘ and type to search. Release ⌘ to switch; Esc cancels.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                SettingsSection(title: "Permissions") {
                    CompactRow(title: "Accessibility", detail: model.accessibilityGranted ? "Allowed" : "Required for writing, paste and window switching.") {
                        Button(L10n.text(model.accessibilityGranted ? "Manage…" : "Allow…")) { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
                    }
                    Divider()
                    CompactRow(title: "Microphone", detail: DictationController.microphoneGranted ? "Allowed" : "Required for transcription.") {
                        Button(L10n.text(DictationController.microphoneGranted ? "Manage…" : "Allow…")) {
                            Task { if !DictationController.microphoneGranted { _ = await DictationController.requestMicrophone() }; DictationController.openMicrophoneSettings(); model.objectWillChange.send() }
                        }
                    }
                    Divider()
                    CompactRow(title: "Notifications") { Button("Allow…") { DesktopNotifications.requestAuthorization() } }
                }
                SettingsSection(title: "History") {
                    CompactRow(title: "Save history on this Mac") { Toggle("Save history on this Mac", isOn: preference(\.historyEnabled)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Maximum entries") { Stepper("\(model.configuration.preferences.historyLimit)", value: preference(\.historyLimit), in: 1...200).fixedSize() }
                    Divider()
                    CompactRow(title: "Retention") { Stepper("\(model.configuration.preferences.historyRetentionDays) \(L10n.text("days"))", value: preference(\.historyRetentionDays), in: 1...30).fixedSize() }
                }
                SettingsSection(title: "About") {
                    CompactRow(title: "Frog") { Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))").foregroundStyle(.secondary) }
                    Divider()
                    CompactRow(title: "Source code") { Link("GitHub ↗", destination: URL(string: "https://github.com/t1llo/frog")!) }
                    Text("Built-in models run locally. Provider rules send text to the provider you choose. No analytics.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                SettingsSection(title: "Configuration") {
                    CompactRow(title: "Import / export", detail: "JSON settings, without keys, models or history.") {
                        HStack {
                            Button("Import…") { chooseConfiguration() }.disabled(model.isProcessing || model.isTestingProvider || model.dictation.active)
                            Button("Export…") { exportConfiguration() }
                        }
                    }
                }
            }.toggleStyle(.switch).controlSize(.small).padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.onAppear { model.refreshSystemStatus() }
            .confirmationDialog("Replace configuration?", isPresented: $confirmingImport) {
                Button("Replace configuration") { if let pendingConfiguration { do { try model.importConfiguration(pendingConfiguration) } catch { model.report(error) } }; pendingConfiguration = nil }
                Button("Cancel", role: .cancel) { pendingConfiguration = nil }
            } message: { Text("The current settings are backed up. Imported history limits apply immediately. Provider keys may need to be re-entered.") }
    }
    private func speechLanguageName(_ code: String) -> String { code == "auto" ? L10n.text("Detect automatically") : L10n.locale.localizedString(forLanguageCode: code) ?? code }
    private func localChoice(_ title: String, selected: String, kind: LocalModelDescriptor.Kind, choose: @escaping (String) -> Void) -> some View {
        CompactRow(title: title) {
            CompactMenu(value: model.localModelLabel(selected)) {
                ForEach(LocalModelDescriptor.catalog.filter { $0.kind == kind && model.localModels.installed.contains($0.id) }) { item in Button(item.name) { choose(item.id) } }
                if !LocalModelDescriptor.catalog.contains(where: { $0.kind == kind && model.localModels.installed.contains($0.id) }) { Text("Download models in Models → Inside Frog") }
            }
        }
    }
    private func update(_ body: (inout WorkflowPreferences) -> Void) { var value = prefs; body(&value); do { try model.saveWorkflowPreferences(value) } catch { model.report(error) } }
    private func workflowBool(_ key: WritableKeyPath<WorkflowPreferences, Bool?>) -> Binding<Bool> { Binding(get: { prefs[keyPath: key] ?? false }, set: { value in update { $0[keyPath: key] = value } }) }
    private func preference<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> { Binding(get: { model.configuration.preferences[keyPath: key] }, set: { value in var prefs = model.configuration.preferences; prefs[keyPath: key] = value; do { try model.savePreferences(prefs) } catch { model.report(error) } }) }
    private func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Frog-configuration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportConfiguration(to: url) } catch { model.report(error) }
    }
    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = model.localModels.root
        panel.title = L10n.text("Model download folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setModelFolder(url)
    }
    private func setModelFolder(_ url: URL) {
        guard !model.dictation.active else { return }
        Task { do { try await model.localModels.changeDirectory(to: url) } catch { model.report(error) } }
    }
    private func chooseConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pendingConfiguration = try ConfigurationFile.read(from: url); confirmingImport = true } catch { model.report(error) }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text(title)).font(.system(size: 12, weight: .semibold)).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 7) { content }.padding(12).frame(maxWidth: .infinity)
                .frogTableSurface()
        }
    }
}
