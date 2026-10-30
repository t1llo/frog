import AppKit
import AVFoundation
import SwiftUI
import Darwin
import XCTest
import FrogCore
@testable import FrogApp

extension AppModel {
    /// Dictation wired as its plugin wires it, made at once so a test can still replace the controller's callbacks.
    @discardableResult
    func attachDictation() -> DictationFeature {
        if let dictationFeature { return dictationFeature }
        let controller = injectedDictationController ?? DictationController(monitorKeys: false, presentsPopup: false)
        let feature = DictationFeature(model: self, controller: controller, settings: DictationSettings()) { [unowned self] in
            try? self.settingsFile.update("dictation", $0)
        }
        dictationFeature = feature
        return feature
    }

    /// Records with `rule` as the page's Record button does.
    func startDictation(_ rule: Rule) { attachDictation().start(rule) }
}

@MainActor
final class DictationPluginTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    // MARK: Actions

    func testActionsRecordStopCancelAndReport() async throws {
        let fixture = try await Fixture(directory: directory())
        defer { fixture.model.shutdown() }
        let host = fixture.model.pluginHost
        await host.syncAndWait()
        XCTAssertNotNil(fixture.model.dictationFeature)

        let started = try await host.run("dictation.start", ActionInput(values: ["rule": "notes"], source: .agent))
        XCTAssertEqual(started.text, "Recording with Notes.")
        XCTAssertEqual(fixture.controller.phase, .recording)
        let status = try await host.run("dictation.status", ActionInput(source: .agent))
        XCTAssertTrue(status.json.contains("\"phase\" : \"recording\""), status.json)
        XCTAssertTrue(status.json.contains("\"rule\" : \"Notes\""), status.json)
        do { _ = try await host.run("dictation.start", ActionInput(source: .agent)); XCTFail("Already recording") }
        catch { XCTAssertEqual(error.localizedDescription, "Frog is already recording.") }

        let stopped = try await host.run("dictation.stop", ActionInput(source: .agent))
        XCTAssertEqual(stopped.text, "Heard 32000 samples.")
        XCTAssertTrue(stopped.json.contains("Heard 32000 samples."))
        XCTAssertEqual(fixture.copied, ["Heard 32000 samples."])
        XCTAssertEqual(fixture.controller.phase, .idle)

        let cancelled = try await host.run("dictation.cancel", ActionInput(source: .agent))
        XCTAssertEqual(cancelled.text, "Nothing is recording.")
        _ = try await host.run("dictation.toggle", ActionInput(source: .shortcut))
        XCTAssertEqual(fixture.controller.phase, .recording)
        _ = try await host.run("dictation.cancel", ActionInput(source: .commandBar))
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(fixture.copied.count, 1, "Cancelling delivers nothing")

        do { _ = try await host.run("dictation.start", ActionInput(values: ["rule": "Lecture"], source: .agent)); XCTFail("No such rule") }
        catch { XCTAssertEqual(error.localizedDescription, "No dictation rule named “Lecture”. Rules: Notes.") }
    }

    func testMicrophonesAreListedAndChosenByIDOrName() async throws {
        let fixture = try await Fixture(directory: directory())
        defer { fixture.model.shutdown() }
        let host = fixture.model.pluginHost
        await host.syncAndWait()
        let listed = try await host.run("dictation.microphones", ActionInput(source: .agent))
        XCTAssertEqual(listed.text, "* default  System default\n  desk  Desk microphone\n  usb  USB headset")
        XCTAssertTrue(listed.json.contains("\"id\" : \"usb\""))

        _ = try await host.run("dictation.microphone", ActionInput(values: ["id": "usb headset"], source: .agent))
        XCTAssertEqual(fixture.model.dictationFeature?.settings.microphone, "usb")
        XCTAssertEqual(try savedSettings(fixture.model).microphone, "usb")
        _ = try await host.run("dictation.microphone", ActionInput(values: ["id": "default"], source: .agent))
        XCTAssertNil(try savedSettings(fixture.model).microphone)
        do { _ = try await host.run("dictation.microphone", ActionInput(values: ["id": "Studio"], source: .agent)); XCTFail("Unknown microphone") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("No microphone “Studio”")) }
        do { _ = try await host.run("dictation.microphone", ActionInput(source: .agent)); XCTFail("Missing id") }
        catch { XCTAssertEqual(error.localizedDescription, "Missing --id.") }
    }

    func testAnAudioFileIsTranscribedInTheWindowsARecordingUses() async throws {
        let fixture = try await Fixture(directory: directory())
        defer { fixture.model.shutdown() }
        await fixture.model.pluginHost.syncAndWait()
        // Three seconds of 44.1 kHz stereo become 48,000 samples at 16 kHz mono.
        let url = fixture.directory.appendingPathComponent("speech.wav")
        try writeTone(to: url, seconds: 3, sampleRate: 44_100, channels: 2)
        XCTAssertEqual(Double(try DictationFeature.samples(from: url).count), 48_000, accuracy: 16)

        let result = try await fixture.model.pluginHost.run("dictation.transcribe", ActionInput(values: ["file": url.path], source: .agent))
        XCTAssertTrue(result.text.hasPrefix("Heard "), result.text)
        XCTAssertTrue(fixture.copied.isEmpty, "A file's transcript is the action's answer, not the clipboard's")
        do {
            _ = try await fixture.model.pluginHost.run("dictation.transcribe", ActionInput(values: ["file": fixture.directory.appendingPathComponent("none.wav").path], source: .agent))
            XCTFail("No file")
        } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("No file at")) }
        do {
            _ = try await fixture.model.pluginHost.run("dictation.transcribe", ActionInput(values: ["file": url.path, "language": "xx"], source: .agent))
            XCTFail("Unknown language")
        } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("--language takes one of")) }
    }

    // MARK: Off and on

    func testOffMeansNoFeatureNoActionsAndNoModel() async throws {
        let fixture = try await Fixture(directory: directory())
        defer { fixture.model.shutdown() }
        let host = fixture.model.pluginHost
        await host.syncAndWait()
        weak var feature = fixture.model.dictationFeature
        XCTAssertNotNil(feature)
        _ = try await host.run("dictation.start", ActionInput(source: .agent))
        XCTAssertFalse(fixture.models.loaded.isEmpty, "Recording holds its speech model")

        try await host.setEnabled("dictation", false)
        XCTAssertNil(fixture.model.dictationFeature)
        XCTAssertNil(feature, "Nothing keeps the feature once the plugin stops")
        XCTAssertEqual(fixture.controller.phase, .idle, "Turning Dictation off ends a recording")
        XCTAssertTrue(fixture.recorders.allSatisfy(\.stopped), "and closes the microphone")
        XCTAssertNil(host.action("dictation.start"))
        do { _ = try await host.run("dictation.start", ActionInput(source: .agent)); XCTFail("Plugin off") }
        catch { XCTAssertEqual(error.localizedDescription, ActionError.pluginOff("Dictation").localizedDescription) }

        try await host.setEnabled("dictation", true)
        XCTAssertNotNil(fixture.model.dictationFeature)
        XCTAssertNotNil(host.action("dictation.start"))
    }

    /// Resident memory of Frog's own process with Dictation off, on and idle, and on after a recording.
    func testMemoryWithDictationOffAndOn() async throws {
        let directory = directory()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        try await model.pluginHost.setEnabled("dictation", false)
        await model.pluginHost.syncAndWait()
        let off = footprint()
        try await model.pluginHost.setEnabled("dictation", true)
        let on = footprint()
        XCTAssertNotNil(model.dictationFeature)
        XCTAssertNil(model.dictation?.microphones.first, "An idle Dictation asks Core Audio nothing")
        print("Dictation memory: off \(off / 1024) KB, on \(on / 1024) KB, difference \((Int64(on) - Int64(off)) / 1024) KB")
        // Turning it on creates a controller and its wiring, not an audio engine or a model.
        XCTAssertLessThan(Int64(on) - Int64(off), 8 * 1024 * 1024)
    }

    // MARK: Latency

    /// From releasing a hold shortcut to the transcript on the clipboard, with a transcriber that answers at once:
    /// what Frog itself adds to the model's own time.
    func testReleaseToTextLatency() async throws {
        let fixture = try await Fixture(directory: directory(), seconds: 5)
        defer { fixture.model.shutdown() }
        await fixture.model.pluginHost.syncAndWait()
        let feature = try XCTUnwrap(fixture.model.dictationFeature)
        var rule = fixture.rule
        rule.action?.recordingMode = .hold
        try await fixture.models.prepare("whisper-base")
        var timings: [Duration] = []
        for _ in 0..<5 {
            feature.handleShortcut(rule, pressed: true)
            await fixture.controller.waitForWork()
            XCTAssertEqual(fixture.controller.phase, .recording)
            var copiedAt: ContinuousClock.Instant?
            fixture.afterCopy = { copiedAt = .now }
            let released = ContinuousClock.now
            feature.handleShortcut(rule, pressed: false)
            await fixture.controller.waitForWork()
            timings.append(released.duration(to: try XCTUnwrap(copiedAt)))
        }
        let sorted = timings.sorted()
        print("Dictation release to text: median \(sorted[2]), worst \(sorted[4]) over 5 recordings of 5 s")
        XCTAssertEqual(fixture.copied.count, 5)
        XCTAssertLessThan(sorted[2], .milliseconds(50))
    }

    // MARK: Settings

    func testSettingsAreSeededOnceFromThePreferencesFrogKeptBefore() async throws {
        let directory = directory()
        let cancel = Hotkey(keyCode: 2, modifiers: 0x1000 | 0x800)
        do {
            let model = AppModel(dataDirectory: directory, registerShortcuts: false)
            var preferences = model.configuration.preferences.workflowSettings
            preferences.microphoneID = "desk"; preferences.muteWhileRecording = true; preferences.cancelRecordingHotkey = cancel
            try model.saveWorkflowPreferences(preferences)
            model.shutdown()
        }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        XCTAssertNil(model.settingsFile.document.value(at: ["dictation"]))
        await model.pluginHost.syncAndWait()
        let seeded = try savedSettings(model)
        XCTAssertEqual(seeded.microphone, "desk")
        XCTAssertTrue(seeded.muteAudio)
        XCTAssertEqual(seeded.cancelShortcut?.hotkey, cancel)
        XCTAssertEqual(model.dictationFeature?.settings, seeded)
        let text = try String(contentsOf: model.settingsFile.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[dictation]"), text)
        XCTAssertTrue(text.contains("mute-audio = true"), text)
        XCTAssertTrue(text.contains("cancel-shortcut = \"ctrl+alt+d\""), text)

        // An edit in the file reaches the running plugin, and a restart does not seed again.
        var edited = seeded; edited.microphone = nil; edited.muteAudio = false
        try model.settingsFile.update("dictation", edited)
        model.pluginHost.settingsChanged()
        XCTAssertEqual(model.dictationFeature?.settings, edited)
        try await model.pluginHost.setEnabled("dictation", false)
        try await model.pluginHost.setEnabled("dictation", true)
        XCTAssertEqual(try savedSettings(model), edited)
        XCTAssertEqual(model.dictationFeature?.settings, edited)
    }

    func testCleanupGoesThroughTheChosenWritingRule() async throws {
        let fixture = try await Fixture(directory: directory())
        defer { fixture.model.shutdown() }
        await fixture.model.pluginHost.syncAndWait()
        let feature = try XCTUnwrap(fixture.model.dictationFeature)
        var writing = Rule(name: "Polish", instructions: "Polish this.")
        writing.action = RuleAction(category: .text)
        try fixture.model.saveRule(writing)
        var rule = fixture.rule
        XCTAssertNil(feature.cleanupRule(for: rule))
        CleanupChoice.rule(writing.id).apply(to: &rule)
        XCTAssertEqual(feature.cleanupRule(for: rule)?.id, writing.id)
        CleanupChoice.own.apply(to: &rule)
        XCTAssertEqual(feature.cleanupRule(for: rule)?.id, rule.id, "A rule with its own instructions cleans up with them")
        CleanupChoice.off.apply(to: &rule)
        XCTAssertNil(feature.cleanupRule(for: rule))
        XCTAssertEqual(rule.action?.cleanup, false)
    }

    // MARK: Page

    /// The Dictation page with two rules, one cleaning up through a Writing rule. Runs only with `FROG_PAGE_SHOTS`.
    func testPageShots() async throws {
        guard let folder = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] else {
            throw XCTSkip("Set FROG_PAGE_SHOTS to a folder to take these pictures")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let fixture = try await Fixture(directory: directory())
        defer { fixture.model.shutdown() }
        var writing = Rule(name: "Polish", instructions: "Fix grammar and punctuation.")
        writing.action = RuleAction(category: .text)
        try fixture.model.saveRule(writing)
        var notes = fixture.rule
        notes.hotkey = Hotkey(keyCode: 49, modifiers: 0x1000 | 0x800); notes.action?.recordingMode = .hold
        CleanupChoice.rule(writing.id).apply(to: &notes); notes.action?.output = .paste
        try fixture.model.saveRule(notes)
        var meeting = Rule.dictationPreset
        meeting.id = UUID(); meeting.preset = false; meeting.name = "Meeting notes"; meeting.hotkey = nil
        meeting.action?.audioModelID = "whisper-base"; meeting.action?.transcriptionLanguage = "de"; meeting.enabled = false
        try fixture.model.saveRule(meeting)
        await fixture.model.pluginHost.syncAndWait()
        fixture.model.toolkit.select(.feature(.dictation))
        let tall = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS_TALL"] != nil
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            let height: CGFloat = tall ? 1_400 : 760
            let host = NSHostingView(rootView: MainView().environmentObject(fixture.model).frame(width: 1_000, height: height)
                .background(FrogStyle.opaqueCanvas))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 1_000, height: height)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "\(folder)/dictation-rules-\(name).png"))
        }
    }

    // MARK: Fixture

    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(value); return value
    }

    private func savedSettings(_ model: AppModel) throws -> DictationSettings {
        let file = ConfigStore(fileURL: model.settingsFile.fileURL)
        try file.load()
        return try file.section("dictation", as: DictationSettings.self).value
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func writeTone(to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.3 }
        }
        try file.write(from: buffer)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let models: LocalModels
        let controller: DictationController
        let model: AppModel
        let rule: Rule
        var copied: [String] = []
        var recorders: [ToneRecording] = []
        var afterCopy: (() -> Void)?

        init(directory: URL, seconds: Int = 2) async throws {
            self.directory = directory
            models = LocalModels(directory: directory, runtime: EchoSpeech(), downloader: { _, base, _ in
                let url = base.appendingPathComponent("fixture")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }, freeSpace: LocalModels.unlimitedFreeSpace)
            let descriptor = try XCTUnwrap(LocalModelDescriptor.find("whisper-base"))
            models.download(descriptor); await models.waitForDownload(descriptor.id)
            var copy: (String) -> Void = { _ in }
            var record: () -> ToneRecording = { ToneRecording(seconds: seconds) }
            controller = DictationController(makeRecorder: { record() }, authorize: { true }, copy: { copy($0) }, monitorKeys: false,
                                             previewInterval: .seconds(3600),
                                             inputDevices: { [MicrophoneDevice(uid: "desk", name: "Desk microphone"),
                                                              MicrophoneDevice(uid: "usb", name: "USB headset")] },
                                             presentsPopup: false)
            model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller, modelService: models)
            var rule = Rule.dictationPreset
            rule.id = UUID(); rule.preset = false; rule.name = "Notes"; rule.hotkey = nil
            rule.action?.audioModelID = descriptor.id; rule.action?.audioProviderID = nil
            rule.action?.showRecordingPopup = false; rule.action?.output = .copy; rule.action?.cleanup = false
            try model.saveRule(rule)
            self.rule = rule
            copy = { [unowned self] in copied.append($0); afterCopy?() }
            record = { [unowned self] in let recorder = ToneRecording(seconds: seconds); recorders.append(recorder); return recorder }
        }
    }
}

@MainActor
private final class ToneRecording: DictationRecording {
    private let seconds: Int
    private(set) var stopped = false
    init(seconds: Int) { self.seconds = seconds }
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        samples(Array(repeating: 0.1, count: seconds * 16000))
    }
    func stop() { stopped = true }
}

/// A speech model that answers at once with how much it heard.
private actor EchoSpeech: LocalInferenceEngine {
    var loadedIDs: Set<String> = []
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
        loadedIDs.insert(model.id); await residency(loadedIDs)
    }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(model.id); await residency(loadedIDs)
        return "Heard \(samples.count) samples."
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        "Cleaned: \(text)"
    }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}
