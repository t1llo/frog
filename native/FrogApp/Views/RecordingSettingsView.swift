import SwiftUI
import FrogCore

/// The Dictation page's recording settings, below its rules.
struct RecordingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }

    var body: some View {
        SettingsSection(title: "Recording") {
            MicrophoneRow(dictation: model.dictation, selection: prefs.microphoneID) { id in update { $0.microphoneID = id } }
            Divider()
            CompactRow(title: "Mute Mac audio while recording") { Toggle("Mute Mac audio while recording", isOn: Binding(get: { prefs.muteWhileRecording ?? false }, set: { value in update { $0.muteWhileRecording = value } })).labelsHidden() }
            Divider()
            CompactRow(title: "Cancel recording", detail: "Escape always cancels.") {
                HotkeyRecorder(hotkey: Binding(get: { prefs.cancelRecordingHotkey }, set: { value in update { $0.cancelRecordingHotkey = value } }))
            }
            if let issue = model.hotkeyErrors[AppModel.cancelRecordingID] { Text(issue).font(.caption).foregroundStyle(FrogStyle.warning) }
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
            CompactMenu(value: dictation.microphones.first { String($0.id) == selection }?.name ?? "System default") {
                Button { choose(nil) } label: { Label("System default", systemImage: selection == nil ? "checkmark" : "mic") }
                    .accessibilityAddTraits(selection == nil ? .isSelected : [])
                ForEach(dictation.microphones, id: \.id) { device in
                    Button { choose(String(device.id)) } label: { Label(device.name, systemImage: selection == String(device.id) ? "checkmark" : "mic") }
                        .accessibilityAddTraits(selection == String(device.id) ? .isSelected : [])
                }
            }
        }
        // Read before the first frame, so the row does not show the default first.
        .onAppear { dictation.refreshMicrophones() }
        .task { for await _ in deviceChanges() { dictation.refreshMicrophones() } }
    }
}
