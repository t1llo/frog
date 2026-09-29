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
    @Published private(set) var inputLevels: [Double] = Array(repeating: 0, count: 40)
    @Published private(set) var hint = ""
    private(set) var ruleID: UUID?
    private var recorder: (any DictationRecording)?
    private let makeRecorder: () -> any DictationRecording
    private let authorize: () async -> Bool
    private let copy: (String) -> Void
    private let monitorKeys: Bool
    private let outputMute = RecordingMute()
    private var work: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var panel: NSPanel?
    private var token: UUID?
    private var stopRequested = false
    private var samples = AudioSamples()
    private var previewPrefix = ""
    private var previewDraft = ""
    private var activeRule: Rule?
    private var preferences = WorkflowPreferences()
    private weak var models: LocalModels?
    var onFinish: ((Rule, String, String, String) -> Void)?
    var onTranscript: ((Rule, String, String) -> Void)?
    var onError: ((Error) -> Void)?
    var cleanup: ((String, Rule) async throws -> String)?
    var externalTranscription: (([Float], Rule) async throws -> String)?
    var active: Bool { phase != .idle }

    init(makeRecorder: @escaping @MainActor () -> any DictationRecording = { MicrophoneRecording() },
         authorize: @escaping @MainActor () async -> Bool = { DictationController.microphoneGranted ? true : await DictationController.requestMicrophone() },
         copy: @escaping (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) },
         monitorKeys: Bool = true) {
        self.makeRecorder = makeRecorder; self.authorize = authorize; self.copy = copy; self.monitorKeys = monitorKeys
    }

    func waitForWork() async { await work?.value }

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
        self.preferences.showDictationPopup = rule.action?.showRecordingPopup ?? true
        self.preferences.transcriptionLanguage = rule.action?.transcriptionLanguage
        stopRequested = false; samples = AudioSamples(); liveText = ""; elapsed = 0
        inputLevels = Array(repeating: 0, count: 40)
        previewPrefix = ""; previewDraft = ""
        phase = .preparing
        let shortcut = rule.hotkey.map(HotkeyManager.display) ?? "Stop button"
        hint = (rule.action?.recordingMode ?? preferences.recordingMode) == .hold ? "Release \(shortcut) to stop · Esc to cancel" : "\(shortcut) to stop · Esc to cancel"
        if rule.hotkey == nil { hint = "Stop to finish · Esc to cancel" }
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
            if self.stopRequested { self.cancel(); return }
            do {
                let recorder = self.makeRecorder()
                self.recorder = recorder
                let device = preferences.microphoneID.flatMap(UInt32.init)
                if let device, !Self.devices.contains(where: { $0.id == device }) { throw FrogError.message("The selected microphone is unavailable. Choose another in Settings.") }
                let samples = self.samples
                if preferences.muteWhileRecording == true { try self.outputMute.begin() }
                try recorder.start(device: device) { samples.append($0) }
                self.phase = .recording
                let recordingStarted = ContinuousClock.now
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.token == token else { return }
                        self.elapsed = Int(recordingStarted.duration(to: .now).components.seconds)
                        self.inputLevels = Array(self.inputLevels.dropFirst()) + [samples.inputLevel]
                        if self.elapsed >= 600 { self.stop(models: models); return }
                    }
                }
                self.preview = Task { [weak self] in
                    var offset = 0
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            guard let self, self.token == token, self.phase == .recording else { return }
                            guard self.preferences.showDictationPopup, !external else { continue }
                            let audio = samples.snapshot(from: offset, limit: 30 * 16000)
                            guard audio.count >= 16000, !models.busy else { continue }
                            let text = try await models.transcribe(audio, modelID: modelID, language: rule.action?.transcriptionLanguage)
                            guard !Task.isCancelled else { return }
                            if self.token == token && self.phase == .recording {
                                let complete = audio.count == 30 * 16000
                                self.updatePreview(text, completingWindow: complete)
                                if complete { offset += audio.count }
                            }
                        } catch { if Task.isCancelled { return } }
                    }
                }
            } catch { self.fail(error, token: token) }
        }
    }

    func stop(models: LocalModels) {
        guard let token, let rule = activeRule else { return }
        if phase == .preparing { stopRequested = true; return }
        guard phase == .recording else { return }
        recorder?.stop(); recorder = nil
        outputMute.restore()
        ticker?.cancel(); ticker = nil
        let previous = preview; previous?.cancel(); preview = nil
        let audio = samples.snapshot(); samples.clear()
        phase = .transcribing; hint = "Esc to cancel"
        let modelID = rule.action?.audioModelID ?? preferences.audioModelID
        work = Task { [weak self] in
            await previous?.value
            guard let self, self.token == token, !Task.isCancelled else { return }
            do {
                guard audio.count >= 3200 else { throw FrogError.message("No speech recorded. Hold the shortcut longer, or use toggle mode.") }
                let raw: String
                if rule.action?.audioProviderID != nil {
                    guard let transcribe = self.externalTranscription else { throw FrogError.message("External speech is unavailable.") }
                    raw = try await transcribe(audio, rule)
                } else { raw = try await models.transcribe(audio, modelID: modelID, language: rule.action?.transcriptionLanguage) }
                try Task.checkCancellation()
                guard self.token == token else { return }
                guard !raw.isEmpty else { throw FrogError.message("No speech detected.") }
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
                self.onTranscript?(rule, raw, output)
                self.copy(output)
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
        token = nil; work?.cancel(); preview?.cancel(); ticker?.cancel()
        work = nil; preview = nil; ticker = nil
        recorder?.stop(); recorder = nil; samples.clear()
        outputMute.restore()
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
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }; return event
        }
    }
    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 212), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: DictationPopup(controller: self))
            self.panel = panel
        }
        if let screen = NSScreen.main { panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.minY + 24)) }
        panel?.orderFrontRegardless()
    }
}

private struct DictationPopup: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: controller.phase == .recording ? "mic.fill" : "waveform").foregroundStyle(FrogStyle.accent)
                Text(L10n.text(controller.phase.rawValue.capitalized)).font(.system(size: 12, weight: .semibold))
                Spacer(); Text("\(controller.elapsed)s").monospacedDigit().foregroundStyle(.secondary)
                if controller.phase == .recording {
                    Button { controller.requestStop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Stop recording").accessibilityLabel("Stop recording")
                }
                Button { controller.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel dictation")
            }
            if controller.phase == .recording {
                MicrophoneWaveform(levels: controller.inputLevels).frame(height: 24)
            }
            ScrollViewReader { reader in
                ScrollView {
                    Text(controller.liveText.isEmpty ? L10n.text(controller.phase == .recording ? "Listening…" : controller.phase == .preparing ? "Starting microphone…" : "Processing audio…") : controller.liveText)
                        .font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("transcript-end")
                }.onChange(of: controller.liveText) { _, _ in reader.scrollTo("transcript-end", anchor: .bottom) }
            }
            Text(controller.hint).font(.system(size: 9)).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(width: 400, height: 212)
            .environment(\.locale, L10n.locale)
            .foregroundStyle(FrogStyle.ink)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
    }
}

private struct MicrophoneWaveform: View {
    let levels: [Double]
    var body: some View {
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
    private var lastInput = ContinuousClock.now
    var inputLevel: Double {
        lock.lock(); defer { lock.unlock() }
        return lastInput.duration(to: .now) < .milliseconds(300) ? level : 0
    }
    func append(_ buffer: [Float]) {
        lock.lock(); defer { lock.unlock() }
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
    func clear() { lock.lock(); defer { lock.unlock() }; samples = []; level = 0 }
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
