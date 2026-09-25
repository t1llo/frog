import SwiftUI
import FrogCore

struct TranscriptionView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Transcription", subtitle: "Speak, clean up locally, copy or paste.")
            if !model.dictation.active {
                Menu("Record") {
                    ForEach(model.configuration.rules.filter { $0.category == .audio && $0.enabled }) { rule in
                        Button(rule.name) { model.startDictation(rule) }
                    }
                }.disabled(model.isProcessing)
            }
            if !DictationController.microphoneGranted {
                FrogCard {
                    HStack {
                        Label("Microphone access required", systemImage: "mic.slash")
                        Spacer()
                        Button("Allow microphone") { Task { _ = await DictationController.requestMicrophone(); model.objectWillChange.send() } }
                        Button("Settings") { DictationController.openMicrophoneSettings() }
                    }
                }
            }
            if model.dictation.active {
                FrogCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.dictation.phase.rawValue.capitalized)
                            Spacer()
                            Button("Stop") { model.dictation.stop(models: model.localModels) }.disabled(model.dictation.phase != .recording)
                            Button("Cancel") { model.dictation.cancel() }
                        }
                        if !model.dictation.liveText.isEmpty { Text(model.dictation.liveText).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            WorkflowSettingsCard()
            SectionCaption(text: "Speech models")
            LocalModelRows(kind: .audio)
            SectionCaption(text: "Local cleanup")
            LocalModelRows(kind: .text)
            HStack {
                Button("Add dictation rule") { do { try model.ensureDictationRule() } catch { model.report(error) } }
                Text("Set its shortcut and prompt in Rules.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LocalModelRows: View {
    @EnvironmentObject private var model: AppModel
    let kind: LocalModelDescriptor.Kind?
    var body: some View {
        if !LocalModels.supported { Text("Built-in models require Apple silicon.").font(.caption).foregroundStyle(.secondary) }
        ForEach(LocalModelDescriptor.catalog.filter { kind == nil || $0.kind == kind }) { item in
            FrogCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Image(systemName: item.kind == .audio ? "waveform" : "cpu").foregroundStyle(FrogStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.system(size: 12, weight: .medium))
                            Text("\(item.size) · \(model.localModels.loaded.contains(item.id) ? "In memory" : "On-device")").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let progress = model.localModels.progress[item.id] {
                            ProgressView(value: progress).frame(width: 70)
                            Button("Cancel") { model.localModels.cancelDownload(item.id) }
                        } else if model.localModels.installed.contains(item.id) {
                            Menu("Use as…") {
                                if item.kind == .audio { Button("Default audio model") { setDefault(item, cleanup: false) } }
                                else {
                                    Button("Default text model") { setDefault(item, cleanup: false) }
                                    Button("Transcription cleanup") { setDefault(item, cleanup: true) }
                                }
                            }.fixedSize()
                            Button { Task { do { try await model.localModels.remove(item.id) } catch { model.report(error) } } } label: { Image(systemName: "trash") }
                                .disabled(model.localModels.busy || model.dictation.active).help("Delete downloaded model")
                        } else {
                            Button("Download") { model.localModels.download(item) }.disabled(!LocalModels.supported)
                        }
                    }
                    if let error = model.localModels.errors[item.id] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
        }
    }
    private func setDefault(_ item: LocalModelDescriptor, cleanup: Bool) {
        var value = model.configuration.preferences.workflowSettings
        if item.kind == .audio { value.audioModelID = item.id }
        else if cleanup { value.cleanupModelID = item.id }
        else { value.defaultLocalTextModelID = item.id }
        do { try model.saveWorkflowPreferences(value) } catch { model.report(error) }
    }
}

struct WorkflowSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        FrogCard {
            VStack(spacing: 12) {
                Picker("Speech model", selection: binding(\.audioModelID)) {
                    ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .audio }) { Text($0.name).tag($0.id) }
                }
                Picker("Cleanup model", selection: binding(\.cleanupModelID)) {
                    ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .text }) { Text($0.name).tag($0.id) }
                }
                Picker("Recording", selection: binding(\.recordingMode)) {
                    ForEach(RecordingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Output", selection: binding(\.output)) {
                    ForEach(TranscriptOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Microphone", selection: binding(\.microphoneID)) {
                    Text("System default").tag(String?.none)
                    ForEach(DictationController.devices, id: \.id) { Text($0.name).tag(String($0.id) as String?) }
                }
                Toggle("Show live dictation popup", isOn: binding(\.showDictationPopup)).toggleStyle(.switch).controlSize(.small)
            }.font(.system(size: 12))
        }
    }
    private func binding<T>(_ key: WritableKeyPath<WorkflowPreferences, T>) -> Binding<T> {
        Binding(get: { model.configuration.preferences.workflowSettings[keyPath: key] }, set: { value in
            var settings = model.configuration.preferences.workflowSettings; settings[keyPath: key] = value
            do { try model.saveWorkflowPreferences(settings) } catch { model.report(error) }
        })
    }
}
