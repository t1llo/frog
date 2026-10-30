import AppKit
import SwiftUI
import FrogCore

final class DictationPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "dictation", name: "Dictation", symbol: "waveform", tint: .red, category: .write,
                                 summary: "Speak instead of typing", enabledByDefault: true,
                                 permissions: [.microphone, .accessibility], recommended: true)
    func page() -> AnyView? {
        legacyPage(RulesView(fixedCategory: .audio, output: .replace) { RecordingSettingsView() })
    }
    var actions: [PluginAction] {
        [PluginAction(id: "dictation.toggle", title: "Start or stop dictation", symbol: "waveform", keywords: "record speak voice") { [model] _ in
            if model.dictation.active { model.dictation.stop(models: model.localModels); return .done("Stopped recording.") }
            guard let rule = model.configuration.rules.first(where: { $0.enabled && $0.category == .audio }) else {
                throw ActionError.failed("Add a dictation rule first.")
            }
            model.startDictation(rule)
            return .done("Recording with \(rule.name).")
        },
         PluginAction(id: "dictation.cancel", title: "Cancel dictation", symbol: "xmark", surfaces: [.agent, .shortcut]) { [model] _ in
            model.dictation.interrupt()
            return .done("Cancelled.")
        }]
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "dictation.recording", order: 10) { [model] in
            AnyView(DictationMenuRows(dictation: model.dictation, models: model.localModels))
        }]
    }
}

private struct DictationMenuRows: View {
    @ObservedObject var dictation: DictationController
    let models: LocalModels
    var body: some View {
        if dictation.active {
            if dictation.phase == .recording {
                MenuActionRow(title: "Stop recording", symbol: "stop.fill") { dictation.stop(models: models) }
            }
            MenuActionRow(title: "Cancel recording", symbol: "xmark") { dictation.interrupt() }
        }
    }
}
