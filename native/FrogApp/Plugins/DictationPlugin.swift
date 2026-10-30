import AppKit
import SwiftUI
import FrogCore

/// Speak instead of typing: a dictation rule's shortcut records, a speech model transcribes, a Writing rule may
/// clean the text up, and Frog copies or pastes it. Off, it registers no key, opens no microphone and holds no model.
final class DictationPlugin: FrogPlugin {
    static let info = PluginInfo(id: "dictation", name: "Dictation", symbol: "waveform", tint: .red, category: .write,
                                 summary: "Speak instead of typing", enabledByDefault: true,
                                 permissions: [.microphone, .accessibility], recommended: true)
    let context: PluginContext
    private var model: AppModel { context.legacy }
    private(set) var feature: DictationFeature?

    init(context: PluginContext) { self.context = context }

    func start() async {
        guard feature == nil else { return }
        if model.registersShortcuts { model.adoptDictationDefaults() }
        let settings = seededSettings()
        let escape = model.injectedDictationController == nil && model.registersShortcuts ? EscapeHotkey(manager: model.sharedHotkeys) : nil
        let controller = model.injectedDictationController ?? DictationController(cancelKey: escape)
        let feature = DictationFeature(model: model, controller: controller, settings: settings) { [weak self] in
            do { try self?.context.save($0) } catch { self?.context.report(error) }
        }
        escape?.extraKey = { [weak feature] in feature?.settings.cancelShortcut?.hotkey }
        self.feature = feature
        model.dictationFeature = feature
    }

    func stop() async {
        feature?.shutdown()
        if model.dictationFeature === feature { model.dictationFeature = nil }
        feature = nil
    }

    func settingsChanged() { feature?.apply(context.settings(DictationSettings.self)) }

    /// `[dictation]` from config.toml. Without the table, Frog writes it once from the settings it kept before.
    private func seededSettings() -> DictationSettings {
        guard model.configurationLoaded, model.settingsFile.document.value(at: [Self.info.id]) == nil else {
            return context.settings(DictationSettings.self)
        }
        let seeded = DictationSettings(legacy: model.configuration.preferences.workflowSettings)
        do { try model.settingsFile.edit { try $0.update(Self.info.id, seeded, all: true) } } catch { context.report(error) }
        return seeded
    }

    func page() -> AnyView? {
        guard let feature else { return nil }
        return AnyView(DictationPage(feature: feature, dictation: feature.controller).environmentObject(model))
    }

    var menu: [MenuContribution] {
        guard let feature else { return [] }
        return [MenuContribution(id: "dictation.recording", order: 10) {
            AnyView(DictationMenuRows(dictation: feature.controller, feature: feature))
        }]
    }

    // MARK: Actions

    var actions: [PluginAction] {
        guard let feature else { return [] }
        let rule = ActionParameter(name: "rule", help: "A dictation rule by name; the one with a shortcut by default")
        return [
            PluginAction(id: "dictation.toggle", title: "Start or stop dictation", symbol: "waveform", keywords: "record speak voice",
                         parameters: [rule]) { input in
                if feature.controller.active { return try await Self.stop(feature) }
                return try await Self.start(feature, rule: input.value("rule"))
            },
            PluginAction(id: "dictation.start", title: "Start dictation", symbol: "mic", keywords: "record speak voice",
                         parameters: [rule]) { input in
                guard !feature.controller.active else { throw ActionError.failed("Frog is already recording.") }
                return try await Self.start(feature, rule: input.value("rule"))
            },
            PluginAction(id: "dictation.stop", title: "Stop dictation", symbol: "stop.fill", keywords: "finish transcribe") { _ in
                try await Self.stop(feature)
            },
            PluginAction(id: "dictation.cancel", title: "Cancel dictation", symbol: "xmark", keywords: "discard recording") { _ in
                guard feature.controller.active else { return .done("Nothing is recording.") }
                feature.cancel()
                return .done("Cancelled.")
            },
            PluginAction(id: "dictation.status", title: "Dictation status", symbol: "waveform", surfaces: .agent) { _ in
                let controller = feature.controller
                let status = DictationStatus(phase: controller.phase.rawValue, seconds: controller.elapsed,
                                             text: controller.liveText.isEmpty ? nil : controller.liveText,
                                             rule: feature.rules.first { $0.id == controller.ruleID }?.name,
                                             microphone: feature.settings.microphone)
                let line = controller.active ? "\(controller.statusText) \(controller.elapsed / 60):\(String(format: "%02d", controller.elapsed % 60))" : "Idle."
                return ActionResult(status, text: line)
            },
            PluginAction(id: "dictation.transcribe", title: "Transcribe an audio file", symbol: "waveform.badge.magnifyingglass",
                         parameters: [ActionParameter(name: "file", required: true, help: "Path to a WAV, M4A, MP3, AIFF or CAF file"),
                                      rule,
                                      ActionParameter(name: "language", kind: .choice(WorkflowPreferences.speechLanguages),
                                                      help: "Spoken language; the rule's by default")],
                         surfaces: .agent) { input in
                let path = (try input.required("file") as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else { throw ActionError.failed("No file at \(path).") }
                let text = try await feature.transcribe(file: URL(fileURLWithPath: path), rule: try feature.rule(named: input.value("rule")),
                                                        language: input.value("language"))
                return ActionResult(["text": text], text: text)
            },
            PluginAction(id: "dictation.microphones", title: "List microphones", symbol: "mic", surfaces: .agent) { _ in
                let chosen = feature.settings.microphone
                feature.controller.refreshMicrophones()
                let list = feature.controller.microphones.map { MicrophoneChoice(id: $0.uid, name: $0.name, chosen: $0.uid == chosen) }
                let lines = ["\(chosen == nil ? "*" : " ") default  System default"]
                    + list.map { "\($0.chosen ? "*" : " ") \($0.id)  \($0.name)" }
                return ActionResult(list, text: lines.joined(separator: "\n"))
            },
            PluginAction(id: "dictation.microphone", title: "Choose a microphone", symbol: "mic.fill",
                         parameters: [ActionParameter(name: "id", required: true,
                                                      help: "A microphone's ID or name from dictation.microphones, or “default”")],
                         surfaces: .agent) { input in
                let wanted = try input.required("id")
                if wanted.lowercased() == "default" {
                    feature.selectMicrophone(nil)
                    return .done("Recording from the macOS default input.")
                }
                feature.controller.refreshMicrophones()
                let devices = feature.controller.microphones
                guard let device = devices.first(where: { $0.uid == wanted })
                        ?? devices.first(where: { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }) else {
                    throw ActionError.failed("No microphone “\(wanted)”. Run `frog run dictation.microphones` for the list.")
                }
                feature.selectMicrophone(device.uid)
                return .done("Recording from \(device.name).")
            }
        ]
    }

    private static func start(_ feature: DictationFeature, rule name: String?) async throws -> ActionResult {
        let rule = try feature.rule(named: name)
        feature.start(rule)
        // Starting ends when the microphone runs, or with the reason it could not.
        await feature.controller.waitForWork()
        guard feature.controller.phase == .recording else { throw ActionError.failed("Dictation did not start. Open Frog to see why.") }
        return .done("Recording with \(rule.name).")
    }

    private static func stop(_ feature: DictationFeature) async throws -> ActionResult {
        let controller = feature.controller
        guard controller.phase == .recording || controller.phase == .preparing else {
            guard controller.finishing else { throw ActionError.failed("Nothing is recording.") }
            await controller.waitForWork()
            return ActionResult(["text": feature.lastTranscript], text: feature.lastTranscript ?? "")
        }
        let wasRecording = controller.phase == .recording
        feature.lastTranscript = nil
        feature.stop()
        await controller.waitForWork()
        if controller.phase == .failed { throw ActionError.failed(controller.failure) }
        guard let text = feature.lastTranscript else {
            throw ActionError.failed(wasRecording ? "Nothing was transcribed." : "Stopped before the microphone started.")
        }
        return ActionResult(["text": text], text: text)
    }
}

private struct DictationStatus: Encodable {
    let phase: String
    let seconds: Int
    let text: String?
    let rule: String?
    let microphone: String?
}

private struct MicrophoneChoice: Encodable {
    let id: String
    let name: String
    let chosen: Bool
}

private struct DictationMenuRows: View {
    @ObservedObject var dictation: DictationController
    let feature: DictationFeature
    var body: some View {
        if dictation.active {
            if dictation.phase == .recording {
                MenuActionRow(title: "Stop recording", symbol: "stop.fill") { feature.stop() }
            }
            MenuActionRow(title: "Cancel recording", symbol: "xmark") { feature.cancel() }
        }
    }
}
