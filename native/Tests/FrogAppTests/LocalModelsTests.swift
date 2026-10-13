import XCTest
import FrogCore
#if arch(arm64)
import Hub
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
            progress(0.5)
            await gate.wait()
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await gate.waitUntilStarted()
        for _ in 0..<1000 where models.progress[descriptor.id] != 0.5 { await Task.yield() }
        XCTAssertEqual(models.progress[descriptor.id], 0.5)
        XCTAssertTrue(models.preparing.isEmpty, "Files are still arriving")

        await gate.resume(); await gate.waitUntilStarted()
        for _ in 0..<1000 where models.progress[descriptor.id] != 1 { await Task.yield() }
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
        let gated = message(Hub.HubClientError.authorizationRequired)
        XCTAssertTrue(gated.contains(model.repository) && !gated.contains("token"), gated)
        XCTAssertTrue(message(Hub.HubClientError.fileNotFound("\(model.repository)@main/model.safetensors")).contains(model.repository))
        let limited = message(Hub.HubClientError.downloadError("Rate limited while downloading \(model.repository)@main/model.safetensors (https://example.invalid/model.safetensors -> /Volumes/Disk/Models/model.safetensors)"))
        XCTAssertTrue(limited.contains("few minutes"), limited)
        XCTAssertFalse(limited.contains("/Volumes") || limited.contains("https://"), "No paths or addresses of the library's making: \(limited)")
        XCTAssertEqual(message(Hub.HubClientError.httpStatusCode(429)), limited)
        #endif
    }

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

    func testUnavailableModelFailsWithoutCallingInference() async throws {
        let engine = FixtureInference()
        let models = LocalModels(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), runtime: engine)
        do { _ = try await models.complete("hello", instructions: "Correct", modelID: "qwen-0.6b"); XCTFail("Missing installation must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Download")) }
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
    }

    nonisolated private static func fixtureDownload(_ model: LocalModelDescriptor, _ base: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = base.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("weights"))
        progress(1)
        return folder
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
