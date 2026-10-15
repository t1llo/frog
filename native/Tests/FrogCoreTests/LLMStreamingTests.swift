import XCTest
@testable import FrogCore

/// Answers each fixture host with a status, a content type and a body delivered in separate chunks.
private final class StreamFixtureProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var contentType = "text/event-stream"
        var chunks: [Data] = []
        /// Keeps the response open after the chunks, like a model that is still generating.
        var hang = false
        var onStop: (() -> Void)?
    }

    static let lock = NSLock()
    static var replies: [String: Reply] = [:]
    static var requests: [String: [(request: URLRequest, body: Data)]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        Self.lock.lock()
        let reply = Self.replies[host]
        Self.requests[host, default: []].append((request, Self.body(of: request)))
        Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !reply.hang { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        Self.lock.lock()
        let onStop = Self.replies[request.url!.host!]?.onStop
        Self.lock.unlock()
        onStop?()
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

final class LLMStreamingTests: XCTestCase {
    private var session: URLSession!
    private var host: String!
    private let conversation = [ChatMessage(role: .user, text: "What is a frog?"), ChatMessage(role: .assistant, text: "An amphibian."),
                                ChatMessage(role: .user, text: "And a toad?")]

    override func setUp() {
        host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        StreamFixtureProtocol.lock.lock(); defer { StreamFixtureProtocol.lock.unlock() }
        StreamFixtureProtocol.replies.removeValue(forKey: host)
        StreamFixtureProtocol.requests.removeValue(forKey: host)
    }

    func testEveryKindStreamsTextInOrderAcrossChunkBoundaries() async throws {
        for kind in [ProviderKind.openAI, .compatible, .lmStudio, .anthropic, .gemini, .ollama] {
            let body = streamBody(kind, ["Grüße ", "🐸 frog", "\n蛙"])
            reply(StreamFixtureProtocol.Reply(contentType: kind == .ollama ? "application/x-ndjson" : "text/event-stream; charset=utf-8",
                                              chunks: splitInsideLineAndCharacter(body)))
            let events = try await collect(kind)
            XCTAssertEqual(events, [.text("Grüße "), .text("🐸 frog"), .text("\n蛙")], "\(kind)")
        }
    }

    func testRequestsCarryTheConversationForEachKind() async throws {
        for kind in [ProviderKind.openAI, .anthropic, .gemini, .ollama] {
            reply(StreamFixtureProtocol.Reply(contentType: kind == .ollama ? "application/x-ndjson" : "text/event-stream",
                                              chunks: [Data(streamBody(kind, ["Ok"]).utf8)]))
            _ = try await collect(kind, key: kind == .ollama ? nil : "fixture-key")
            let (request, data) = try XCTUnwrap(recorded().last)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-key"), "The key stays out of the URL")
            switch kind {
            case .openAI:
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                XCTAssertNil(request.url?.query)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
                XCTAssertEqual(request.timeoutInterval, 300)
                XCTAssertEqual(body["stream"] as? Bool, true)
                XCTAssertEqual(body["model"] as? String, "test-model")
                XCTAssertEqual(body["messages"] as? [[String: String]], [
                    ["role": "system", "content": "Explain briefly"], ["role": "user", "content": "What is a frog?"],
                    ["role": "assistant", "content": "An amphibian."], ["role": "user", "content": "And a toad?"]
                ])
            case .anthropic:
                XCTAssertEqual(request.url?.path, "/v1/messages")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(body["system"] as? String, "Explain briefly")
                XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
                XCTAssertEqual(body["stream"] as? Bool, true)
                XCTAssertEqual(body["messages"] as? [[String: String]], [
                    ["role": "user", "content": "What is a frog?"], ["role": "assistant", "content": "An amphibian."],
                    ["role": "user", "content": "And a toad?"]
                ])
            case .gemini:
                XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-test:streamGenerateContent")
                XCTAssertEqual(request.url?.query, "alt=sse")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
                let system = try XCTUnwrap(body["system_instruction"] as? [String: Any])
                XCTAssertEqual(system["parts"] as? [[String: String]], [["text": "Explain briefly"]])
                let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
                XCTAssertEqual(contents[1]["parts"] as? [[String: String]], [["text": "An amphibian."]])
            default:
                XCTAssertEqual(request.url?.path, "/api/chat")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson")
                XCTAssertEqual(request.timeoutInterval, 600)
                XCTAssertEqual(body["stream"] as? Bool, true)
                XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user", "assistant", "user"])
            }
        }
    }

    func testAServerThatIgnoresStreamingAnswersInOnePiece() async throws {
        reply(StreamFixtureProtocol.Reply(contentType: "application/json",
                                          chunks: [Data(#"{"choices":[{"message":{"content":"Whole answer"},"finish_reason":"stop"}]}"#.utf8)]))
        let events = try await collect(.compatible, key: nil)
        XCTAssertEqual(events, [.text("Whole answer")])
    }

    func testHTTPErrorsMatchTheNonStreamingMessages() async throws {
        for (status, message) in [(401, "The provider rejected authentication. Check the API key and model access."),
                                  (429, "The provider rate limit or quota was reached. Check your usage and try again later.")] {
            reply(StreamFixtureProtocol.Reply(status: status, contentType: "application/json", chunks: [Data("private-secret".utf8)]))
            do { _ = try await collect(.openAI); XCTFail("Expected HTTP \(status) to fail") }
            catch { XCTAssertEqual(error.localizedDescription, message) }
        }
    }

    func testCancellingTheConsumerCancelsTheRequest() async throws {
        let stopped = expectation(description: "The request stopped loading")
        let received = expectation(description: "The first text arrived")
        received.assertForOverFulfill = false
        reply(StreamFixtureProtocol.Reply(chunks: [Data(#"data: {"choices":[{"delta":{"content":"Partial"}}]}"#.utf8 + [10])],
                                          hang: true, onStop: { stopped.fulfill() }))
        let stream = client.stream(messages: conversation, instructions: "Explain briefly", rule: Rule(), provider: provider(.openAI), apiKey: "fixture-key")
        let task = Task { () async throws -> [AnswerEvent] in
            var events: [AnswerEvent] = []
            for try await event in stream {
                events.append(event)
                received.fulfill()
            }
            try Task.checkCancellation()
            return events
        }
        await fulfillment(of: [received], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testAnAnswerLongerThanTheLimitFails() async throws {
        let line = #"{"message":{"content":"\#(String(repeating: "a", count: 1_024 * 1_024))"},"done":false}"# + "\n"
        reply(StreamFixtureProtocol.Reply(contentType: "application/x-ndjson", chunks: Array(repeating: Data(line.utf8), count: 9)))
        do { _ = try await collect(.ollama, key: nil); XCTFail("Expected the answer to be too long") }
        catch { XCTAssertEqual(error.localizedDescription, "The answer was too long.") }
    }

    func testInvalidRequestsFailBeforeAnyRequest() async throws {
        reply(StreamFixtureProtocol.Reply(chunks: [Data(streamBody(.openAI, ["Never"]).utf8)]))
        var insecure = provider(.anthropic); insecure.endpoint = "http://\(host!)"
        let cases: [(ProviderConfiguration, String?, [ChatMessage], String)] = [
            (provider(.openAI), nil, conversation, "Explain briefly"),
            (insecure, "fixture-key", conversation, "Explain briefly"),
            (provider(.openAI), "fixture-key", [], "Explain briefly"),
            (provider(.openAI), "fixture-key", [ChatMessage(role: .user, text: " ")], "Explain briefly"),
            (provider(.openAI), "fixture-key", conversation, " "),
            (ProviderConfiguration(kind: .claudeCode), nil, conversation, "Explain briefly")
        ]
        for (provider, key, messages, instructions) in cases {
            do {
                for try await _ in client.stream(messages: messages, instructions: instructions, rule: Rule(), provider: provider, apiKey: key) {}
                XCTFail("Expected a validation failure for \(provider.kind)")
            } catch { XCTAssertTrue(error is FrogError, "\(error)") }
        }
        XCTAssertTrue(recorded().isEmpty)
    }

    // MARK: Helpers

    private var client: LLMClient { LLMClient(session: session) }

    private func provider(_ kind: ProviderKind) -> ProviderConfiguration {
        let path = kind == .gemini ? "/v1beta" : ([.openAI, .compatible, .lmStudio].contains(kind) ? "/v1" : "")
        return ProviderConfiguration(kind: kind, endpoint: "https://\(host!)\(path)", model: kind == .gemini ? "models/gemini-test" : "test-model")
    }

    private func collect(_ kind: ProviderKind, key: String? = "fixture-key") async throws -> [AnswerEvent] {
        var events: [AnswerEvent] = []
        for try await event in client.stream(messages: conversation, instructions: "Explain briefly", rule: Rule(),
                                             provider: provider(kind), apiKey: key) {
            events.append(event)
        }
        return events
    }

    private func reply(_ reply: StreamFixtureProtocol.Reply) {
        StreamFixtureProtocol.lock.lock(); defer { StreamFixtureProtocol.lock.unlock() }
        StreamFixtureProtocol.replies[host] = reply
    }

    private func recorded() -> [(request: URLRequest, body: Data)] {
        StreamFixtureProtocol.lock.lock(); defer { StreamFixtureProtocol.lock.unlock() }
        return StreamFixtureProtocol.requests[host] ?? []
    }

    /// A complete response in each kind's wire format that streams `parts` as separate deltas.
    private func streamBody(_ kind: ProviderKind, _ parts: [String]) -> String {
        func json(_ value: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: [value], options: .fragmentsAllowed), as: UTF8.self)
                .dropFirst().dropLast().description
        }
        switch kind {
        case .anthropic:
            return "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n"
                + "event: ping\ndata: {\"type\":\"ping\"}\n\n"
                + parts.map { "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(json($0))}}\n\n" }.joined()
                + "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"
                + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        case .gemini:
            return parts.map { "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\(json($0))}]}}]}\r\n\r\n" }.joined()
        case .ollama:
            return parts.map { "{\"message\":{\"role\":\"assistant\",\"content\":\(json($0))},\"done\":false}\n" }.joined()
                + "{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}\n"
        default:
            return ": keep-alive\n\n" + parts.map { "data: {\"choices\":[{\"delta\":{\"content\":\(json($0))}}]}\n\n" }.joined() + "data: [DONE]\n\n"
        }
    }

    /// Splits a body in the middle of its first line and inside its first multi-byte character.
    private func splitInsideLineAndCharacter(_ body: String) -> [Data] {
        let bytes = Array(body.utf8)
        let multiByte = bytes.firstIndex(where: { $0 >= 0xC0 }).map { $0 + 1 } ?? bytes.count / 2
        let cuts = Array(Set([min(5, bytes.count), multiByte])).sorted()
        var chunks: [Data] = []
        var start = 0
        for cut in cuts + [bytes.count] where cut > start {
            chunks.append(Data(bytes[start..<cut]))
            start = cut
        }
        return chunks
    }
}
