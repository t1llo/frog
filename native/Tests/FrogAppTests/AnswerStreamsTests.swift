import XCTest
import FrogCore
@testable import FrogApp

final class AnswerStreamsTests: XCTestCase {
    private let messages = [ChatMessage(role: .user, text: "Selected text: bank"),
                            ChatMessage(role: .assistant, text: "A river bank."),
                            ChatMessage(role: .user, text: "And a money bank?")]

    func testACodingToolAnswersInOnePieceFromTheTranscript() async throws {
        let received = Received()
        for (model, expected) in [(LocalToolKind.defaultModelID, ""), ("sonnet", "sonnet")] {
            let request = AnswerRequest(rule: .explainPreset, provider: ProviderConfiguration(name: "Claude Code", kind: .claudeCode, model: model),
                                        apiKey: nil, instructions: "Explain it.", messages: messages, isFrogLocal: false)
            let stream = AnswerStreams.codingTool(request, kind: .claudeCode) { tool in
                received.append(tool)
                return "A bank that keeps money."
            }
            var events: [AnswerEvent] = []
            for try await event in stream { events.append(event) }
            XCTAssertEqual(events, [.text("A bank that keeps money.")])
            let tool = try XCTUnwrap(received.last)
            XCTAssertEqual(tool.kind, .claudeCode)
            XCTAssertEqual(tool.model, expected)
            XCTAssertEqual(tool.instructions, "Explain it.")
            XCTAssertEqual(tool.text, AnswerPrompt.transcript(messages))
        }
    }

    @MainActor func testLiveStreamsSendCodingToolsToTheirClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No tool is installed in the fixture folder, so the client says how to install it.
        let tools = LocalToolClient(discovery: .init(home: root, environment: [:], searchDirectories: [root]), temporaryRoot: root)
        let live = AnswerStreams.live(localModels: LocalModels(directory: root.appendingPathComponent("models")), localTools: tools)
        let request = AnswerRequest(rule: .explainPreset, provider: ProviderConfiguration(name: "Codex", kind: .codex),
                                    apiKey: nil, instructions: "Explain it.", messages: messages, isFrogLocal: false)
        do {
            for try await _ in live(request) {}
            XCTFail("A missing tool must fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, LocalToolKind.codex.loginInstructions)
        }
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [LocalToolRequest] = []
    var last: LocalToolRequest? { lock.withLock { requests.last } }
    func append(_ request: LocalToolRequest) { lock.withLock { requests.append(request) } }
}
