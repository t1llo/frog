import SwiftUI
import FrogCore

/// The Dictation page's recording settings, below its rules.
struct RecordingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }

    var body: some View {
        SettingsSection(title: "Recording") {
            MicrophoneRow(dictation: model.dictation, selection: prefs.microphoneID) { id in update { $0.microphoneID = id } }
            CompactRow(title: "Mute Mac audio while recording") { Toggle("Mute Mac audio while recording", isOn: Binding(get: { prefs.muteWhileRecording ?? false }, set: { value in update { $0.muteWhileRecording = value } })).labelsHidden() }
            CompactRow(title: "Cancel recording", detail: "Escape always cancels.") {
                HotkeyRecorder(hotkey: Binding(get: { prefs.cancelRecordingHotkey }, set: { value in update { $0.cancelRecordingHotkey = value } }))
            }
            if let issue = model.hotkeyErrors[AppModel.cancelRecordingID] { Text(issue).font(FrogType.caption).foregroundStyle(FrogStyle.warning) }
        }.toggleStyle(.switch).controlSize(.small)
    }

    private func update(_ body: (inout WorkflowPreferences) -> Void) { var value = prefs; body(&value); do { try model.saveWorkflowPreferences(value) } catch { model.report(error) } }
}

/// The Microphone row of the Recording section. Reading the microphones asks Core Audio about
/// every device, and the page draws again for every change of the app, once a second while
/// dictating. So they are read when the row appears and when a device is connected or removed.
struct MicrophoneRow: View {
    @ObservedObject var dictation: DictationController
    let selection: String?
    var deviceChanges: () -> AsyncStream<Void> = AudioDeviceChanges.stream
    let choose: (String?) -> Void
    var body: some View {
        CompactRow(title: "Microphone") {
            FrogDropdown(selected: selection, options: [nil] + dictation.microphones.map { String($0.id) },
                         searchPrompt: dictation.microphones.count > 6 ? "Find a microphone" : nil,
                         title: { id in id.flatMap { id in dictation.microphones.first { String($0.id) == id }?.name } ?? "System default" },
                         symbol: { $0 == nil ? "mic" : "mic.fill" }, choose: choose)
        }
        // Read before the first frame, so the row does not show the default first.
        .onAppear { dictation.refreshMicrophones() }
        .task { for await _ in deviceChanges() { dictation.refreshMicrophones() } }
    }
}
