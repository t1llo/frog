import XCTest
import FrogCore
@testable import FrogApp

/// Every other test replaces the downloader and the inference engine with
/// fixtures. This one runs the real ones: it fetches the smallest Whisper and
/// text models from Hugging Face (about 480 MB) into a temporary folder, loads
/// them with WhisperKit and MLX and runs each once. It therefore runs only on
/// request, on a Mac with Apple silicon:
///
///     FROG_RUN_MODEL_TESTS=1 swift test --filter RealModelTests
///
/// Run it after changing the version of WhisperKit, mlx-swift-lm or
/// swift-transformers. Parakeet is left out to keep the download small.
@MainActor
final class RealModelTests: XCTestCase {
    func testSmallestSpeechAndTextModelsDownloadLoadAndRun() async throws {
        guard ProcessInfo.processInfo.environment["FROG_RUN_MODEL_TESTS"] == "1" else { throw XCTSkip("Opt-in: downloads and runs real models") }
        guard LocalModels.supported else { throw XCTSkip("Built-in local models require Apple silicon") }
        // Its own storage root: never the model folder of an installed Frog.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        let speech = try XCTUnwrap(LocalModelDescriptor.find("whisper-tiny"))
        let text = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        for model in [speech, text] {
            models.download(model); await models.waitForDownload(model.id)
            // A failed download ends the test before the next one is fetched.
            guard models.installed.contains(model.id) else { return XCTFail("\(model.name): \(models.errors[model.id] ?? "not installed")") }
            XCTAssertNil(models.errors[model.id])
        }
        XCTAssertTrue(models.unfinished.isEmpty)

        // One second of a 440 Hz tone at 16 kHz. It holds no words, so any text
        // counts, none included: the model has to load and decode without failing.
        let tone = (0..<16000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16000)) * 0.2 }
        _ = try await models.transcribe(tone, modelID: speech.id)
        XCTAssertEqual(models.loaded, [speech.id])

        let corrected = try await models.complete("helo wrold", instructions: "Correct the spelling. Return only the corrected text.", modelID: text.id)
        XCTAssertFalse(corrected.isEmpty)
        XCTAssertEqual(models.loaded, [speech.id, text.id])

        await models.unload()
        XCTAssertTrue(models.loaded.isEmpty)
    }
}
