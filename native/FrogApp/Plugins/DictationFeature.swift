import AppKit
import AVFoundation
import Combine
import FrogCore

/// `[dictation]` in config.toml. A recording's shortcut, mode, model, language, cleanup and output belong to its
/// rule; these are the settings every recording shares.
struct DictationSettings: ConfigSection {
    /// A `MicrophoneDevice.uid`; nil records from the macOS default input.
    var microphone: String?
    var muteAudio = false
    /// Cancels a recording besides Escape. Registered only while Frog records.
    var cancelShortcut: Shortcut?

    static let comments = [
        "": "Dictation: speak, and Frog types it. Each dictation rule keeps its own shortcut and model.",
        "microphone": "Input device ID; leave out for the macOS default",
        "mute-audio": "Mutes the Mac's sound while recording",
        "cancel-shortcut": "Cancels a recording, besides Escape",
    ]

    init() {}

    /// The settings as Frog kept them before config.toml.
    init(legacy: WorkflowPreferences) {
        microphone = legacy.microphoneID
        muteAudio = legacy.muteWhileRecording ?? false
        cancelShortcut = legacy.cancelRecordingHotkey.flatMap { try? Shortcut($0) }
    }
}

/// Dictation while its plugin is on: the recording controller and everything that connects it to the rest of
/// Frog. The plugin creates it in `start()` and drops it in `stop()`; nothing of it exists while Dictation is off.
@MainActor
final class DictationFeature: ObservableObject {
    let controller: DictationController
    private unowned let model: AppModel
    @Published private(set) var settings: DictationSettings
    private let save: (DictationSettings) -> Void
    /// The History generation a recording started in; a recording that outlives a cleared History saves nothing.
    private var historyEpoch: UUID?
    /// Interrupted recordings whose History entry waits for the rest of their transcript.
    private var recoveries: [UUID: UUID] = [:]
    private var observations = Set<AnyCancellable>()
    /// What the last recording delivered, for `dictation.stop` and agents.
    var lastTranscript: String?

    init(model: AppModel, controller: DictationController, settings: DictationSettings,
         save: @escaping (DictationSettings) -> Void) {
        self.model = model; self.controller = controller; self.settings = settings; self.save = save
        wire()
    }

    /// Ends whatever runs and lets go of the popup. After it returns nothing records, listens or holds a model.
    func shutdown() {
        controller.cancel()
        controller.cancelHistoryRecovery()
        controller.releasePanel()
        recoveries = [:]
        observations = []
    }

    /// `[dictation]` as config.toml says now, also after an edit in an editor.
    func apply(_ settings: DictationSettings) {
        self.settings = settings
        do { try syncCancelShortcut(settings.cancelShortcut?.hotkey) } catch { model.report(error) }
    }

    /// The cancel shortcut lives in `[dictation]`; the preferences keep a copy, since Frog's shortcut conflict
    /// checks, the shortcut reference and the window switcher read it there. A conflicting shortcut is refused.
    func setCancelShortcut(_ hotkey: Hotkey?) throws {
        let shortcut = try hotkey.map { try Shortcut($0) }
        try syncCancelShortcut(hotkey)
        update { $0.cancelShortcut = shortcut }
    }

    private func syncCancelShortcut(_ hotkey: Hotkey?) throws {
        guard model.configurationLoaded else { return }
        var preferences = model.configuration.preferences.workflowSettings
        guard preferences.cancelRecordingHotkey != hotkey else { return }
        preferences.cancelRecordingHotkey = hotkey
        try model.saveWorkflowPreferences(preferences)
    }

    /// The model History names for a recording made with `rule`.
    private func modelName(_ rule: Rule) -> String {
        rule.action?.audioModelID ?? model.configuration.preferences.workflowSettings.audioModelID
    }

    // MARK: Rules

    /// Dictation rules that are on, in the order the page lists them.
    var rules: [Rule] { model.configuration.rules.filter { $0.enabled && $0.category == .audio } }

    /// The rule a person dictates with every day: the first with a shortcut, else the first.
    var defaultRule: Rule? { rules.first { $0.hotkey != nil } ?? rules.first }

    /// A rule by name, or the default rule for nil.
    func rule(named name: String?) throws -> Rule {
        if let name, !name.isEmpty {
            guard let rule = rules.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw ActionError.failed("No dictation rule named “\(name)”. Rules: \(rules.map(\.name).joined(separator: ", ")).")
            }
            return rule
        }
        guard let rule = defaultRule else { throw ActionError.failed("Add a dictation rule first.") }
        return rule
    }

    /// The Writing rule that cleans up a recording made with `rule`; the rule itself for one with its own
    /// cleanup instructions; nil when the transcript goes out as recognised.
    func cleanupRule(for rule: Rule) -> Rule? {
        if let id = rule.action?.cleanupRuleID, let writing = model.configuration.rules.first(where: { $0.id == id && $0.category == .text }) {
            return writing
        }
        return rule.action?.cleanup == true ? rule : nil
    }

    /// A dictation rule whose Writing rule was deleted no longer names it, and says so once.
    private func forgetDeletedCleanup(_ rules: [Rule]) {
        let writing = Set(rules.filter { $0.category == .text }.map(\.id))
        for var rule in rules where rule.category == .audio {
            guard let id = rule.action?.cleanupRuleID, !writing.contains(id) else { continue }
            rule.action?.cleanupRuleID = nil
            do {
                try model.saveRule(rule)
                model.report(FrogError.message("\(rule.name) no longer cleans up its transcript: its Writing rule was deleted."))
            } catch { model.report(error) }
        }
    }

    // MARK: Recording

    func start(_ rule: Rule, shortcutHeld: Bool = false, handoff: DictationHandoff? = nil) {
        guard !model.isProcessing else { model.report(FrogError.message("Wait for the current request to finish.")); return }
        guard !controller.active else { return }
        historyEpoch = model.configuration.preferences.historyEnabled ? model.historyEpoch : nil
        var preferences = model.configuration.preferences.workflowSettings
        preferences.microphoneID = settings.microphone
        preferences.muteWhileRecording = settings.muteAudio
        controller.start(rule: rule, preferences: preferences, models: model.localModels,
                         shortcutHeld: shortcutHeld, handoff: handoff)
    }

    func stop() { controller.requestStop() }

    func cancel() { controller.interrupt() }

    /// A press or release of a dictation rule's shortcut.
    func handleShortcut(_ rule: Rule, pressed: Bool) {
        let mode = rule.action?.recordingMode ?? model.configuration.preferences.workflowSettings.recordingMode
        switch RecordingShortcut.action(mode: mode, pressed: pressed, target: rule.id, active: controller.ruleID,
                                        finishing: controller.finishing) {
        case .start: start(rule, shortcutHeld: true)
        case .stop: controller.stop(models: model.localModels)
        case .busy:
            // A recording starts only after the last one was delivered. Without the popup, the processing
            // indicator says why the press did nothing.
            if !controller.showPressWhileFinishing() {
                model.note(controller.phase == .correcting ? "Still cleaning up…" : "Still transcribing…")
            }
        case nil: break
        }
    }

    /// `frog://dictate` from another app: records with the person's usual rule, or the one the link names, and
    /// sends the transcript back to the app. The same link stops the recording it started.
    func open(_ request: DictationHandoff) {
        let current = controller.handoff.flatMap { $0.sameCaller(request) ? $0 : nil }
        switch request.command {
        case .cancel:
            if current != nil { controller.interrupt() }
            return
        case .stop:
            if current != nil { controller.requestStop() }
            return
        case .toggle:
            if current != nil { controller.requestStop(); return }
        }
        func refuse(_ message: String) { NSWorkspace.shared.open(request.reply(.failed(message))) }
        guard NSWorkspace.shared.urlForApplication(toOpen: request.reply) != nil else {
            model.report(FrogError.message("No app opens \(request.caller)'s reply link, so Frog did not record.")); return
        }
        guard !controller.active, !model.isProcessing else { return refuse("Frog is busy with another recording.") }
        let rule: Rule
        do { rule = try self.rule(named: request.rule) } catch { return refuse(error.localizedDescription) }
        start(rule, handoff: request)
        // A rule that cannot start says why in Frog; the app learns that nothing is recording.
        if controller.handoff == nil { refuse("Frog could not start \(rule.name). Open Frog to see why.") }
    }

    // MARK: Microphones

    func selectMicrophone(_ id: String?) {
        if controller.phase == .recording { controller.selectMicrophone(id) } else { rememberMicrophone(id) }
    }

    private func rememberMicrophone(_ id: String?) { update { $0.microphone = id } }

    /// Changes `[dictation]` and writes it to config.toml.
    func update(_ change: (inout DictationSettings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }
        settings = changed
        save(changed)
    }

    // MARK: Files

    /// The transcript of an audio file, as a recording with `rule` would deliver it, cleanup included. A downloaded
    /// model reads the file one 30-second window at a time, so a long file never sits in memory whole.
    func transcribe(file: URL, rule: Rule, language: String? = nil) async throws -> String {
        let reader = try await Task.detached(priority: .userInitiated) { try AudioFileSamples(url: file) }.value
        guard reader.seconds <= Self.longestFile else { throw ActionError.failed("Files up to four hours long can be transcribed.") }
        var rule = rule
        if let language { rule.action?.transcriptionLanguage = language }
        let raw: String
        if rule.action?.audioProviderID != nil {
            // A provider takes the recording in one request.
            guard reader.seconds <= Self.longestUpload else {
                throw ActionError.failed("A provider takes files up to 30 minutes. Choose a downloaded speech model for longer ones.")
            }
            let samples = try await Task.detached(priority: .userInitiated) { try reader.read(.max) }.value
            guard samples.count >= 3200 else { throw ActionError.failed("The file holds less than a fifth of a second of sound.") }
            raw = try await model.transcribeWithProvider(samples, rule: rule)
        } else {
            guard let modelID = rule.action?.audioModelID else { throw ActionError.failed("Choose a speech model for \(rule.name).") }
            guard model.localModels.installed.contains(modelID) else { throw ActionError.failed("Download \(modelID) in Models first.") }
            let models = model.localModels, language = rule.action?.transcriptionLanguage
            let hold = models.holdResidency()
            defer { models.releaseResidency(hold) }
            var pieces: [String] = [], pending: [Float] = [], total = 0
            // The windows recording reads in, so a file and a recording of the same speech read alike.
            while true {
                let wanted = DictationTranscript.samplesCompletingWindow - pending.count
                let more = try await Task.detached(priority: .userInitiated) { try reader.read(wanted) }.value
                pending += more; total += more.count
                guard pending.count >= DictationTranscript.samplesCompletingWindow else { break }
                pieces.append(try await models.transcribe(Array(pending[..<DictationTranscript.window]), modelID: modelID,
                                                          language: language, waiting: true))
                pending.removeFirst(DictationTranscript.window)
            }
            guard total >= 3200 else { throw ActionError.failed("The file holds less than a fifth of a second of sound.") }
            for pass in DictationTranscript.passes(endingSamples: pending.count) {
                pieces.append(try await models.transcribe(Array(pending[pass]), modelID: modelID, language: language, waiting: true))
            }
            raw = DictationTranscript.join(pieces)
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionError.failed("No speech detected.") }
        guard let cleanup = cleanupRule(for: rule) else { return raw }
        return try await model.complete(raw, with: cleanup)
    }

    static let longestFile: TimeInterval = 4 * 3600
    static let longestUpload: TimeInterval = 30 * 60

    /// All of a file's 16 kHz mono samples; for short files and tests.
    nonisolated static func samples(from url: URL) throws -> [Float] { try AudioFileSamples(url: url).read(.max) }

    // MARK: Wiring

    private func wire() {
        // Pages read only whether Frog dictates and which History entries it recovers. The timer, the preview
        // text and the microphones are drawn by views that observe the controller, so a tick of the recording
        // does not redraw every page.
        controller.$phase.removeDuplicates().dropFirst().sink { [weak self] _ in self?.model.objectWillChange.send() }.store(in: &observations)
        controller.$recoveringHistoryIDs.removeDuplicates().dropFirst().sink { [weak self] _ in self?.model.objectWillChange.send() }.store(in: &observations)
        // An entry History dropped, by its limit or by hand, needs no more recognition.
        model.$history.sink { [weak self] entries in
            guard let self, !self.recoveries.isEmpty else { return }
            let ids = Set(entries.map(\.id))
            for id in Array(self.recoveries.keys) where !ids.contains(id) {
                self.recoveries[id] = nil; self.controller.cancelHistoryRecovery(id: id)
            }
        }.store(in: &observations)
        // After the change is stored: @Published sends before it sets the new value.
        model.$configuration.map(\.rules).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.forgetDeletedCleanup($0) }.store(in: &observations)
        controller.onError = { [weak self] in self?.model.report($0) }
        controller.onHandoff = { handoff, outcome in NSWorkspace.shared.open(handoff.reply(outcome)) }
        controller.onCopy = { [weak self] in self?.model.clipboardHistoryStore.recordCopiedText($0) }
        controller.onMicrophoneChange = { [weak self] in self?.rememberMicrophone($0) }
        controller.externalTranscription = { [weak self] audio, rule in
            guard let self else { throw CancellationError() }
            return try await self.model.transcribeWithProvider(audio, rule: rule)
        }
        controller.cleanupRule = { [weak self] in self?.cleanupRule(for: $0) }
        controller.cleanup = { [weak self] text, rule in
            guard let self else { throw CancellationError() }
            return try await self.model.complete(text, with: rule)
        }
        controller.localCleanupModel = { [weak self] rule in
            guard let self else { throw CancellationError() }
            let provider = try self.model.resolved(rule)
            return provider.id == AppModel.localProviderID ? provider.model : nil
        }
        controller.onSuccessfulDelivery = { [weak self] seconds, text in
            self?.model.statistics.recordDictation(recordingSeconds: seconds, text: text, rule: .dictation)
        }
        controller.onTranscript = { [weak self] id, rule, original, result in
            guard let self else { return }
            self.lastTranscript = result
            guard self.model.configuration.preferences.historyEnabled, self.historyEpoch == self.model.historyEpoch else { return }
            var entry = HistoryEntry(id: id, originalText: original, processedText: result, ruleName: rule.name,
                                     providerName: "Transcription", model: self.modelName(rule))
            entry.category = .audio
            do { _ = try self.model.appendHistory(entry) } catch { self.model.report(error) }
        }
        controller.onInterruption = { [weak self] in self?.saveInterruption($0) ?? false }
        controller.onHistoryRecovered = { [weak self] in self?.finishRecovery(id: $0, result: $1) }
    }

    /// Saves what an interrupted recording said so far. True when History waits for the rest of its transcript.
    private func saveInterruption(_ interruption: DictationInterruption) -> Bool {
        guard model.configuration.preferences.historyEnabled, historyEpoch == model.historyEpoch else { return false }
        do {
            if interruption.transcriptPublished {
                // Delivery may be interrupted after the completed result was already saved.
                if var entry = model.history.first(where: { $0.id == interruption.id }) {
                    entry.interruption = interruption.reason; entry.transcriptState = .complete
                    try model.updateHistory(entry)
                }
                return false
            }
            var entry = HistoryEntry(id: interruption.id, originalText: interruption.text, processedText: interruption.text,
                                     ruleName: interruption.rule.name, providerName: "Transcription",
                                     model: modelName(interruption.rule))
            entry.category = .audio; entry.interruption = interruption.reason; entry.transcriptState = .partial
            recoveries[entry.id] = model.historyEpoch
            guard try model.appendHistory(entry) else { recoveries[entry.id] = nil; return false }
            return recoveries[entry.id] != nil
        } catch { recoveries[interruption.id] = nil; model.report(error); return false }
    }

    private func finishRecovery(id: UUID, result: Result<String, Error>) {
        guard recoveries.removeValue(forKey: id) == model.historyEpoch,
              model.configuration.preferences.historyEnabled, var entry = model.history.first(where: { $0.id == id }) else { return }
        switch result {
        case .success(let text):
            entry.originalText = text; entry.processedText = text; entry.transcriptState = .complete
        case .failure(let error):
            entry.transcriptState = .failed
            model.report(FrogError.message("Interrupted recording transcription failed. \(error.localizedDescription)"))
        }
        do { try model.updateHistory(entry) } catch { model.report(error) }
    }
}

/// 16 kHz mono samples of any file Core Audio reads (WAV, AIFF, CAF, M4A, MP3), converted a piece at a time.
/// One reader is used by one task at a time.
final class AudioFileSamples: @unchecked Sendable {
    let seconds: TimeInterval
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let name: String
    private var leftover: [Float] = []
    private var inputEnded = false
    private var finished = false

    init(url: URL) throws {
        name = url.lastPathComponent
        do { file = try AVAudioFile(forReading: url) }
        catch { throw ActionError.failed("Frog cannot read \(url.lastPathComponent) as audio.") }
        seconds = Double(file.length) / file.processingFormat.sampleRate
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768) else {
            throw ActionError.failed("Frog cannot convert \(url.lastPathComponent) for transcription.")
        }
        self.converter = converter; self.input = input; self.output = output
    }

    /// Up to `count` more samples; fewer only at the end of the file, none after it.
    func read(_ count: Int) throws -> [Float] {
        var samples = leftover
        leftover = []
        if count != .max { samples.reserveCapacity(count) }
        while samples.count < count, !finished {
            output.frameLength = 0
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { [self] _, state in
                if inputEnded { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input)
                    if input.frameLength == 0 { inputEnded = true; state.pointee = .endOfStream; return nil }
                } catch { inputEnded = true; state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return input
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .error { throw ActionError.failed("Converting \(name) failed: \(failure?.localizedDescription ?? "unknown error").") }
            if status == .endOfStream || (status == .inputRanDry && inputEnded) { finished = true }
        }
        if samples.count > count { leftover = Array(samples[count...]); samples.removeLast(samples.count - count) }
        return samples
    }
}
