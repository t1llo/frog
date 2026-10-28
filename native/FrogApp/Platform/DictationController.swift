import AppKit
import AVFoundation
import ApplicationServices
import QuartzCore
import SwiftUI
import FrogCore

@MainActor
final class DictationController: ObservableObject {
    /// `failed` keeps a recording whose final transcription can be repeated until it is retried or discarded.
    enum Phase: String { case idle, preparing, recording, transcribing, correcting, failed }
    @Published private(set) var phase: Phase = .idle { didSet { resizePanel() } }
    @Published private(set) var liveText = "" { didSet { resizePanel() } }
    @Published private(set) var failure = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var noMicrophoneInput = false
    /// False while the opened microphone has not delivered its first buffer.
    @Published private(set) var microphoneDelivering = false
    @Published private(set) var selectedMicrophoneID: String?
    @Published private(set) var microphones: [MicrophoneDevice] = []
    @Published private(set) var recoveringHistoryIDs = Set<UUID>()
    let microphoneMeter = MicrophoneMeter()
    @Published private(set) var hint = ""
    @Published private(set) var preparationMessage = "Preparing…"
    /// A shortcut press came while this recording was still being finished, and started nothing.
    @Published private(set) var pressedWhileFinishing = false
    private(set) var ruleID: UUID?
    private var recorder: (any DictationRecording)?
    private let makeRecorder: () -> any DictationRecording
    private let authorize: () async -> Bool
    private let copy: (String) -> Void
    private let paste: () async throws -> Void
    private let now: () -> ContinuousClock.Instant
    private var recordingStarted: ContinuousClock.Instant?
    private var recordingSeconds = 0.0
    var onCopy: ((String) -> Void)?
    private let monitorKeys: Bool
    private let presentsPopup: Bool
    private let previewInterval: Duration
    private let inputDevices: () -> [MicrophoneDevice]
    private var lastInputElapsed = 0
    private var lastInputRevision: UInt64 = 0
    private let outputMute: any OutputMuting
    private let cancelKey: (any DictationCancelKey)?
    private var muteFailureReported = false
    private var inputLossReported = false
    private var work: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var previewInference: Task<Void, Error>?
    /// What the preview in flight reads. Its text serves Stop only when it completes a window or
    /// when nothing was recorded after it.
    private var previewSnapshot: (sampleCount: Int, completesWindow: Bool)?
    private var finalTranscription: Task<String, Error>?
    private var historyRecovery: [UUID: (work: Task<Void, Never>, recognition: Task<String, Error>)] = [:]
    private var ticker: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var panel: NSPanel?
    private var token: UUID?
    private var samples = AudioSamples()
    private var previewPrefix = ""
    private var previewDraft = ""
    private var transcript = DictationTranscript()
    private var transcriptPublished = false
    private var activeRule: Rule?
    private var preferences = WorkflowPreferences()
    private weak var models: LocalModels?
    private var residencyHold: UUID?
    var onFinish: ((Rule, String, String, String) -> Void)?
    /// Raw transcript and frozen microphone-session duration, only after successful delivery.
    var onSuccessfulDelivery: ((_ recordingSeconds: Double, _ text: String) -> Void)?
    var onTranscript: ((UUID, Rule, String, String) -> Void)?
    var onInterruption: ((DictationInterruption) -> Bool)?
    var onHistoryRecovered: ((UUID, Result<String, Error>) -> Void)?
    var onError: ((Error) -> Void)?
    var onMicrophoneChange: ((String?) -> Void)?
    var cleanup: ((String, Rule) async throws -> String)?
    var localCleanupModel: ((Rule) throws -> String?)?
    var externalTranscription: (([Float], Rule) async throws -> String)?
    var active: Bool { phase != .idle }
    /// Transcribing or cleaning up: a new recording cannot start before delivery.
    var finishing: Bool { phase == .transcribing || phase == .correcting }
    /// The popup's one-line account of the session.
    var statusText: String {
        switch phase {
        case .preparing: preparationMessage
        // The capture session starts after the microphone opens; words spoken before it runs are lost.
        case .recording: microphoneDelivering ? "Listening…" : "Starting microphone…"
        case .transcribing: pressedWhileFinishing ? "Still transcribing…" : "Transcribing…"
        case .correcting: pressedWhileFinishing ? "Still cleaning up transcript…" : "Cleaning up transcript…"
        case .failed: "Transcription failed"
        case .idle: "Dictation"
        }
    }

    init(makeRecorder: @escaping @MainActor () -> any DictationRecording = { MicrophoneRecording() },
         authorize: @escaping @MainActor () async -> Bool = { DictationController.microphoneGranted ? true : await DictationController.requestMicrophone() },
         copy: @escaping (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) },
         monitorKeys: Bool = true, previewInterval: Duration = .seconds(2),
          inputDevices: @escaping @MainActor () -> [MicrophoneDevice] = { DictationController.devices },
          paste: @escaping @MainActor () async throws -> Void = { try await DictationTarget.pasteIntoFocusedField() },
          now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, presentsPopup: Bool = true,
          outputMute: any OutputMuting = RecordingMute(), cancelKey: (any DictationCancelKey)? = nil) {
        self.makeRecorder = makeRecorder; self.authorize = authorize; self.copy = copy; self.monitorKeys = monitorKeys
        self.presentsPopup = presentsPopup; self.outputMute = outputMute
        self.cancelKey = cancelKey ?? (monitorKeys ? EscapeHotkey() : nil)
        self.previewInterval = previewInterval
        self.inputDevices = inputDevices
        self.paste = paste; self.now = now
    }

    func waitForWork() async { await work?.value }
    func waitForHistoryRecovery() async {
        for task in Array(historyRecovery.values) { await task.work.value }
    }

    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var devices: [MicrophoneDevice] { MicrophoneDevice.connected }
    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    /// `shortcutHeld` is true when the rule's own shortcut started the recording and is still down.
    /// Only then does releasing it end a hold-to-record session.
    func start(rule: Rule, preferences: WorkflowPreferences, models: LocalModels, shortcutHeld: Bool = false) {
        guard !active else { return }
        guard let modelID = rule.action?.audioModelID else { onError?(FrogError.message("Choose a speech model in this audio rule. Add one in Models first.")); return }
        let external = rule.action?.audioProviderID != nil
        guard external || models.installed.contains(modelID) else { onError?(FrogError.message("Download this speech model in Models first.")); return }
        let token = UUID(); self.token = token
        self.preferences = preferences; self.models = models; activeRule = rule; ruleID = rule.id
        residencyHold = models.holdResidency()
        self.preferences.showDictationPopup = rule.action?.showRecordingPopup ?? true
        self.preferences.transcriptionLanguage = rule.action?.transcriptionLanguage
        samples = AudioSamples(); liveText = ""; elapsed = 0
        recordingStarted = nil; recordingSeconds = 0
        noMicrophoneInput = false; lastInputElapsed = 0; lastInputRevision = 0; inputLossReported = false
        selectedMicrophoneID = preferences.microphoneID; refreshMicrophones()
        microphoneMeter.reset()
        previewPrefix = ""; previewDraft = ""
        transcript = DictationTranscript(); transcriptPublished = false
        phase = .preparing; pressedWhileFinishing = false
        preparationMessage = "Checking microphone access…"
        let shortcut = rule.hotkey.map(HotkeyManager.display) ?? "Stop button"
        // A hold recording that its key did not start ends when the key is pressed and released.
        let holding = shortcutHeld && (rule.action?.recordingMode ?? preferences.recordingMode) == .hold
        let recordingHint = rule.hotkey == nil ? "Stop to finish · Esc to cancel" : holding ? "Release \(shortcut) to stop · Esc to cancel" : "\(shortcut) to stop · Esc to cancel"
        hint = "Esc to cancel"
        if self.preferences.showDictationPopup { showPanel() }
        installEscape()
        work = Task { [weak self] in
            guard let self else { return }
            let granted = await self.authorize()
            guard self.token == token, !Task.isCancelled else { return }
            guard granted else {
                self.fail(FrogError.message("Allow Microphone in Settings to record dictation."), token: token); return
            }
            do {
                if !external {
                    self.preparationMessage = "Loading speech model…"
                    try await models.prepare(modelID)
                }
                try Task.checkCancellation()
                guard self.token == token else { return }
                if rule.action?.cleanup == true {
                    let cleanupID: String?
                    if let resolve = self.localCleanupModel { cleanupID = try resolve(rule) }
                    else { cleanupID = rule.action?.localTextModelID }
                    if let cleanupID {
                        self.preparationMessage = "Loading cleanup model…"
                        try await models.prepare(cleanupID)
                    }
                }
                try Task.checkCancellation()
                guard self.token == token else { return }
                self.preparationMessage = "Starting microphone…"
                if preferences.muteWhileRecording == true {
                    do { try self.outputMute.begin(); self.muteFailureReported = false }
                    catch {
                        // Sound that keeps playing is no reason to refuse the recording. Say why once,
                        // not before every recording on an output that has no mute control.
                        if !self.muteFailureReported {
                            self.muteFailureReported = true
                            self.onError?(FrogError.message("Recording without muting the Mac. " + error.localizedDescription))
                        }
                    }
                }
                do { try self.beginRecording(microphoneID: self.preferences.microphoneID) }
                catch {
                    guard self.preferences.microphoneID != nil else { throw error }
                    // A disconnected preferred input must not prevent starting with
                    // macOS's default. Keep the saved preference for its next connection.
                    try self.beginRecording(microphoneID: nil)
                    self.selectedMicrophoneID = nil
                }
                let recordingStarted = self.now()
                self.recordingStarted = recordingStarted
                self.phase = .recording
                self.hint = recordingHint
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.token == token else { return }
                        self.refreshRecordingFeedback(elapsed: Int(recordingStarted.duration(to: self.now()).components.seconds))
                        if self.elapsed >= 600 { self.stop(models: models); return }
                    }
                }
                self.preview = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: self?.previewDelay ?? .seconds(2))
                            guard let self, self.token == token, self.phase == .recording else { return }
                            guard !external else { continue }
                            try await self.refreshPreview(includePartial: self.preferences.showDictationPopup)
                        } catch { if Task.isCancelled { return } }
                    }
                }
            } catch { self.fail(error, token: token) }
        }
    }

    func refreshRecordingFeedback(elapsed: Int) {
        if self.elapsed != elapsed { self.elapsed = elapsed }
        let level = samples.inputLevel
        microphoneMeter.append(level)
        let revision = samples.inputRevision
        if revision != lastInputRevision {
            lastInputElapsed = elapsed; lastInputRevision = revision
            if !microphoneDelivering { microphoneDelivering = true }
        }
        let missing = phase == .recording && elapsed - lastInputElapsed >= 2
        if noMicrophoneInput != missing { noMicrophoneInput = missing }
        // A running capture delivers buffers even in silence. An input that delivered and then
        // stopped was unplugged, stopped by macOS or replaced as the default input.
        if missing, microphoneDelivering { replaceLostInput() }
    }

    /// Goes on with macOS's default input without saving it as the choice, so the saved microphone
    /// is used again once it is back. The warning stays until the new input delivers.
    private func replaceLostInput() {
        recorder?.stop(); recorder = nil
        do {
            try beginRecording(microphoneID: nil)
            selectedMicrophoneID = nil; refreshMicrophones()
            // The popup shows the warning and the input; without it, say once what happened.
            if panel?.isVisible != true, !inputLossReported {
                inputLossReported = true
                onError?(FrogError.message("The microphone stopped delivering sound. Recording continues with the system default input."))
            }
        } catch {
            requestStop()
            onError?(FrogError.message("No microphone could be opened, so recording stopped. What was recorded is being transcribed."))
        }
    }

    func refreshMicrophones() {
        let devices = inputDevices()
        if microphones != devices { microphones = devices }
    }

    func selectMicrophone(_ id: String?) {
        guard phase == .recording else { return }
        if id == selectedMicrophoneID, !noMicrophoneInput {
            rememberMicrophone(id)
            return
        }
        let previous = selectedMicrophoneID
        recorder?.stop(); recorder = nil
        do {
            try beginRecording(microphoneID: id)
            selectedMicrophoneID = id
            noMicrophoneInput = false; lastInputElapsed = elapsed; microphoneMeter.reset()
            rememberMicrophone(id)
        } catch {
            var issue = error
            if (try? beginRecording(microphoneID: previous)) == nil {
                // The input that was recording is often the one that vanished. What was said so far
                // must survive that: go on with macOS's default without saving it as the choice.
                if previous != nil, (try? beginRecording(microphoneID: nil)) != nil {
                    selectedMicrophoneID = nil
                    noMicrophoneInput = false; lastInputElapsed = elapsed; microphoneMeter.reset()
                } else {
                    issue = FrogError.message("No microphone could be opened, so recording stopped. What was recorded is being transcribed.")
                    requestStop()
                }
            }
            onError?(issue)
        }
    }

    private func rememberMicrophone(_ id: String?) {
        guard preferences.microphoneID != id else { return }
        preferences.microphoneID = id
        onMicrophoneChange?(id)
    }

    private func beginRecording(microphoneID: String?) throws {
        // A saved choice is a persistent device UID. One that is not connected, or the device
        // number an earlier version saved, names no input: the callers go on with the default.
        if let microphoneID, !inputDevices().contains(where: { $0.uid == microphoneID }) {
            throw FrogError.message("The selected microphone is unavailable. Choose another microphone.")
        }
        let recorder = makeRecorder()
        let samples = self.samples
        let input = samples.beginInput()
        // Only this capture's buffers count as its first sound, not the last ones of a replaced input.
        lastInputRevision = samples.inputRevision
        if microphoneDelivering { microphoneDelivering = false }
        do { try recorder.start(deviceUID: microphoneID) { samples.append($0, from: input) } }
        catch { recorder.stop(); throw error }
        self.recorder = recorder
    }

    /// The wait before the preview reads the recording again.
    private var previewDelay: Duration {
        Self.previewDelay(interval: previewInterval, uncommittedSamples: samples.count - transcript.offset)
    }

    /// Every pass transcribes all the audio that no finished window holds yet, so passes get rarer
    /// as that audio grows: half an interval more for every ten seconds. The pass that completes
    /// the window keeps its text and shortens Stop, so the longer wait never runs past that point.
    nonisolated static func previewDelay(interval: Duration, uncommittedSamples: Int) -> Duration {
        let full = DictationTranscript.samplesCompletingWindow, uncommitted = max(0, uncommittedSamples)
        guard uncommitted < full else { return interval }
        let widened = interval * (2 + uncommitted / (10 * 16000)) / 2
        // A quarter second later the capture buffer that completes the window has arrived too.
        let untilFull = Duration.milliseconds((full - uncommitted) / 16 + 250)
        return min(widened, max(interval, untilFull))
    }

    func refreshPreview(includePartial: Bool = true) async throws {
        guard let token, let rule = activeRule, let models, let modelID = rule.action?.audioModelID,
              rule.action?.audioProviderID == nil, phase == .recording, !models.busy, previewInference == nil else { return }
        let transcript = self.transcript
        let completes = DictationTranscript.completesWindow(uncommittedSamples: samples.count - transcript.offset)
        if completes, let partial = transcript.partial, partial.sampleCount == DictationTranscript.window {
            // A partial pass already read this whole window before the audio after it arrived.
            transcript.acceptPreview(partial.text, sampleCount: partial.sampleCount, completesWindow: true)
            updatePreview(partial.text, completingWindow: true)
            return
        }
        let audio = samples.snapshot(from: transcript.offset, limit: DictationTranscript.window)
        guard completes || (includePartial && audio.count >= 16000 && transcript.partial?.sampleCount != audio.count) else { return }
        // Keep inference separate from the preview timer: Stop interrupts the timer
        // but lets useful in-flight recognition finish, including interrupted history.
        let inference = Task { [weak self] in
            let text = try await models.transcribe(audio, modelID: modelID, language: rule.action?.transcriptionLanguage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            transcript.acceptPreview(text, sampleCount: audio.count, completesWindow: completes)
            guard let self, self.token == token, self.phase == .recording || self.phase == .transcribing else { return }
            self.updatePreview(text, completingWindow: completes)
        }
        previewInference = inference; previewSnapshot = (audio.count, completes)
        defer { if self.token == token { previewInference = nil; previewSnapshot = nil } }
        try await inference.value
    }

    /// Says in the popup that a press started nothing because this recording is still being
    /// finished. False when no popup shows it, so the caller can say it another way.
    func showPressWhileFinishing() -> Bool {
        guard finishing else { return false }
        pressedWhileFinishing = true
        return panel?.isVisible == true
    }

    func stop(models: LocalModels) {
        guard let token, let rule = activeRule else { return }
        if phase == .preparing { cancel(); return }
        guard phase == .recording else { return }
        deliver(token: token, rule: rule, models: models)
    }

    /// Repeats the final pass over the recording that a failed transcription left in memory.
    func retryTranscription() {
        guard phase == .failed, let token, let rule = activeRule, let models else { return }
        failure = ""
        residencyHold = models.holdResidency()
        installEscape()
        deliver(token: token, rule: rule, models: models)
    }

    /// Copies what was recognised before the final pass failed. The recording stays for a retry.
    func copyPartialTranscript() {
        guard phase == .failed, !liveText.isEmpty else { return }
        copy(liveText)
        onCopy?(liveText)
    }

    private func deliver(token: UUID, rule: Rule, models: LocalModels) {
        let recognition = finishTranscription(token: token, rule: rule, models: models)
        let recordingSeconds = self.recordingSeconds
        phase = .transcribing; pressedWhileFinishing = false; hint = "Esc to cancel"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await recognition.value
                try Task.checkCancellation()
                guard self.token == token else { return }
                self.liveText = raw
                var output = raw
                if rule.action?.cleanup == true {
                    self.phase = .correcting
                    if let cleanup = self.cleanup {
                        do { output = try await cleanup(raw, rule) }
                        catch {
                            try Task.checkCancellation()
                            guard self.token == token else { return }
                            self.onError?(FrogError.message("Cleanup failed; the original transcript will be copied. \(error.localizedDescription)"))
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.token == token else { return }
                // A completed transcript belongs in history even if delivery is subsequently cancelled.
                self.transcriptPublished = true
                self.onTranscript?(token, rule, raw, output)
                self.copy(output)
                self.onCopy?(output)
                var insertion: (() async throws -> Void)?
                if (rule.action?.output ?? self.preferences.output) == .paste {
                    insertion = self.paste
                }
                try await DictationDelivery.finish(isCurrent: { self.token == token }, paste: insertion, onIssue: { self.onError?($0) }, onSuccess: {
                    self.onSuccessfulDelivery?(recordingSeconds, raw)
                }) { delivery in
                    self.onFinish?(rule, raw, output, delivery)
                    if self.token == token { self.cancel() }
                }
            } catch {
                // Only a failed final pass leaves the recording with the transcript.
                if self.token == token, !Task.isCancelled, self.transcript.canRetry { self.keepForRetry(error) }
                else { self.fail(error, token: token) }
            }
        }
    }

    /// A final pass that can be repeated must not cost the recording: keep it, show what was
    /// already recognised and let the person retry, copy that text or discard.
    private func keepForRetry(_ error: Error) {
        finalTranscription = nil
        if let residencyHold { models?.releaseResidency(residencyHold) }; residencyHold = nil
        // Escape pressed in another app must not discard the recording unnoticed.
        removeEscape()
        liveText = transcript.recognized
        failure = error.localizedDescription
        phase = .failed
        onError?(error)
        if panel?.isVisible != true { showPanel() }
    }

    private func finishTranscription(token: UUID, rule: Rule, models: LocalModels) -> Task<String, Error> {
        if let finalTranscription { return finalTranscription }
        if let recordingStarted {
            let duration = recordingStarted.duration(to: now()).components
            recordingSeconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            self.recordingStarted = nil
        }
        let recorder = self.recorder; self.recorder = nil
        let capturedSamples = samples, transcript = self.transcript
        let pending = previewInference, external = externalTranscription
        // Audio recorded after a partial preview's snapshot means its text will not be used:
        // stop it, so the final pass does not wait for a result it would throw away.
        if let snapshot = previewSnapshot, !snapshot.completesWindow,
           capturedSamples.count - transcript.offset > snapshot.sampleCount { pending?.cancel() }
        ticker?.cancel(); ticker = nil
        preview?.cancel(); preview = nil
        let recognition = Task { [weak self] in
            try await transcript.finish(recorder: recorder, samples: capturedSamples,
                                        pendingPreview: pending, models: models, rule: rule, external: external) {
                if self?.token == token { self?.outputMute.restore() }
            }
        }
        finalTranscription = recognition
        return recognition
    }

    func interrupt(reason: HistoryEntry.Interruption = .cancelled) {
        // Discarding a failed transcription is a failed request: nothing goes to History.
        guard let token, let rule = activeRule, let models, phase != .preparing, phase != .failed else { cancel(); return }
        let interruption = DictationInterruption(id: token, rule: rule, text: liveText,
                                                reason: reason, transcriptPublished: transcriptPublished)
        guard onInterruption?(interruption) == true else { cancel(); return }
        let recognition = finishTranscription(token: token, rule: rule, models: models)
        let hold = residencyHold; residencyHold = nil
        // Transfer capture/recognition ownership before resetting the active recording.
        finalTranscription = nil; previewInference = nil; previewSnapshot = nil; samples = AudioSamples()
        cancel()
        recoveringHistoryIDs.insert(token)
        let recovery = Task { [weak self] in
            defer {
                if let hold { models.releaseResidency(hold) }
                self?.historyRecovery[token] = nil
                self?.recoveringHistoryIDs.remove(token)
            }
            do {
                let text = try await recognition.value
                try Task.checkCancellation()
                self?.onHistoryRecovered?(token, .success(text))
            } catch {
                if !Task.isCancelled { self?.onHistoryRecovered?(token, .failure(error)) }
            }
        }
        historyRecovery[token] = (recovery, recognition)
    }

    func cancelHistoryRecovery(id: UUID? = nil) {
        for (key, task) in historyRecovery where id == nil || id == key {
            task.work.cancel(); task.recognition.cancel(); recoveringHistoryIDs.remove(key)
        }
    }
    func requestStop() { if let models { stop(models: models) } }
    func updatePreview(_ text: String, completingWindow: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { previewDraft = text }
        liveText = DictationTranscript.join([previewPrefix, previewDraft])
        if completingWindow { previewPrefix = liveText; previewDraft = "" }
    }
    func setPopupVisible(_ visible: Bool) {
        preferences.showDictationPopup = visible
        if !visible { panel?.orderOut(nil) }
        else if active { showPanel() }
    }
    func cancel() {
        token = nil; work?.cancel(); finalTranscription?.cancel(); preview?.cancel(); previewInference?.cancel(); ticker?.cancel()
        work = nil; finalTranscription = nil; preview = nil; previewInference = nil; previewSnapshot = nil; ticker = nil
        recorder?.stop(); recorder = nil; samples.clear()
        // A recording kept for a retry ends with its session; interrupted history holds its own.
        transcript = DictationTranscript(); failure = ""
        recordingStarted = nil; recordingSeconds = 0
        outputMute.restore()
        if let residencyHold { models?.releaseResidency(residencyHold) }; residencyHold = nil
        activeRule = nil; ruleID = nil; phase = .idle
        panel?.orderOut(nil)
        removeEscape()
    }
    private func removeEscape() {
        cancelKey?.unregister()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }; localEscapeMonitor = nil
    }
    private func fail(_ error: Error, token: UUID) {
        guard self.token == token else { return }
        if !Task.isCancelled { onError?(error) }
        cancel()
    }
    private func installEscape() {
        guard let token else { return }
        // A registered key works without Accessibility permission and keeps Escape from the focused
        // app. While a hold shortcut is down, Escape arrives together with that shortcut's modifiers.
        let hold = (activeRule?.action?.recordingMode ?? preferences.recordingMode) == .hold
        cancelKey?.register(heldModifiers: hold ? activeRule?.hotkey?.modifiers ?? 0 : 0) { [weak self] in
            guard self?.token == token else { return }
            self?.interrupt(reason: .escape)
        }
        guard monitorKeys else { return }
        // The monitors remain for an Escape that macOS would not register for Frog.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    guard self?.token == token else { return }
                    self?.interrupt(reason: .escape)
                }
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.token == token { self?.interrupt(reason: .escape); return nil }; return event
        }
    }
    private func showPanel() {
        guard presentsPopup else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 50), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.title = "Dictation"
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        let content = DictationPopup(controller: self)
        if let hosting = panel?.contentView as? NSHostingView<DictationPopup> { hosting.rootView = content }
        else {
            let hosting = NSHostingView(rootView: content)
            // The panel owns geometry; SwiftUI must not impose its transient ideal size.
            hosting.sizingOptions = []
            panel?.contentView = hosting
        }
        resizePanel(on: NSScreen.main, animated: false)
        panel?.orderFrontRegardless()
    }

    private func resizePanel(on screen: NSScreen? = nil, animated: Bool = true) {
        guard let panel, phase != .idle,
              let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let frame = DictationPopupLayout.frame(phase: phase, text: liveText, visibleFrame: screen.visibleFrame)
        guard frame != panel.frame else { return }
        if animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = FrogMotion.resize
                context.timingFunction = FrogMotion.resizeCurve
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }
}

/// Geometry is based on rendered text, so a short preview doesn't reserve a large blank area.
@MainActor
enum DictationPopupLayout {
    static let maximumHeight = 220.0
    static let maximumTranscriptHeight = 104.0
    /// Presentation only. Keep native glyph layout bounded even for hours of Unicode text.
    /// The controller and delivery pipeline always retain the complete transcript.
    static func displayText(_ text: String) -> String { String(text.suffix(2048)) }
    static func frame(phase: DictationController.Phase, text: String, visibleFrame: NSRect) -> NSRect {
        let recording = phase == .recording, failed = phase == .failed
        let hasTranscript = (recording || failed) && !text.isEmpty
        let width = min(recording || failed ? 360.0 : 300.0, max(1, visibleFrame.width - 32))
        // A failed transcription shows its reason and what to do instead of the waveform and hint.
        var height = recording ? 108.0 : failed ? 116.0 : 50.0
        if hasTranscript {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
            let bounds = (displayText(text) as NSString).boundingRect(
                with: NSSize(width: max(1, width - 24), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
            height += min(maximumTranscriptHeight, ceil(bounds.height) + 2) + 8
        }
        height = min(height, maximumHeight, max(1, visibleFrame.height - 48))
        return NSRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.minY + min(24, max(0, (visibleFrame.height - height) / 2)),
                      width: width, height: height)
    }
}

private struct DictationPopup: View {
    @ObservedObject var controller: DictationController
    @State private var copiedPartial = false
    @State private var closeHovering = false
    var body: some View {
        let failed = controller.phase == .failed
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(FrogStyle.warning) }
                else if controller.phase != .recording { ProgressView().controlSize(.mini) }
                else {
                    Menu {
                        Button { controller.selectMicrophone(nil) } label: {
                            Label("System default", systemImage: controller.selectedMicrophoneID == nil ? "checkmark" : "mic")
                        }
                        ForEach(controller.microphones) { device in
                            Button { controller.selectMicrophone(device.uid) } label: {
                                Label(device.name, systemImage: controller.selectedMicrophoneID == device.uid ? "checkmark" : "mic")
                            }
                        }
                    } label: { Image(systemName: "mic.fill").foregroundStyle(FrogStyle.accent) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Change microphone").accessibilityLabel("Change microphone")
                    .simultaneousGesture(TapGesture().onEnded { controller.refreshMicrophones() })
                }
                Text(L10n.text(controller.statusText)).font(FrogType.section)
                    .lineLimit(1).truncationMode(.tail).help(L10n.text(controller.statusText))
                Spacer(minLength: 0)
                if controller.phase == .recording {
                    Text(String(format: "%d:%02d", controller.elapsed / 60, controller.elapsed % 60))
                        .font(FrogType.body).monospacedDigit().foregroundStyle(FrogStyle.muted)
                    Button { controller.requestStop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.frog(compact: true)).help("Stop recording").accessibilityLabel("Stop recording")
                }
                if failed {
                    Button { controller.retryTranscription() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.frog(compact: true)).help("Transcribe the recording again").accessibilityLabel("Retry transcription")
                }
                // An `IconAction` at the compact height, which keeps its own help text.
                Button { controller.interrupt() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(closeHovering ? FrogStyle.ink : FrogStyle.muted)
                        .frame(width: FrogStyle.compactHeight, height: FrogStyle.compactHeight)
                        .frogRowHighlight(hovering: closeHovering)
                }.buttonStyle(.plain).onHover { closeHovering = $0 }.help(failed ? "Discard recording" : "Cancel dictation · Esc")
                    .accessibilityLabel(failed ? "Discard recording" : "Cancel dictation")
            }.frame(height: 26)
            if failed {
                Text(controller.failure).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .lineLimit(2).truncationMode(.tail).help(controller.failure)
                    .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 28, alignment: .topLeading)
            }
            if controller.phase == .recording {
                HStack(spacing: 8) {
                    if controller.noMicrophoneInput {
                        Label("No microphone input", systemImage: "exclamationmark.triangle.fill")
                            .font(FrogType.small).foregroundStyle(FrogStyle.warning).fixedSize()
                    }
                    MicrophoneWaveform(meter: controller.microphoneMeter)
                }.frame(height: 28)
            }
            if controller.phase == .recording || failed, !controller.liveText.isEmpty {
                DictationTranscriptView(text: controller.liveText)
                    .frame(minHeight: 0, maxHeight: DictationPopupLayout.maximumTranscriptHeight)
            }
            if controller.phase == .recording {
                Text(controller.hint).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }
            if failed {
                HStack(spacing: 8) {
                    Text("The recording is kept until you retry or discard it.")
                        .font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    Spacer(minLength: 0)
                    if !controller.liveText.isEmpty {
                        Button(copiedPartial ? "Copied" : "Copy partial text") {
                            controller.copyPartialTranscript(); copiedPartial = true
                        }.buttonStyle(.frog(.ghost, compact: true))
                            .fixedSize().help("Copy the text recognised before the failure")
                    }
                }.frame(height: 20)
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: controller.phase) { copiedPartial = false }
            .clipped()
            .environment(\.locale, L10n.locale)
            .foregroundStyle(FrogStyle.ink)
            .frogPanel()
    }
}

private struct DictationTranscriptView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> DictationTranscriptViewport { DictationTranscriptViewport() }
    func updateNSView(_ view: DictationTranscriptViewport, context: Context) {
        view.transcriptView.textColor = NSColor(FrogStyle.ink)
        view.setTranscript(text)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DictationTranscriptViewport, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: min(proposal.height ?? 0, DictationPopupLayout.maximumTranscriptHeight))
    }
}

/// The document can grow, but its viewport never contributes an intrinsic height.
/// AppKit follows the tail after text layout AND after each native panel resize.
@MainActor
final class DictationTranscriptViewport: NSScrollView {
    let transcriptView = NSTextView()
    private var layingOutTranscript = false
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("dictation-transcript")
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; autohidesScrollers = true; scrollerStyle = .overlay
        transcriptView.drawsBackground = false
        transcriptView.isEditable = false; transcriptView.isSelectable = true
        transcriptView.isHorizontallyResizable = false; transcriptView.isVerticallyResizable = false
        transcriptView.textContainerInset = .zero
        transcriptView.textContainer?.lineFragmentPadding = 0
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.textContainer?.heightTracksTextView = false
        transcriptView.setAccessibilityLabel("Live transcript")
        documentView = transcriptView
    }
    required init?(coder: NSCoder) { return nil }

    func setTranscript(_ text: String) {
        let text = DictationPopupLayout.displayText(text)
        guard transcriptView.string != text else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        transcriptView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph,
            .foregroundColor: transcriptView.textColor ?? .labelColor
        ]))
        needsLayout = true
        layoutTranscript()
    }

    override func layout() {
        super.layout()
        layoutTranscript()
    }

    private func layoutTranscript() {
        guard !layingOutTranscript, contentSize.width >= 16, contentSize.height > 0,
              let container = transcriptView.textContainer,
              let manager = transcriptView.layoutManager else { return }
        layingOutTranscript = true
        defer { layingOutTranscript = false }
        let width = max(1, contentSize.width)
        transcriptView.setFrameSize(NSSize(width: width, height: max(1, transcriptView.frame.height)))
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(contentSize.height, ceil(manager.usedRect(for: container).maxY) + 2)
        transcriptView.setFrameSize(NSSize(width: width, height: height))
        contentView.scroll(to: NSPoint(x: 0, y: max(0, height - contentSize.height)))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
final class MicrophoneMeter: ObservableObject {
    @Published private(set) var levels = Array(repeating: 0.0, count: 40)
    private var envelope = 0.0
    func append(_ level: Double) {
        let target = level.isFinite ? min(1, max(0, level)) : 0
        // At the feedback ticker's 100 ms cadence, catch syllables immediately and
        // let them decay over a few frames instead of flickering between callbacks.
        let timeConstant = target > envelope ? 0.045 : 0.24
        envelope += (target - envelope) * (1 - exp(-0.1 / timeConstant))
        if envelope < 0.005 { envelope = 0 }
        levels = Array(levels.dropFirst()) + [envelope]
    }
    func reset() { envelope = 0; levels = Array(repeating: 0, count: 40) }
}

private struct MicrophoneWaveform: View {
    @ObservedObject var meter: MicrophoneMeter
    var body: some View {
        let levels = meter.levels
        Canvas { context, size in
            let step = size.width / CGFloat(max(levels.count, 1))
            for (index, level) in levels.enumerated() {
                let height = max(2, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(2, step - 3), height: height)
                context.fill(Capsule().path(in: rect), with: .color(FrogStyle.accent.opacity(level > 0.02 ? 0.85 : 0.25)))
            }
        }.accessibilityLabel("Microphone input level")
            .accessibilityValue("\(Int((levels.last ?? 0) * 100)) percent")
    }
}

final class AudioSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var level = 0.0
    private var revision: UInt64 = 0
    private var input = UUID()
    private var lastInput = ContinuousClock.now
    var inputRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
    var inputLevel: Double {
        lock.lock(); defer { lock.unlock() }
        return lastInput.duration(to: .now) < .milliseconds(300) ? level : 0
    }
    func beginInput() -> UUID {
        lock.lock(); defer { lock.unlock() }
        input = UUID(); level = 0; lastInput = .now
        return input
    }
    func endInput() { lock.lock(); defer { lock.unlock() }; input = UUID(); level = 0 }
    func append(_ buffer: [Float], from input: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty, input == nil || input == self.input else { return }
        revision &+= 1
        samples.append(contentsOf: buffer.prefix(max(0, 600 * 16000 - samples.count)))
        let energy = buffer.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = sqrt(energy / Double(buffer.count))
        // Display only: -56 dBFS noise floor through -12 dBFS loud speech. Ordinary
        // microphone speech (~-34 dBFS) now fills half the waveform, not just 16%.
        let decibels = 20 * log10(max(rms, 1e-9))
        level = decibels.isFinite ? min(1, max(0, (decibels + 56) / 44)) : 0
        lastInput = .now
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
    func snapshot(from offset: Int = 0, limit: Int? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let start = min(offset, samples.count)
        return Array(samples[start..<min(samples.count, start + (limit ?? samples.count))])
    }
    func clear() { lock.lock(); defer { lock.unlock() }; samples = []; level = 0; input = UUID() }
}

@MainActor
struct DictationTarget {
    /// The app that receives the paste. Each obstacle has its own message, because the remedies
    /// differ; the transcript is on the clipboard in every case.
    nonisolated static func application(trusted: Bool, frontmost: pid_t?,
                                        own: pid_t = ProcessInfo.processInfo.processIdentifier) throws -> pid_t {
        guard trusted else {
            throw FrogError.message("Allow Frog in System Settings → Privacy & Security → Accessibility to paste. The transcript is copied.")
        }
        guard let frontmost, frontmost != own else {
            throw FrogError.message("Focus an input field in another app to paste. The transcript is copied.")
        }
        return frontmost
    }

    static func pasteIntoFocusedField() async throws {
        try await ClipboardSelection.waitForShortcutRelease(message: "Release the shortcut keys so Frog can paste. The transcript is copied.")
        try Task.checkCancellation()
        let application = try application(trusted: SelectionService.isTrusted,
                                          frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let ax = AXUIElementCreateApplication(application)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        if let element = AXRead.element(ax, kAXFocusedUIElementAttribute),
           AXRead.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
            throw FrogError.message("The focused field is a password field. The transcript is copied.")
        }
        // Not every layout has V where QWERTY has it.
        let key = CommandKey.code(for: "v", fallback: 9)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw FrogError.message("Could not send the paste shortcut. The transcript is copied.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
