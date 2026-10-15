import SwiftUI
import FrogCore

struct CommandBarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Command bar", subtitle: "Applications, windows, files and Frog tools, one shortcut away.")
            SettingsSection(title: "Shortcut") {
                CompactRow(title: "Open command bar") {
                    HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey }, set: { key in
                        do { try model.updateToolkit { $0.commandBarHotkey = key } } catch { model.report(error) }
                    }), showsClearButton: false)
                    Button("Open") { model.showCommandBar() }
                }
                if let issue = model.hotkeyErrors[AppModel.commandBarID] { Text(issue).font(.caption).foregroundStyle(FrogStyle.warning) }
            }
            Text("Type an application, window or filename. You can also calculate 25% * 200 or convert 5 mi to km. Arrow keys select a result; Return opens it and Escape closes the panel.")
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
            CommandBarSetupView()
        }
    }
}
