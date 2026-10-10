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
