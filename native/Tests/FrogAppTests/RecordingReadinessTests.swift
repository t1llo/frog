import XCTest
import AppKit
import FrogCore
@testable import FrogApp

@MainActor
final class RecordingReadinessTests: XCTestCase {
    func testColdSpeechModelLoadsBeforeRecording() async throws {
        try await checkReadiness(pausing: "whisper-base", cleanup: false)
    }

    func testColdCleanupModelAlsoLoadsBeforeRecording() async throws {
        try await checkReadiness(pausing: "qwen-0.6b", cleanup: true)
    }

    func testReleasingHoldDuringPreparationCancelsBeforeMicrophoneStarts() async throws {
        try await checkReadiness(pausing: "whisper-base", cleanup: false, cancel: true)
    }

    func testPreparationFailureLeavesMicrophoneClosedAndReportsError() async throws {
        try await checkReadiness(pausing: "qwen-0.6b", cleanup: true, fail: true)
    }

    func testNativePopupTransitionsFromLoadingThroughSpeechAndCleanup() async throws {
        try await checkNativePopup(includePreview: true)
    }

    func testNativePopupWithoutPreviewReturnsToCompactTranscribingFeedback() async throws {
        try await checkNativePopup(includePreview: false)
    }

    private func checkNativePopup(includePreview: Bool) async throws {
        _ = NSApplication.shared
        let prefix = includePreview ? "" : "no-preview-"
        var expectedTranscript = "Transcript"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = expectation(description: "Speech model loading")
        ready.assertForOverFulfill = false
        let transcribing = expectation(description: "Transcribing captured fixture")
        let engine = ReadinessInference(pausing: "whisper-base", checkpoint: ready, fail: false, transcriptionCheckpoint: transcribing)
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let folder = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        })
        models.download(try XCTUnwrap(LocalModelDescriptor.find("whisper-base")))
        await models.waitForDownload("whisper-base")
        let recorder = ReadinessRecorder(checkpoint: ready)
        var copied = ""
        let controller = DictationController(makeRecorder: { recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600), inputDevices: { [] })
        defer { controller.cancel() }
        let correcting = expectation(description: "Cleaning transcript")
        var finishCleanup: CheckedContinuation<Void, Never>?
        controller.cleanup = { text, _ in
            await withCheckedContinuation { finishCleanup = $0; correcting.fulfill() }
            return text
        }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"; rule.action?.showRecordingPopup = true
        rule.action?.cleanup = true; rule.action?.localTextModelID = nil; rule.action?.output = .copy
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await fulfillment(of: [ready], timeout: 2)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "Dictation" })
        XCTAssertEqual(panel.frame.size, NSSize(width: 300, height: 50))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(recorder.starts, 0)
        try await capture(panel, name: prefix + "preparing")
        let anchor = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        await engine.resume(); await controller.waitForWork()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(panel.frame.size, NSSize(width: 360, height: 108))
        XCTAssertEqual(panel.frame.midX, anchor.x, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, anchor.y, accuracy: 1)
        for index in 0..<40 {
            let syllable = max(0, sin(Double(index) * 0.6))
            recorder.emit(rms: 0.03 * syllable)
            controller.refreshRecordingFeedback(elapsed: 0)
        }
        try await capture(panel, name: prefix + "recording", settle: false)
        if includePreview {
            controller.updatePreview("Let's review the proposal tomorrow morning.")
            try await capture(panel, name: "short-transcript")
            let shortHeight = panel.frame.height
            controller.updatePreview(String(repeating: "We can review the proposal tomorrow morning and share our notes with the team. ", count: 12))
            try await capture(panel, name: "long-transcript")
            XCTAssertGreaterThan(panel.frame.height, shortHeight)
            XCTAssertLessThanOrEqual(panel.frame.height, 220)
            expectedTranscript = (0..<2000).map { "Line \($0): 日本語 café e\u{301} 👩🏽‍💻 مرحبا — complete spoken words." }.joined(separator: "\n")
            controller.updatePreview(expectedTranscript)
            try await capture(panel, name: "huge-transcript")
            let maximumHeight = panel.frame.height
            expectedTranscript += "\nThe latest spoken words: 最新👩🏽‍💻e\u{301}"
            controller.updatePreview(expectedTranscript)
            try await capture(panel, name: "newest-unicode-transcript")
            XCTAssertEqual(panel.frame.height, maximumHeight)
            XCTAssertLessThanOrEqual(panel.frame.height, 220)
            let viewport = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? DictationTranscriptViewport }.first)
            XCTAssertLessThanOrEqual(viewport.frame.height, 104)
            XCTAssertTrue(expectedTranscript.hasSuffix(viewport.transcriptView.string))
            XCTAssertLessThanOrEqual(viewport.transcriptView.string.count, 2048, "Only the presentation is bounded; native glyph layout must not grow with the full transcript")
            try assertNewestVisible(in: viewport, suffix: "最新👩🏽‍💻e\u{301}")
            XCTAssertEqual(controller.liveText, expectedTranscript, "The bounded presentation never trims the delivery transcript")
            await engine.setTranscript(expectedTranscript)
        }
        controller.requestStop()
        await fulfillment(of: [transcribing], timeout: 2)
        try await capture(panel, name: prefix + "transcribing")
        XCTAssertEqual(controller.phase, .transcribing)
        XCTAssertEqual(panel.frame.size, NSSize(width: 300, height: 50), "Finished recording must collapse to clear processing feedback")
        await engine.resume()
        await fulfillment(of: [correcting], timeout: 2)
        try await capture(panel, name: prefix + "correcting")
        XCTAssertEqual(controller.phase, .correcting)
        XCTAssertEqual(panel.frame.size, NSSize(width: 300, height: 50))
        finishCleanup?.resume()
        await controller.waitForWork()
        XCTAssertEqual(copied, expectedTranscript)
        XCTAssertFalse(panel.isVisible)
        await models.unload()
    }

    func testTranscriptTailRemainsVisibleInSmallScreenViewport() throws {
        _ = NSApplication.shared
        let viewport = DictationTranscriptViewport()
        viewport.frame = NSRect(x: 0, y: 0, width: 230, height: 32)
        let text = String(repeating: "Older words 日本語 👩🏽‍💻\n", count: 2000) + "Newest: 最新👩🏽‍💻e\u{301}"
        viewport.setTranscript(text)
        viewport.layoutSubtreeIfNeeded()
        try assertNewestVisible(in: viewport, suffix: "最新👩🏽‍💻e\u{301}")
        viewport.setFrameSize(NSSize(width: 180, height: 22))
        viewport.layoutSubtreeIfNeeded()
        try assertNewestVisible(in: viewport, suffix: "最新👩🏽‍💻e\u{301}")
        XCTAssertTrue(text.hasSuffix(viewport.transcriptView.string))
        XCTAssertLessThanOrEqual(viewport.transcriptView.string.count, 2048)
        let screen = NSRect(x: -300, y: -200, width: 250, height: 180)
        let panel = DictationPopupLayout.frame(phase: .recording, text: text, visibleFrame: screen)
        XCTAssertTrue(screen.contains(panel))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func assertNewestVisible(in viewport: DictationTranscriptViewport, suffix: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = viewport.transcriptView
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let range = (text.string as NSString).range(of: suffix, options: .backwards)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertTrue(viewport.documentVisibleRect.intersects(bounds), "The newest Unicode glyphs must actually be in the viewport", file: file, line: line)
        XCTAssertLessThanOrEqual(bounds.maxY, viewport.documentVisibleRect.maxY + 1, file: file, line: line)
    }

    private func capture(_ panel: NSWindow, name: String, settle: Bool = true) async throws {
        try await Task.sleep(for: .milliseconds(settle ? 300 : 30))
        guard let path = ProcessInfo.processInfo.environment["FROG_TEST_DICTATION_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = try XCTUnwrap(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func checkReadiness(pausing id: String, cleanup: Bool, cancel: Bool = false, fail: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = expectation(description: "Preparation or premature microphone start")
        checkpoint.assertForOverFulfill = false
        let engine = ReadinessInference(pausing: id, checkpoint: checkpoint, fail: fail)
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let folder = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        })
        let ids = cleanup ? ["whisper-base", "qwen-0.6b"] : ["whisper-base"]
        for id in ["whisper-base", "qwen-0.6b"] {
            models.download(try XCTUnwrap(LocalModelDescriptor.find(id)))
            await models.waitForDownload(id)
        }
        let recorder = ReadinessRecorder(checkpoint: checkpoint)
        let controller = DictationController(makeRecorder: { recorder }, authorize: { true }, copy: { _ in }, monitorKeys: false)
        var issue: Error?
        controller.onError = { issue = $0 }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"; rule.action?.showRecordingPopup = false
        rule.action?.cleanup = cleanup; rule.action?.localTextModelID = "qwen-0.6b"
        rule.action?.recordingMode = .hold
        models.idleSeconds = 0
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        let completion = Task { await controller.waitForWork() }
        await fulfillment(of: [checkpoint], timeout: 2)
        XCTAssertEqual(recorder.starts, 0, "The microphone must stay closed while a required model is loading")
        XCTAssertEqual(controller.phase, .preparing)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertFalse(controller.noMicrophoneInput)
        XCTAssertEqual(controller.preparationMessage, id == "whisper-base" ? "Loading speech model…" : "Loading cleanup model…")
        if cancel { controller.requestStop(); XCTAssertEqual(controller.phase, .idle) }
        await engine.resume()
        await completion.value
        if cancel || fail {
            XCTAssertEqual(recorder.starts, 0)
            XCTAssertEqual(controller.phase, .idle)
            XCTAssertEqual(issue != nil, fail)
        } else {
            await models.unload()
            await models.waitForIdleUnload()
            XCTAssertEqual(models.loaded, Set(ids), "Only required models should be prepared, and remain resident during recording")
            XCTAssertEqual(recorder.starts, 1)
            XCTAssertEqual(controller.phase, .recording)
            XCTAssertNil(issue)
        }
        controller.cancel(); await models.waitForIdleUnload()
        XCTAssertTrue(models.loaded.isEmpty, "Idle unloading resumes after the session ends")
    }
}

@MainActor
private final class ReadinessRecorder: DictationRecording {
    private let checkpoint: XCTestExpectation
    private var receive: (@Sendable ([Float]) -> Void)?
    var starts = 0
    init(checkpoint: XCTestExpectation) { self.checkpoint = checkpoint }
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        starts += 1; receive = samples; checkpoint.fulfill()
    }
    func stop() { receive = nil }
    func emit(rms: Double) {
        receive?((0..<1600).map { Float(sqrt(2) * rms * sin(2 * .pi * 200 * Double($0) / 16000)) })
    }
}

private actor ReadinessInference: LocalInferenceEngine {
    var loadedIDs = Set<String>()
    private let pausing: String
    private let checkpoint: XCTestExpectation
    private let fail: Bool
    private let transcriptionCheckpoint: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var transcript = "Transcript"
    init(pausing: String, checkpoint: XCTestExpectation, fail: Bool, transcriptionCheckpoint: XCTestExpectation? = nil) {
        self.pausing = pausing; self.checkpoint = checkpoint; self.fail = fail
        self.transcriptionCheckpoint = transcriptionCheckpoint
    }
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
        if model.id == pausing { await withCheckedContinuation { continuation = $0; checkpoint.fulfill() } }
        try Task.checkCancellation()
        if fail && model.id == pausing { throw FrogError.message("Fixture model could not load") }
        loadedIDs.insert(model.id); await residency(loadedIDs)
    }
    func resume() { continuation?.resume(); continuation = nil }
    func setTranscript(_ text: String) { transcript = text }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        if let transcriptionCheckpoint { await withCheckedContinuation { continuation = $0; transcriptionCheckpoint.fulfill() } }
        return transcript
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}
