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
    private var target: DictationTarget?
    private var activeRule: Rule?
    private var preferences = WorkflowPreferences()
    private weak var models: LocalModels?
    var onFinish: ((Rule, String, String, String) -> Void)?
    var onError: ((Error) -> Void)?
    var cleanup: ((String, Rule) async throws -> String)?
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
        let modelID = rule.action?.audioModelID ?? preferences.audioModelID
        guard models.installed.contains(modelID) else { onError?(FrogError.message("Download an audio model in Models → Inside Frog first.")); return }
        let token = UUID(); self.token = token
        self.preferences = preferences; self.models = models; activeRule = rule; ruleID = rule.id
        stopRequested = false; samples = AudioSamples(); liveText = ""; elapsed = 0
        target = (rule.action?.output ?? preferences.output) == .paste ? DictationTarget.capture() : nil
        phase = .preparing
        let shortcut = rule.hotkey.map(HotkeyManager.display) ?? "Stop button"
        hint = (rule.action?.recordingMode ?? preferences.recordingMode) == .hold ? "Release \(shortcut) to stop · Esc to cancel" : "\(shortcut) to stop · Esc to cancel"
        if rule.hotkey == nil { hint = "Stop to finish · Esc to cancel" }
        if preferences.showDictationPopup { showPanel() }
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
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, self.token == token else { return }
                        self.elapsed += 1
                        if self.elapsed >= 600 { self.stop(models: models); return }
                    }
                }
                self.preview = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            guard let self, self.token == token, self.phase == .recording else { return }
                            guard self.preferences.showDictationPopup else { continue }
                            let audio = samples.snapshot(last: 30 * 16000)
                            guard audio.count >= 16000, !models.busy else { continue }
                            let text = try await models.transcribe(audio, modelID: modelID, language: preferences.transcriptionLanguage)
                            if self.token == token && self.phase == .recording { self.liveText = text }
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
                let raw = try await models.transcribe(audio, modelID: modelID, language: self.preferences.transcriptionLanguage)
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
                self.copy(output)
                var insertion: (() async throws -> Void)?
                if (rule.action?.output ?? self.preferences.output) == .paste {
                    let target = self.target
                    insertion = {
                        guard let target else { throw FrogError.message("No editable insertion point was captured. The transcript is copied.") }
                        try await target.paste()
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
        target = nil; activeRule = nil; ruleID = nil; phase = .idle
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
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 88), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: DictationPopup(controller: self))
            self.panel = panel
        }
        if let screen = NSScreen.main { panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.minY + 24)) }
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
            Text(controller.liveText.isEmpty ? L10n.text(controller.phase == .recording ? "Listening…" : controller.phase == .preparing ? "Starting microphone…" : "Processing audio…") : controller.liveText)
                .font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(controller.hint).font(.system(size: 9)).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(width: 320, height: 88)
            .environment(\.locale, L10n.locale)
            .foregroundStyle(FrogStyle.ink)
            .background(FrogStyle.panelSurface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
    }
}

private final class AudioSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ buffer: [Float]) { lock.lock(); defer { lock.unlock() }; samples.append(contentsOf: buffer.prefix(max(0, 600 * 16000 - samples.count))) }
    func snapshot(last: Int? = nil) -> [Float] { lock.lock(); defer { lock.unlock() }; return last.map { Array(samples.suffix($0)) } ?? samples }
    func clear() { lock.lock(); defer { lock.unlock() }; samples = [] }
}

@MainActor
private struct DictationTarget {
    let pid: pid_t
    let element: AXUIElement
    let range: CFRange
    let value: String?
    static func capture() -> Self? {
        guard SelectionService.isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        guard let element = AXRead.element(ax, kAXFocusedUIElementAttribute),
              AXRead.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              let range = AXRead.range(element) else { return nil }
        return Self(pid: app.processIdentifier, element: element, range: range, value: AXRead.string(element, kAXValueAttribute))
    }
    func paste() async throws {
        try await ClipboardSelection.waitForShortcutRelease()
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = AXRead.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute), CFEqual(focused, element),
              let current = AXRead.range(element), current.location == range.location, current.length == range.length,
              AXRead.string(element, kAXValueAttribute) == value else {
            throw FrogError.message("The insertion point changed. Your transcript is copied instead.")
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
}
