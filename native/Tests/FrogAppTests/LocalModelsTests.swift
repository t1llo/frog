import XCTest
import FrogCore
#if arch(arm64)
import Hub
import MLX
import MLXLMCommon
#endif
@testable import FrogApp

@MainActor
final class LocalModelsTests: XCTestCase {
    func testPreparingAResidentModelRefreshesItsIdleDeadlineWithoutReloading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = try XCTUnwrap(LocalModelDescriptor.find("parakeet-v3"))
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        models.idleSeconds = 60
        try await models.prepare(descriptor.id)
        let waiting = expectation(description: "Waiting on the original idle deadline")
        let refreshed = expectation(description: "Original idle deadline cancelled")
        let originalDeadline = Task {
            waiting.fulfill()
            await models.waitForIdleUnload()
            refreshed.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        try await models.prepare(descriptor.id)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(models.loaded, [descriptor.id], "A successful readiness request counts as use, even when weights are already resident")
        let preparations = await engine.preparations
        XCTAssertEqual(preparations, 1)
        models.idleSeconds = 0
        await models.waitForIdleUnload()
        await originalDeadline.value
        XCTAssertTrue(models.loaded.isEmpty, "Readiness must extend the chosen interval, not disable idle unloading")
    }

    func testConcurrentReadinessRequestsSharePreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let engine = FixtureInference(preparationGate: gate)
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = try XCTUnwrap(LocalModelDescriptor.find("parakeet-v3"))
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let first = Task { try await models.prepare(descriptor.id) }
        await gate.waitUntilStarted()
        let second = Task { try await models.prepare(descriptor.id) }
        await Task.yield()
        await gate.resume()
        try await first.value
        try await second.value
        let preparations = await engine.preparations
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(models.loaded, [descriptor.id])
        await models.unload()
    }

    func testLegacySpeechDownloadsSurviveRestartAndKeepTheirOriginalRuntimeSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: Self.fixtureDownload)
        let ids = ["whisper-small", "whisper-large-v3-turbo", "parakeet-v2"]
        for id in ids {
            models.download(try XCTUnwrap(LocalModelDescriptor.find(id))); await models.waitForDownload(id)
        }
        let engine = FixtureInference()
        let restarted = LocalModels(directory: directory, runtime: engine)
        restarted.updateCatalog(Configuration().modelCatalog)
        XCTAssertEqual(restarted.installed, Set(ids))
        for id in ids {
            _ = try await restarted.transcribe([0.1], modelID: id)
            let source = await engine.lastSpeechModel
            XCTAssertEqual(source, LocalModelDescriptor.find(id))
        }
        await restarted.unload()
    }
    func testCustomSourceInstallsRescansAndReachesTheSpeechRuntimeWithItsLanguagePolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let repository = "fixture/whisperkit"
        let variant = "openai_whisper-tiny.en"
        let custom = LocalModelDescriptor(id: HuggingFaceSource.modelID(repository: repository, variant: variant, backend: .whisperKit), name: "English fixture", kind: .audio, repository: repository, variant: variant, size: "Fixture")
        var installations = 0
        models.onInstall = { XCTAssertEqual($0.id, custom.id); installations += 1 }
        models.updateCatalog(LocalModelDescriptor.catalog + [custom])
        models.download(custom); await models.waitForDownload(custom.id)
        XCTAssertEqual(installations, 1)
        let restarted = LocalModels(directory: directory, runtime: FixtureInference())
        restarted.updateCatalog(models.catalog)
        XCTAssertTrue(restarted.installed.contains(custom.id))
        _ = try await models.transcribe([0.1], modelID: custom.id, language: "de")
        let requestedModel = await engine.lastSpeechModel
        let requestedLanguage = await engine.lastLanguage
        XCTAssertEqual(requestedModel, custom)
        XCTAssertEqual(requestedLanguage, "en", "English-only models must not receive a conflicting global language hint")
        await models.unload()
    }
    func testChangingIdlePolicyToImmediateUnloadsAnAlreadyResidentModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        _ = try await models.complete("hello", instructions: "Correct", modelID: descriptor.id)
        models.idleSeconds = 0
        await models.waitForIdleUnload()
        XCTAssertTrue(models.loaded.isEmpty)
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, 1)
        models.shutdown()
    }
    func testResidencyIsVisibleDuringInferenceAndSurvivesInferenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let models = LocalModels(directory: directory, runtime: FixtureInference(gate: gate, fail: true), downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let request = Task { try await models.complete("hello", instructions: "Correct", modelID: descriptor.id) }
        await gate.waitUntilStarted()
        XCTAssertTrue(models.busy)
        XCTAssertEqual(models.loaded, [descriptor.id])
        await gate.resume()
        do { _ = try await request.value; XCTFail("Fixture should fail") } catch {}
        XCTAssertEqual(models.loaded, [descriptor.id])
        await models.unload()
        XCTAssertTrue(models.loaded.isEmpty)
    }
    func testTranscriptionThatWaitsQueuesBehindRunningWorkInsteadOfFailingBusy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let engine = FixtureInference(gate: gate)
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let text = LocalModelDescriptor.find("qwen-0.6b")!
        let speech = try XCTUnwrap(LocalModelDescriptor.find("parakeet-v3"))
        for model in [text, speech] { models.download(model); await models.waitForDownload(model.id) }
        let completion = Task { try await models.complete("corrected", instructions: "Correct", modelID: text.id) }
        await gate.waitUntilStarted()
        XCTAssertTrue(models.busy)

        // A live preview only tries: it skips a busy engine and comes back later.
        do { _ = try await models.transcribe([0.1], modelID: speech.id); XCTFail("A transcription that does not wait must not queue") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already processing"), error.localizedDescription) }
        let calls = await engine.calls
        XCTAssertEqual(calls, 1)

        // The transcript of a finished recording must come, however many are waiting.
        let transcripts = (0..<3).map { _ in Task { try await models.transcribe([0.1], modelID: speech.id, waiting: true) } }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(models.busy)
        await gate.resume()
        let corrected = try await completion.value
        XCTAssertEqual(corrected, "corrected")
        for transcript in transcripts {
            let heard = try await transcript.value
            XCTAssertEqual(heard, "hello")
        }
        XCTAssertFalse(models.busy)
        await models.unload()
    }
    func testChangingStoragePreservesOldDownloadsAndPersistsNewLocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let original = models.root
        try await models.changeDirectory(to: directory.appendingPathComponent("custom"))
        XCTAssertTrue(models.installed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent(descriptor.id).path))
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let restarted = LocalModels(directory: directory)
        XCTAssertEqual(restarted.root, models.root)
        XCTAssertTrue(restarted.installed.contains(descriptor.id))
        try await models.changeDirectory(to: original)
        XCTAssertTrue(models.installed.contains(descriptor.id))
    }
    func testChangingStorageDuringDownloadIsRejectedAndForeignFolderIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let models = LocalModels(directory: directory, downloader: { model, base, progress in
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await gate.waitUntilStarted()
        let original = models.root
        do { try await models.changeDirectory(to: directory.appendingPathComponent("custom")); XCTFail("Active download must keep its root") } catch {}
        XCTAssertEqual(models.root, original)
        models.cancelDownload(descriptor.id); await gate.resume(); await models.waitForDownload(descriptor.id)
        let existing = original.appendingPathComponent(descriptor.id)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("user-file"))
        models.download(descriptor)
        XCTAssertNotNil(models.errors[descriptor.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.appendingPathComponent("user-file").path))
    }
    func testInstalledModelSurvivesRestartAndIdleUnloadReleasesResidency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertTrue(models.installed.contains(descriptor.id))
        XCTAssertTrue(LocalModels(directory: directory).installed.contains(descriptor.id))
        models.idleSeconds = 0
        let output = try await models.complete("hello", instructions: "Correct", modelID: descriptor.id)
        XCTAssertEqual(output, "hello")
        await models.waitForIdleUnload()
        XCTAssertTrue(models.loaded.isEmpty)
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, 1)
        let cancelledUnload = await engine.cancelledUnload
        XCTAssertFalse(cancelledUnload, "The idle task must not cancel itself before native resources are released")
        try await models.remove(descriptor.id)
        XCTAssertFalse(models.installed.contains(descriptor.id))
    }

    func testMemoryPressureUnloadsAnIdleModelAtOnceButKeepsOneInUse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        _ = try await models.complete("hello", instructions: "Correct", modelID: descriptor.id)
        XCTAssertEqual(models.loaded, [descriptor.id], "The idle interval has two minutes left")

        let session = models.holdResidency()
        await models.relieveMemoryPressure()
        XCTAssertEqual(models.loaded, [descriptor.id], "A running session keeps its model")
        models.releaseResidency(session)

        await models.relieveMemoryPressure()
        XCTAssertTrue(models.loaded.isEmpty, "An idle model goes as soon as macOS reports that memory is short")
        await models.relieveMemoryPressure()
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, 1, "With nothing resident there is nothing to release")
    }

    func testDownloadWhoseFilesAreInSaysThatTheModelIsBeingPrepared() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        // Like a Whisper installation: the files arrive, then the model is loaded
        // once, which takes a while and has no fraction to report.
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { model, base, progress in
            progress(DownloadProgress(fraction: 0.5))
            await gate.wait()
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await gate.waitUntilStarted()
        for _ in 0..<1000 where models.progress[descriptor.id]?.fraction != 0.5 { await Task.yield() }
        XCTAssertEqual(models.progress[descriptor.id]?.fraction, 0.5)
        XCTAssertTrue(models.preparing.isEmpty, "Files are still arriving")

        await gate.resume(); await gate.waitUntilStarted()
        for _ in 0..<1000 where models.progress[descriptor.id]?.fraction != 1 { await Task.yield() }
        XCTAssertEqual(models.preparing, [descriptor.id], "A full bar that keeps standing still says nothing about what Frog is doing")

        await gate.resume(); await models.waitForDownload(descriptor.id)
        XCTAssertTrue(models.preparing.isEmpty)
        XCTAssertTrue(models.installed.contains(descriptor.id))
    }

    func testCancelledDownloadRemovesPartialFilesAndCannotInstallLateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let models = LocalModels(directory: directory, downloader: { model, base, progress in
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor)
        await gate.waitUntilStarted()
        models.cancelDownload(descriptor.id)
        await gate.resume()
        await models.waitForDownload(descriptor.id)
        XCTAssertFalse(models.installed.contains(descriptor.id))
        XCTAssertNil(models.progress[descriptor.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Models/\(descriptor.id)").path))
        XCTAssertTrue(models.unfinished.isEmpty)
    }

    func testDownloadInterruptedByQuittingCanBeStartedAgainAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        // The process ends inside the downloader: nothing after it gets to run.
        let quit = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { model, base, progress in
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        quit.download(descriptor); await gate.waitUntilStarted()
        let folder = directory.appendingPathComponent("Models/\(descriptor.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        let relaunched = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { model, base, progress in
            guard FileManager.default.fileExists(atPath: base.appendingPathComponent("fixture/weights").path) else { throw FrogError.message("The files fetched before the quit are gone") }
            return try await Self.fixtureDownload(model, base, progress)
        })
        XCTAssertFalse(relaunched.installed.contains(descriptor.id), "An unfinished folder is not an installation")
        XCTAssertEqual(relaunched.unfinished, [descriptor.id])
        relaunched.download(descriptor); await relaunched.waitForDownload(descriptor.id)
        XCTAssertNil(relaunched.errors[descriptor.id])
        XCTAssertTrue(relaunched.installed.contains(descriptor.id), "Frog's own unfinished folder must not block the model for good")
        XCTAssertTrue(relaunched.unfinished.isEmpty)
        XCTAssertTrue(LocalModels(directory: directory).installed.contains(descriptor.id))

        quit.shutdown(); await gate.resume(); await quit.waitForDownload(descriptor.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Quitting is not a Cancel: it keeps the files")
    }

    func testFailedDownloadKeepsItsFilesAndTheNextDownloadContinuesFromThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attempts = Attempts()
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { model, base, progress in
            let firstFile = base.appendingPathComponent("first-file")
            if await attempts.next() == 1 {
                try Data("fetched".utf8).write(to: firstFile)
                throw FrogError.message("The connection dropped")
            }
            guard FileManager.default.fileExists(atPath: firstFile.path) else { throw FrogError.message("The first file was thrown away") }
            return try await Self.fixtureDownload(model, base, progress)
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertEqual(models.errors[descriptor.id], "The connection dropped")
        XCTAssertFalse(models.installed.contains(descriptor.id))
        XCTAssertEqual(models.unfinished, [descriptor.id])
        XCTAssertFalse(LocalModels(directory: directory).installed.contains(descriptor.id), "Kept files are not an installation")

        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertNil(models.errors[descriptor.id])
        XCTAssertTrue(models.installed.contains(descriptor.id))
        XCTAssertTrue(models.unfinished.isEmpty)
    }

    func testDownloadFailuresSayWhatToDoInsteadOfQuotingTheLibrary() {
        let model = LocalModelDescriptor.find("qwen-1.7b")!
        func message(_ error: Error) -> String { LocalInference.downloadFailure(error, model: model) }
        let offline = message(URLError(.notConnectedToInternet))
        XCTAssertTrue(offline.contains("internet connection"), offline)
        XCTAssertEqual(message(URLError(.networkConnectionLost)), offline)
        for full in [message(CocoaError(.fileWriteOutOfSpace)), message(POSIXError(.ENOSPC))] {
            XCTAssertTrue(full.contains("disk space") && full.contains(model.name), full)
        }
        XCTAssertEqual(message(FrogError.message("Built-in local models require Apple silicon.")), "Built-in local models require Apple silicon.")
        let odd = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Odd failure"])
        XCTAssertEqual(message(odd), "Could not download \(model.name). Odd failure")
        #if arch(arm64)
        XCTAssertEqual(message(HubApi.EnvironmentError.offlineModeError("Repository not available locally")), offline)
        XCTAssertEqual(message(Hub.HubClientError.networkError(URLError(.timedOut))), offline)
        // What a download started offline throws: the file list is requested first,
        // and the hub client passes on only the text of the URL error behind it.
        let noConnection = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        XCTAssertEqual(message(Hub.HubClientError.downloadError(noConnection.localizedDescription)), offline)
        let gated = message(Hub.HubClientError.authorizationRequired)
        XCTAssertTrue(gated.contains(model.repository) && !gated.contains("token"), gated)
        XCTAssertTrue(message(Hub.HubClientError.fileNotFound("\(model.repository)@main/model.safetensors")).contains(model.repository))
        let limited = message(Hub.HubClientError.downloadError("Rate limited while downloading \(model.repository)@main/model.safetensors (https://example.invalid/model.safetensors -> /Volumes/Disk/Models/model.safetensors)"))
        XCTAssertTrue(limited.contains("few minutes"), limited)
        XCTAssertFalse(limited.contains("/Volumes") || limited.contains("https://"), "No paths or addresses of the library's making: \(limited)")
        XCTAssertEqual(message(Hub.HubClientError.httpStatusCode(429)), limited)
        #endif
    }

    #if arch(arm64)
    func testMLXAndParakeetDownloadsBypassTheSharedHuggingFaceCacheAndNeverRunOffline() throws {
        let client = HubApi.modelFolder(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        // Both settings are private to the pinned Hub package. If its layout changes
        // and these lookups find nothing, verify with one real download instead:
        // nothing may appear under the home folder's .cache/huggingface/hub.
        func setting(_ name: String, of value: Any) throws -> Mirror {
            Mirror(reflecting: try XCTUnwrap(Mirror(reflecting: value).children.first { $0.label == name }?.value, "\(name) is gone"))
        }
        let cache = try setting("cache", of: try XCTUnwrap(Mirror(reflecting: client).children.first { $0.label == "foregroundCachedClient" }?.value))
        XCTAssertEqual(cache.displayStyle, .optional)
        XCTAssertTrue(cache.children.isEmpty, "A shared cache keeps a second copy of every file that deleting the model never removes")
        let offline = try setting("useOfflineMode", of: client)
        XCTAssertEqual(offline.children.first?.value as? Bool, false, "Offline mode would accept an unfinished folder as complete")
    }
    #endif

    #if arch(arm64)
    func testLocalTextThatStoppedAtTheOutputLimitOrInsideItsReasoningIsNotAResult() throws {
        XCTAssertEqual(try LocalInference.textResult(" Corrected text.\n", stop: .stop), "Corrected text.")
        XCTAssertEqual(try LocalInference.textResult("<think>\nFix the typo.\n</think>\n\nCorrected text.", stop: .stop), "Corrected text.")
        XCTAssertEqual(try LocalInference.textResult("Write <think> in angle brackets.", stop: .stop), "Write <think> in angle brackets.", "Only reasoning the answer starts with is the model's own")

        XCTAssertThrowsError(try LocalInference.textResult("The first half of a long rewrite", stop: .length), "Cut text would replace the selection and drop its end") {
            XCTAssertTrue($0.localizedDescription.contains("before completing the text"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try LocalInference.textResult("<think>\nThe user wants a correction, so", stop: .length)) {
            XCTAssertTrue($0.localizedDescription.contains("before completing the text"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try LocalInference.textResult("<think>\nThe user wants a correction.", stop: .stop), "Reasoning without an answer is not the answer") {
            XCTAssertTrue($0.localizedDescription.contains("reasoning"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try LocalInference.textResult("<think>\nDone.\n</think>\n", stop: .stop)) {
            XCTAssertEqual($0.localizedDescription, "The local model returned no text.")
        }
        for unfinished in [GenerateStopReason.cancelled, nil] {
            XCTAssertThrowsError(try LocalInference.textResult("Half a sent", stop: unfinished)) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        }
    }

    func testLoadingAnotherTextModelHandsBackFreedBuffersAndBoundsTheBufferCache() async throws {
        // A buffer that MLX keeps for reuse after its array is gone, as it keeps
        // the weights of a text model that is being replaced.
        do { let buffer = MLXArray.zeros([1024, 1024]); eval(buffer) }
        // The GPU hands the buffer back once its command has completed.
        for _ in 0..<200 where MLX.Memory.cacheMemory == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(MLX.Memory.cacheMemory, 0)
        let engine = LocalInference()
        let model = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        // A test has no weights to load: stop at the moment the old model is gone.
        let attempt = Task {
            try await engine.prepare(model: model, url: FileManager.default.temporaryDirectory, residency: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        _ = await attempt.result
        XCTAssertEqual(MLX.Memory.cacheMemory, 0, "Buffers freed before a model loads go back to macOS")
        XCTAssertLessThanOrEqual(MLX.Memory.cacheLimit, 64 * 1024 * 1024, "The cache must not grow to MLX's memory limit during generation")
    }
    #endif

    func testUnfinishedDownloadCanBeDiscardedButAFolderFrogDidNotStartCannot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { _, base, _ in
            try Data("fetched".utf8).write(to: base.appendingPathComponent("first-file"))
            throw FrogError.message("The connection dropped")
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        let folder = directory.appendingPathComponent("Models/\(descriptor.id)")
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("first-file").path))

        models.discardDownload(descriptor.id); await models.waitForDownload(descriptor.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(models.unfinished.isEmpty)
        XCTAssertNil(models.errors[descriptor.id])

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("user-file"))
        models.discardDownload(descriptor.id); await models.waitForDownload(descriptor.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("user-file").path))
    }

    func testDownloadThatDoesNotFitOnTheDiskIsRefusedBeforeAnyFileIsFetched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let free = FreeSpace(312_000_000)
        let attempts = Attempts()
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { model, base, progress in
            _ = await attempts.next()
            return try await Self.fixtureDownload(model, base, progress)
        }, freeSpace: { _ in free.bytes })
        let descriptor = try XCTUnwrap(LocalModelDescriptor.find("whisper-large-v3-turbo-626mb"))
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertEqual(models.errors[descriptor.id], "Whisper Large v3 Turbo needs about 729.5 MB of free space, but the disk of the model folder has 312 MB free. Free up space or choose another model folder in Settings, then try again.")
        let started = await attempts.next()
        XCTAssertEqual(started, 1, "Nothing may be fetched for a model that cannot fit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Models/\(descriptor.id)").path))
        XCTAssertFalse(models.installed.contains(descriptor.id))
        XCTAssertTrue(models.unfinished.isEmpty)
        XCTAssertNil(models.progress[descriptor.id])

        free.bytes = 10_000_000_000
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertNil(models.errors[descriptor.id])
        XCTAssertTrue(models.installed.contains(descriptor.id))

        // A source whose metadata gave no sizes downloads as before.
        free.bytes = 0
        let repository = "fixture/whisperkit"
        let variant = "openai_whisper-tiny.en"
        let unsized = LocalModelDescriptor(id: HuggingFaceSource.modelID(repository: repository, variant: variant, backend: .whisperKit), name: "English fixture", kind: .audio, repository: repository, variant: variant, size: "See source for size")
        models.updateCatalog(LocalModelDescriptor.catalog + [unsized])
        models.download(unsized); await models.waitForDownload(unsized.id)
        XCTAssertNil(models.errors[unsized.id])
        XCTAssertTrue(models.installed.contains(unsized.id))
    }

    func testResumedDownloadNeedsRoomOnlyForTheBytesItsFolderLacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let free = FreeSpace(LocalModels.spareBytes + 1_500_000)
        let attempts = Attempts()
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: { model, base, progress in
            if await attempts.next() == 1 {
                try Data(repeating: 7, count: 2_000_000).write(to: base.appendingPathComponent("first-file"))
                throw FrogError.message("The connection dropped")
            }
            return try await Self.fixtureDownload(model, base, progress)
        }, freeSpace: { _ in free.bytes })
        let repository = "fixture/mlx"
        let custom = LocalModelDescriptor(id: HuggingFaceSource.modelID(repository: repository, variant: nil, backend: .mlx), name: "Fixture text", kind: .text, repository: repository, size: "See source for size", downloadBytes: 3_000_000)
        models.updateCatalog(LocalModelDescriptor.catalog + [custom])

        models.download(custom); await models.waitForDownload(custom.id)
        XCTAssertEqual(models.errors[custom.id], "Fixture text needs about 103 MB of free space, but the disk of the model folder has 101.5 MB free. Free up space or choose another model folder in Settings, then try again.")

        free.bytes = 10_000_000_000
        models.download(custom); await models.waitForDownload(custom.id)
        XCTAssertEqual(models.errors[custom.id], "The connection dropped")
        XCTAssertEqual(models.unfinished, [custom.id])

        // Two of the three megabytes are in the folder already.
        free.bytes = LocalModels.spareBytes + 1_500_000
        models.download(custom); await models.waitForDownload(custom.id)
        XCTAssertNil(models.errors[custom.id])
        XCTAssertTrue(models.installed.contains(custom.id))
    }

    func testFreeSpaceIsReadFromTheDiskOfAModelFolderThatDoesNotExistYet() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Models", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let free = try XCTUnwrap(LocalModels.availableCapacity(missing))
        XCTAssertGreaterThan(free, 0)
    }

    func testDiskUseIsMeasuredForDownloadedModelsAndForgottenWhenOneIsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: Self.sizedDownload, freeSpace: { _ in 10_000_000_000 })
        let text = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        let speech = try XCTUnwrap(LocalModelDescriptor.find("whisper-tiny"))
        await models.waitForDiskUse()
        XCTAssertTrue(models.diskUse.isEmpty)
        XCTAssertNil(models.totalDiskUse(of: models.installed), "No downloads, no total")
        XCTAssertEqual(models.size(of: text), text.downloadSize, "A model that is not downloaded shows what its download fetches")

        for model in [text, speech] { models.download(model); await models.waitForDownload(model.id) }
        await models.waitForDiskUse()
        let folder = directory.appendingPathComponent("Models/\(text.id)")
        let measured = try XCTUnwrap(models.diskUse[text.id])
        XCTAssertGreaterThanOrEqual(measured, 100_000)
        XCTAssertEqual(measured, LocalModels.allocatedSize(folder))
        XCTAssertEqual(models.size(of: text), LocalModelDescriptor.byteCount(measured), "A downloaded model shows what its folder takes")
        XCTAssertNotEqual(models.size(of: text), text.downloadSize)
        let both = try XCTUnwrap(models.totalDiskUse(of: models.installed))
        XCTAssertEqual(both, measured + (models.diskUse[speech.id] ?? 0))
        XCTAssertEqual(models.totalDiskUse(of: [text.id, "hf-not-downloaded"]), measured)

        let restarted = LocalModels(directory: directory, runtime: FixtureInference())
        await restarted.waitForDiskUse()
        XCTAssertEqual(restarted.diskUse, models.diskUse, "Measured at start")

        try await models.remove(text.id)
        XCTAssertNil(models.diskUse[text.id])
        XCTAssertEqual(models.totalDiskUse(of: models.installed), models.diskUse[speech.id])
    }

    func testDiskUseFollowsTheModelFolderAndTheCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: Self.sizedDownload, freeSpace: { _ in 10_000_000_000 })
        let repository = "fixture/mlx"
        let custom = LocalModelDescriptor(id: HuggingFaceSource.modelID(repository: repository, variant: nil, backend: .mlx), name: "Fixture text", kind: .text, repository: repository, size: "See source for size")
        models.updateCatalog(LocalModelDescriptor.catalog + [custom])
        models.download(custom); await models.waitForDownload(custom.id)
        await models.waitForDiskUse()
        XCTAssertNotNil(models.diskUse[custom.id])

        let restarted = LocalModels(directory: directory, runtime: FixtureInference())
        await restarted.waitForDiskUse()
        XCTAssertNil(restarted.diskUse[custom.id], "A source added by link is known once the catalogue arrives")
        restarted.updateCatalog(models.catalog)
        await restarted.waitForDiskUse()
        XCTAssertEqual(restarted.diskUse[custom.id], models.diskUse[custom.id])

        let original = models.root
        try await models.changeDirectory(to: directory.appendingPathComponent("elsewhere"))
        await models.waitForDiskUse()
        XCTAssertTrue(models.diskUse.isEmpty, "The new folder holds no models")
        try await models.changeDirectory(to: original)
        await models.waitForDiskUse()
        XCTAssertEqual(models.diskUse, restarted.diskUse)
    }

    func testUnavailableModelFailsWithoutCallingInference() async throws {
        let engine = FixtureInference()
        let models = LocalModels(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), runtime: engine)
        do { _ = try await models.complete("hello", instructions: "Correct", modelID: "qwen-0.6b"); XCTFail("Missing installation must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Download")) }
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
    }

    nonisolated private static func fixtureDownload(_ model: LocalModelDescriptor, _ base: URL, _ progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let folder = base.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("weights"))
        progress(.filesAreIn)
        return folder
    }
    /// Weights big enough that what the folder takes on disk is not one block.
    nonisolated private static func sizedDownload(_ model: LocalModelDescriptor, _ base: URL, _ progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let folder = try await fixtureDownload(model, base, progress)
        try Data(repeating: 7, count: 100_000).write(to: folder.appendingPathComponent("weights"))
        return folder
    }
}

/// The free space a test sets for the disk of the model folder.
private final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64?
    init(_ bytes: Int64?) { value = bytes }
    var bytes: Int64? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private actor FixtureInference: LocalInferenceEngine {
    let gate: DownloadGate?
    let preparationGate: DownloadGate?
    let fail: Bool
    init(gate: DownloadGate? = nil, fail: Bool = false, preparationGate: DownloadGate? = nil) { self.gate = gate; self.fail = fail; self.preparationGate = preparationGate }
    var loadedIDs = Set<String>()
    var preparations = 0
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
        preparations += 1
        if let preparationGate { await preparationGate.wait() }
        try Task.checkCancellation()
        loadedIDs.insert(model.id); await residency(loadedIDs)
    }
    var unloads = 0
    var cancelledUnload = false
    var calls = 0
    var lastSpeechModel: LocalModelDescriptor?
    var lastLanguage: String?
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        lastSpeechModel = model; lastLanguage = language
        loadedIDs.insert(model.id); calls += 1; await residency(loadedIDs); return "hello"
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(id); calls += 1; await residency(loadedIDs)
        if let gate { await gate.wait() }
        if fail { throw FrogError.message("Fixture inference failure") }
        return text
    }
    func unload(keepingMetadata: Bool) { cancelledUnload = Task.isCancelled; loadedIDs = []; unloads += 1 }
}

private actor Attempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
