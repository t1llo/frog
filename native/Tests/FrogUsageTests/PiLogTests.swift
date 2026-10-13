import Foundation
import XCTest
@testable import FrogUsage

/// Synthetic session files only; no test reads Pi's real folder.
final class PiLogTests: XCTestCase {
    func testForkCopiesCountOnceAndOnlyFinishedAssistantCallsCount() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), session = root.appendingPathComponent("session.jsonl")
        let first = assistant(at: now.addingTimeInterval(-300), input: 10, output: 20, cacheRead: 100, cacheWrite: 8)
        let second = assistant(at: now.addingTimeInterval(-200), input: 3, output: 4)
        let third = try entry(assistant(at: now.addingTimeInterval(-100), input: 1, output: 2))
        let start = try jsonLine(["type": "session", "version": 3, "id": "fixture"])
            // Other lines can carry the same field without being a model call.
            + entry(["role": "user", "content": "how much is left?", "usage": ["input": 999, "output": 999]])
            + entry(["role": "toolResult", "content": String(repeating: "output ", count: 400)])
            + entry(first)
            + jsonLine(["type": "compaction", "tokensBefore": 50_000, "usage": ["input": 7_777, "output": 1]])
            + entry(assistant(provider: "amazon-bedrock", at: now.addingTimeInterval(-250), input: 500, output: 500))
            + entry(assistant(at: now.addingTimeInterval(-240), input: 0, output: 0))
        // The last line is still being written.
        try (start + entry(second) + third.dropLast()).write(to: session)
        let fork = root.appendingPathComponent("forked/copy.jsonl")
        try FileManager.default.createDirectory(at: fork.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (entry(first) + entry(assistant(provider: "openai-codex", model: "gpt-5.1", at: now.addingTimeInterval(-150), input: 5, output: 6)))
            .write(to: fork)

        let scanner = PiScanner(root: root)
        let scan = await scanner.scan(), repeated = await scanner.scan()
        XCTAssertEqual(scan.map(\.output).sorted(), [4, 6, 20], "The copy in the fork is the same call")
        XCTAssertEqual(repeated.map(\.output).sorted(), [4, 6, 20])
        XCTAssertTrue(scan.allSatisfy { $0.source == .pi })
        let call = try XCTUnwrap(scan.first { $0.output == 20 })
        XCTAssertEqual(call.provider, .claude)
        XCTAssertEqual([call.input, call.cacheRead, call.cacheWrite], [10, 100, 8])
        XCTAssertEqual(call.date.timeIntervalSince1970, now.addingTimeInterval(-300).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(scan.first { $0.output == 6 }?.provider, .openai)

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        let finished = await scanner.scan()
        XCTAssertEqual(finished.map(\.output).sorted(), [2, 4, 6, 20])

        // Pi can rewrite a session; what is no longer in the file is no longer counted.
        try (start + third).write(to: session)
        let rewritten = await scanner.scan()
        XCTAssertEqual(rewritten.map(\.output).sorted(), [2, 6, 20])
    }

    func testCallsAreTakenFromTheChartHorizonAndCopiesAreKnownWithoutTheirOwnTimestamp() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var undated = assistant(at: now, input: 7, output: 9)
        undated["timestamp"] = nil
        // Two calls at different times are two calls, however alike they are.
        let alike = try entry(assistant(at: now.addingTimeInterval(-60), input: 1, output: 1))
            + entry(assistant(at: now.addingTimeInterval(-50), input: 1, output: 1))
        try (entry(undated, at: now.addingTimeInterval(-30)) + alike
            + entry(assistant(at: now.addingTimeInterval(-TokenScanner.horizon - 3600), input: 100, output: 100))
            + entry(assistant(at: now.addingTimeInterval(3600), input: 200, output: 200)))
            .write(to: root.appendingPathComponent("original.jsonl"))
        try entry(undated, at: now.addingTimeInterval(-20)).write(to: root.appendingPathComponent("copy.jsonl"))
        let scan = await PiScanner(root: root).scan()
        XCTAssertEqual(scan.map(\.output).sorted(), [1, 1, 9])
    }

    func testACallIsPricedFromItsOwnProvidersList() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), million = 1_000_000
        try (entry(assistant(at: now.addingTimeInterval(-60), input: million, output: 100_000, cacheRead: 2 * million, cacheWrite: 400_000))
            + entry(assistant(provider: "openai-codex", model: "gpt-5.1", at: now.addingTimeInterval(-50),
                              input: million, output: 200_000, cacheRead: 2 * million))
            + entry(assistant(provider: "openai", model: "gpt-5.6-sol", at: now.addingTimeInterval(-40),
                              input: million, output: 300_000, cacheRead: million, cacheWrite: million))
            + entry(assistant(provider: "openai", model: "a-model-without-a-price", at: now.addingTimeInterval(-30), input: 1, output: 400_000)))
            .write(to: root.appendingPathComponent("session.jsonl"))
        let scan = await PiScanner(root: root).scan()
        func cost(output: Int) -> Double? { scan.first { $0.output == output }.flatMap(\.cost) }
        XCTAssertEqual(scan.count, 4)

        let claude = try XCTUnwrap(apiPrices["claude-sonnet-4-6"])
        XCTAssertEqual(try XCTUnwrap(cost(output: 100_000)),
                       claude.input + 0.4 * claude.input * 1.25 + 2 * claude.cacheRead + 0.1 * claude.output, accuracy: 1e-9)
        let plain = try XCTUnwrap(openAIPrices["gpt-5.1"])
        XCTAssertEqual(try XCTUnwrap(cost(output: 200_000), "An OpenAI model is not in Anthropic's price list"),
                       plain.input + 2 * plain.cachedInput + 0.2 * plain.output, accuracy: 1e-9)
        let caching = try XCTUnwrap(openAIPrices["gpt-5.6-sol"]), write = try XCTUnwrap(caching.cacheWrite)
        XCTAssertEqual(try XCTUnwrap(cost(output: 300_000)),
                       caching.input + caching.cachedInput + write + 0.3 * caching.output, accuracy: 1e-9)
        XCTAssertNil(cost(output: 400_000), "A model without a list price is left unpriced rather than guessed")
    }

    private func assistant(provider: String = "anthropic", model: String = "claude-sonnet-4-6", at date: Date,
                           input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> [String: Any] {
        ["role": "assistant", "provider": provider, "model": model, "stopReason": "stop",
         "timestamp": (date.timeIntervalSince1970 * 1000).rounded(),
         "content": [["type": "text", "text": "reply \(output)"]],
         "usage": ["input": input, "output": output, "cacheRead": cacheRead, "cacheWrite": cacheWrite]]
    }
    /// One line of a session file: Pi wraps every message in an entry with its own id and time.
    private func entry(_ message: [String: Any], at date: Date = Date()) throws -> Data {
        try jsonLine(["type": "message", "id": UUID().uuidString,
                      "timestamp": ISO8601DateFormatter().string(from: date), "message": message])
    }
    private func jsonLine(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) + Data([10])
    }
    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
