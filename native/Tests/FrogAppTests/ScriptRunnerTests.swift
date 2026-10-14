import AppKit
import XCTest
import FrogCore
@testable import FrogApp

final class ScriptRunnerTests: XCTestCase {
    func testLargeStdoutAndStderrAreDrainedAndBoundedWithExitStatus() async throws {
        let result = try await ScriptProcess.run("/usr/bin/head -c 131072 /dev/zero; printf complete >&2; exit 7", outputLimit: 1024)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output.utf8.count, 1024)
        XCTAssertTrue(result.truncated)
    }

    func testCancellationKillsTheOwnedShellAndBackgroundChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pids")
        let task = Task { try await ScriptProcess.run("echo $$ > '\(file.path)'; /bin/sleep 30 & echo $! >> '\(file.path)'; wait") }
        defer { task.cancel() }
        var pids: [Int32] = []
        for _ in 0..<200 {
            pids = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            if pids.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pids.count, 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        for _ in 0..<200 where pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(for: .milliseconds(5)) }
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1, "Owned process must be gone"); XCTAssertEqual(errno, ESRCH) }
    }

    func testTimeoutTerminatesAnOtherwiseBlockingScript() async throws {
        let start = ContinuousClock.now
        do { _ = try await ScriptProcess.run("/bin/sleep 30", timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testAScriptThatRunsOutOfTimeKeepsWhatItPrinted() async throws {
        let printed = ScriptPrintedFixture()
        do {
            _ = try await ScriptProcess.run("print -r -- progress fixture; /bin/sleep 30", timeout: 0.5) { printed.text = $0 }
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        XCTAssertEqual(printed.text, "progress fixture\n")
    }

    func testOutputShownWhileTheScriptRunsEndsBeforeACharacterStillArriving() {
        let frog = Data("a🐸".utf8)
        XCTAssertEqual(ScriptProcess.wholeCharacterCount(frog), 5)
        for cut in 2..<5 { XCTAssertEqual(ScriptProcess.wholeCharacterCount(frog.prefix(cut)), 1) }
        XCTAssertEqual(ScriptProcess.wholeCharacterCount(Data("é".utf8).prefix(1)), 0)
        XCTAssertEqual(ScriptProcess.wholeCharacterCount(Data("ab".utf8)), 2)
        XCTAssertEqual(ScriptProcess.wholeCharacterCount(Data()), 0)
    }

    @MainActor func testOutputAppearsWhileTheScriptRunsAndStaysWhenItIsStopped() async throws {
        let runner = ScriptRunner()
        runner.run(UtilityDocument(kind: .script, title: "Slow", text: "print -r -- printed fixture; /bin/sleep 30"))
        for _ in 0..<300 where runner.output.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(runner.running)
        XCTAssertEqual(runner.output, "printed fixture\n")
        runner.stop()
        await runner.stopAndWait()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.output, "printed fixture\n")
        XCTAssertEqual(runner.status, "Stopped")
        // A new run starts empty and shows only its own output.
        runner.run(UtilityDocument(kind: .script, title: "Quick", text: "print -r -- second fixture"))
        XCTAssertEqual(runner.output, "")
        for _ in 0..<300 where runner.running != nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.output, "second fixture\n")
        XCTAssertEqual(runner.status, "Exit 0")
    }

    @MainActor func testAStoppedScriptHoldsUpQuitOnlyUntilItsProcessIsGone() async throws {
        let runner = ScriptRunner()
        runner.run(UtilityDocument(kind: .script, title: "Slow", text: "/bin/sleep 30"))
        XCTAssertTrue(runner.needsQuitCleanup)
        runner.stop()
        // The process group is killed by the stopped task, so a quit right after Stop still waits for it.
        XCTAssertTrue(runner.needsQuitCleanup)
        for _ in 0..<300 where runner.needsQuitCleanup { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(runner.needsQuitCleanup)
        XCTAssertEqual(runner.status, "Stopped")
    }

    @MainActor func testAScriptReplacedByAnotherLeavesTheNewOneToCleanUpAtQuit() async throws {
        let runner = ScriptRunner()
        runner.run(UtilityDocument(kind: .script, title: "First", text: "/bin/sleep 30"))
        let second = UtilityDocument(kind: .script, title: "Second", text: "print -r -- second fixture; /bin/sleep 30")
        runner.run(second)
        // The first script ends once the second starts printing; its end must not release the second one's task.
        for _ in 0..<300 where runner.output.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.output, "second fixture\n")
        XCTAssertEqual(runner.running, second.id)
        XCTAssertTrue(runner.needsQuitCleanup)
        await runner.stopAndWait()
        XCTAssertFalse(runner.needsQuitCleanup)
    }

    func testScriptsSearchTheHomebrewDirectoriesAheadOfTheInheritedPath() async throws {
        XCTAssertEqual(ScriptProcess.searchPath(inherited: "/usr/bin:/bin:/usr/sbin:/sbin"), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(ScriptProcess.searchPath(inherited: "/fixture/bin:/usr/local/bin:/usr/bin:/opt/homebrew/bin:/fixture/bin"), "/opt/homebrew/bin:/usr/local/bin:/fixture/bin:/usr/bin")
        XCTAssertEqual(ScriptProcess.searchPath(inherited: nil), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        let result = try await ScriptProcess.run("print -r -- $PATH")
        XCTAssertEqual(result.status, 0)
        let directories = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        XCTAssertEqual(Array(directories.prefix(2)), ["/opt/homebrew/bin", "/usr/local/bin"])
        XCTAssertEqual(Set(directories).count, directories.count)
        XCTAssertTrue(directories.contains("/usr/bin"))
    }

    @MainActor func testShelfAcceptsNativeFileURLAndTextProviders() async throws {
        let url = URL(fileURLWithPath: "/fixture/folder/example.txt")
        let file = await ShelfDrop.document(from: NSItemProvider(object: url as NSURL))
        XCTAssertEqual(file?.files, [url])
        XCTAssertEqual(file?.text, "")
        let text = await ShelfDrop.document(from: NSItemProvider(object: "two\nlines" as NSString))
        XCTAssertEqual(text?.title, "two lines")
        XCTAssertEqual(text?.text, "two\nlines")
        let link = await ShelfDrop.document(from: NSItemProvider(object: URL(string: "https://example.org/path")! as NSURL))
        XCTAssertEqual(link?.text, "https://example.org/path")
        XCTAssertEqual(link?.files, [])
    }
}

private final class ScriptPrintedFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
