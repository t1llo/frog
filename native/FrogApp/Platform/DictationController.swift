import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import FrogCore
import WhisperKit

@MainActor
final class DictationController: ObservableObject {
    enum Phase: String { case idle, preparing, recording, transcribing, correcting }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var noMicrophoneInput = false
    @Published private(set) var selectedMicrophoneID: String?
    @Published private(set) var microphones: [AudioDevice] = []
    @Published private(set) var recoveringHistoryIDs = Set<UUID>()
    let microphoneMeter = MicrophoneMeter()
    @Published private(set) var hint = ""
    @Published private(set) var preparationMessage = "Preparing…"
    private(set) var ruleID: UUID?
    private var recorder: (any DictationRecording)?
    private let makeRecorder: () -> any DictationRecording
    private let authorize: () async -> Bool
    private let copy: (String) -> Void
    var onCopy: ((String) -> Void)?
    private let monitorKeys: Bool
    private let previewInterval: Duration
    private let inputDevices: () -> [AudioDevice]
    private var lastInputElapsed = 0
    private var lastInputRevision: UInt64 = 0
    private let outputMute = RecordingMute()
    private var work: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var previewInference: Task<Void, Error>?
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
    var onTranscript: ((UUID, Rule, String, String) -> Void)?
    var onInterruption: ((DictationInterruption) -> Bool)?
    var onHistoryRecovered: ((UUID, Result<String, Error>) -> Void)?
    var onError: ((Error) -> Void)?
    var onMicrophoneChange: ((String?) -> Void)?
    var cleanup: ((String, Rule) async throws -> String)?
    var localCleanupModel: ((Rule) throws -> String?)?
    var externalTranscription: (([Float], Rule) async throws -> String)?
    var active: Bool { phase != .idle }

    init(makeRecorder: @escaping @MainActor () -> any DictationRecording = { MicrophoneRecording() },
         authorize: @escaping @MainActor () async -> Bool = { DictationController.microphoneGranted ? true : await DictationController.requestMicrophone() },
         copy: @escaping (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) },
         monitorKeys: Bool = true, previewInterval: Duration = .seconds(2),
         inputDevices: @escaping @MainActor () -> [AudioDevice] = { DictationController.devices }) {
        self.makeRecorder = makeRecorder; self.authorize = authorize; self.copy = copy; self.monitorKeys = monitorKeys
        self.previewInterval = previewInterval
        self.inputDevices = inputDevices
    }

    func waitForWork() async { await work?.value }
    func waitForHistoryRecovery() async {
        for task in Array(historyRecovery.values) { await task.work.value }
    }

    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var devices: [AudioDevice] { AudioProcessor.getAudioDevices() }
    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func start(rule: Rule, preferences: WorkflowPreferences, models: LocalModels) {
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
        noMicrophoneInput = false; lastInputElapsed = 0; lastInputRevision = 0
        selectedMicrophoneID = preferences.microphoneID; refreshMicrophones()
        microphoneMeter.reset()
        previewPrefix = ""; previewDraft = ""
        transcript = DictationTranscript(); transcriptPublished = false
        phase = .preparing
        preparationMessage = "Checking microphone permission…"
        let shortcut = rule.hotkey.map(HotkeyManager.display) ?? "Stop button"
        let recordingHint = rule.hotkey == nil ? "Stop to finish · Esc to cancel" : (rule.action?.recordingMode ?? preferences.recordingMode) == .hold ? "Release \(shortcut) to stop · Esc to cancel" : "\(shortcut) to stop · Esc to cancel"
        hint = "Esc to cancel"
        if self.preferences.showDictationPopup { showPanel() }
        if monitorKeys { installEscape() }
        work = Task { [weak self] in
            guard let self else { return }
            let granted = await self.authorize()
            guard self.token == token, !Task.isCancelled else { return }
            guard granted else {
                self.fail(FrogError.message("Allow Microphone in Settings to record dictation."), token: token); return
            }
            guard self.token == token, !Task.isCancelled else { return }
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
                if preferences.muteWhileRecording == true { try self.outputMute.begin() }
                do { try self.beginRecording(microphoneID: self.preferences.microphoneID) }
                catch {
                    guard self.preferences.microphoneID != nil else { throw error }
                    // A disconnected preferred input must not prevent starting with
                    // macOS's default. Keep the saved preference for its next connection.
                    try self.beginRecording(microphoneID: nil)
                    self.selectedMicrophoneID = nil
                }
                self.phase = .recording
                self.hint = recordingHint
                let recordingStarted = ContinuousClock.now
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.token == token else { return }
                        self.refreshRecordingFeedback(elapsed: Int(recordingStarted.duration(to: .now).components.seconds))
                        if self.elapsed >= 600 { self.stop(models: models); return }
                    }
                }
                self.preview = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: self?.previewInterval ?? .seconds(2))
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
        if revision != lastInputRevision { lastInputElapsed = elapsed; lastInputRevision = revision }
        let missing = phase == .recording && elapsed - lastInputElapsed >= 2
        if noMicrophoneInput != missing { noMicrophoneInput = missing }
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
            let issue = error
            do { try beginRecording(microphoneID: previous) }
            catch { if let token { fail(error, token: token) }; return }
            onError?(issue)
        }
    }

    private func rememberMicrophone(_ id: String?) {
        guard preferences.microphoneID != id else { return }
        preferences.microphoneID = id
        onMicrophoneChange?(id)
    }

    private func beginRecording(microphoneID: String?) throws {
        let device = microphoneID.flatMap(UInt32.init)
        if let device, !inputDevices().contains(where: { $0.id == device }) {
            throw FrogError.message("The selected microphone is unavailable. Choose another microphone.")
        }
        let recorder = makeRecorder()
        let samples = self.samples
        let input = samples.beginInput()
        do { try recorder.start(device: device) { samples.append($0, from: input) } }
        catch { recorder.stop(); throw error }
        self.recorder = recorder
    }

    func refreshPreview(includePartial: Bool = true) async throws {
        guard let token, let rule = activeRule, let models, let modelID = rule.action?.audioModelID,
              rule.action?.audioProviderID == nil, phase == .recording, !models.busy, previewInference == nil else { return }
        let transcript = self.transcript
        let audio = samples.snapshot(from: transcript.offset, limit: 30 * 16000)
        guard audio.count >= (includePartial ? 16000 : 30 * 16000), transcript.partial?.sampleCount != audio.count else { return }
        // Keep inference separate from the preview timer: Stop interrupts the timer
        // but lets useful in-flight recognition finish, including interrupted history.
        let inference = Task { [weak self] in
            let text = try await models.transcribe(audio, modelID: modelID, language: rule.action?.transcriptionLanguage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            transcript.acceptPreview(text, sampleCount: audio.count)
            guard let self, self.token == token, self.phase == .recording || self.phase == .transcribing else { return }
            self.updatePreview(text, completingWindow: audio.count == 30 * 16000)
        }
        previewInference = inference
        defer { if self.token == token { previewInference = nil } }
        try await inference.value
    }

    func stop(models: LocalModels) {
        guard let token, let rule = activeRule else { return }
        if phase == .preparing { cancel(); return }
        guard phase == .recording else { return }
        let recognition = finishTranscription(token: token, rule: rule, models: models)
        phase = .transcribing; hint = "Esc to cancel"
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
                    insertion = {
                        try await DictationTarget.pasteIntoFocusedField()
                    }
                }
                try await DictationDelivery.finish(isCurrent: { self.token == token }, paste: insertion, onIssue: { self.onError?($0) }) { delivery in
                    self.onFinish?(rule, raw, output, delivery)
                    self.cancel()
                }
            } catch { self.fail(error, token: token) }
        }
    }

    private func finishTranscription(token: UUID, rule: Rule, models: LocalModels) -> Task<String, Error> {
        if let finalTranscription { return finalTranscription }
        let recorder = self.recorder; self.recorder = nil
        let capturedSamples = samples, transcript = self.transcript
        let pending = previewInference, external = externalTranscription
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
        guard let token, let rule = activeRule, let models, phase != .preparing else { cancel(); return }
        let interruption = DictationInterruption(id: token, rule: rule, text: liveText,
                                                reason: reason, transcriptPublished: transcriptPublished)
        guard onInterruption?(interruption) == true else { cancel(); return }
        let recognition = finishTranscription(token: token, rule: rule, models: models)
        let hold = residencyHold; residencyHold = nil
        // Transfer capture/recognition ownership before resetting the active recording.
        finalTranscription = nil; previewInference = nil; samples = AudioSamples()
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
        liveText = [previewPrefix, previewDraft].filter { !$0.isEmpty }.joined(separator: " ")
        if completingWindow { previewPrefix = liveText; previewDraft = "" }
    }
    func setPopupVisible(_ visible: Bool) {
        preferences.showDictationPopup = visible
        if !visible { panel?.orderOut(nil) }
        else if active { showPanel() }
    }
    func cancel() {
        token = nil; work?.cancel(); finalTranscription?.cancel(); preview?.cancel(); previewInference?.cancel(); ticker?.cancel()
        work = nil; finalTranscription = nil; preview = nil; previewInference = nil; ticker = nil
        recorder?.stop(); recorder = nil; samples.clear()
        outputMute.restore()
        if let residencyHold { models?.releaseResidency(residencyHold) }; residencyHold = nil
        activeRule = nil; ruleID = nil; phase = .idle
        panel?.orderOut(nil)
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
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: DictationPopup.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        let content = DictationPopup(controller: self)
        if let hosting = panel?.contentView as? NSHostingView<DictationPopup> { hosting.rootView = content }
        else { panel?.contentView = NSHostingView(rootView: content) }
        if let screen = NSScreen.main { panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - DictationPopup.size.width / 2, y: screen.visibleFrame.minY + 24)) }
        panel?.orderFrontRegardless()
    }
}

private struct DictationPopup: View {
    static let size = NSSize(width: 400, height: 120)
    @ObservedObject var controller: DictationController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if controller.phase != .recording { ProgressView().controlSize(.mini) }
                else {
                    Menu {
                        Button { controller.selectMicrophone(nil) } label: {
                            Label("System default", systemImage: controller.selectedMicrophoneID == nil ? "checkmark" : "mic")
                        }
                        ForEach(controller.microphones) { device in
                            Button { controller.selectMicrophone(String(device.id)) } label: {
                                Label(device.name, systemImage: controller.selectedMicrophoneID == String(device.id) ? "checkmark" : "mic")
                            }
                        }
                    } label: { Image(systemName: "mic.fill").foregroundStyle(FrogStyle.accent) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Change microphone").accessibilityLabel("Change microphone")
                    .simultaneousGesture(TapGesture().onEnded { controller.refreshMicrophones() })
                }
                Text(L10n.text(controller.phase.rawValue.capitalized)).font(.system(size: 12, weight: .semibold))
                Spacer()
                if controller.phase != .preparing { Text("\(controller.elapsed)s").monospacedDigit().foregroundStyle(.secondary) }
                if controller.phase == .recording {
                    Button { controller.requestStop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Stop recording").accessibilityLabel("Stop recording")
                }
                Button { controller.interrupt() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel dictation")
            }
            if controller.phase == .recording {
                HStack(spacing: 8) {
                    if controller.noMicrophoneInput {
                        Label("No microphone input", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize()
                    }
                    MicrophoneWaveform(meter: controller.microphoneMeter)
                }.frame(height: 16)
            }
            ScrollViewReader { reader in
                ScrollView {
                    Text(controller.liveText.isEmpty ? L10n.text(controller.phase == .preparing ? controller.preparationMessage : controller.phase == .recording ? "Listening…" : "Processing audio…") : controller.liveText)
                        .font(.system(size: 12)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("transcript-end")
                }.onChange(of: controller.liveText) { _, _ in reader.scrollTo("transcript-end", anchor: .bottom) }
            }
            Text(controller.hint).font(.system(size: 9)).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(width: Self.size.width, height: Self.size.height)
            .environment(\.locale, L10n.locale)
            .foregroundStyle(FrogStyle.ink)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
    }
}

@MainActor
final class MicrophoneMeter: ObservableObject {
    @Published private(set) var levels = Array(repeating: 0.0, count: 40)
    func append(_ level: Double) { levels = Array(levels.dropFirst()) + [level] }
    func reset() { levels = Array(repeating: 0, count: 40) }
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
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(FrogStyle.accent.opacity(level > 0.02 ? 0.85 : 0.25)))
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
        level = min(1, sqrt(energy / Double(max(1, buffer.count))) * 8)
        lastInput = .now
    }
    func snapshot(from offset: Int = 0, limit: Int? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let start = min(offset, samples.count)
        return Array(samples[start..<min(samples.count, start + (limit ?? samples.count))])
    }
    func clear() { lock.lock(); defer { lock.unlock() }; samples = []; level = 0; input = UUID() }
}

@MainActor
private struct DictationTarget {
    static func pasteIntoFocusedField() async throws {
        try await ClipboardSelection.waitForShortcutRelease()
        try Task.checkCancellation()
        guard SelectionService.isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw FrogError.message("Focus an input field in another app to paste. The transcript is copied.")
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        if let element = AXRead.element(ax, kAXFocusedUIElementAttribute),
           AXRead.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
            throw FrogError.message("The focused field is a password field. The transcript is copied.")
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
}
