import XCTest
@testable import FrogCore

private final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> (Int, Data)?] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url!.host!]
        Self.lock.unlock()
        do {
            guard let (status, data) = try XCTUnwrap(handler)(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class LLMClientTests: XCTestCase {
    private var session: URLSession!
    private var host: String!
    override func setUp() {
        host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        FixtureProtocol.lock.lock(); defer { FixtureProtocol.lock.unlock() }
        FixtureProtocol.handlers.removeValue(forKey: host)
    }

    func testOpenAIRequestKeepsTextSeparateExpandsLanguageOverridesModelAndPreservesOutput() async throws {
        fixture { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test")
            XCTAssertEqual(request.timeoutInterval, 90)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.body(request)
            XCTAssertEqual(body["model"] as? String, "override")
            XCTAssertEqual(body["stream"] as? Bool, false)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role": "system", "content": "Translate to German"], ["role": "user", "content": "{{language}} selected text"]])
            return (200, Data(#"{"choices":[{"message":{"content":"  result\n"},"finish_reason":"stop"}]}"#.utf8))
        }
        let rule = Rule(instructions: "Translate to {{language}}", model: "override", targetLanguage: "German")
        let result = try await client.complete(text: "{{language}} selected text", rule: rule, provider: provider(.openAI), apiKey: "secret-test")
        XCTAssertEqual(result, "  result\n")
    }

    func testAnthropicProtocol() async throws {
        fixture { request in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try self.body(request)
            XCTAssertEqual(body["system"] as? String, "Instructions")
            XCTAssertEqual(body["max_tokens"] as? Int, 8192)
            XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "Text"]])
            return (200, Data(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"One"},{"type":"text","text":" two"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let result = try await complete(.anthropic)
        XCTAssertEqual(result, "One two")
    }

    func testGeminiProtocolKeepsKeyOutOfURLAndOmitsThoughts() async throws {
        fixture { request in
            XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-test:generateContent")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "key")
            let body = try self.body(request)
            let system = try XCTUnwrap(body["system_instruction"] as? [String: Any])
            XCTAssertEqual(system["parts"] as? [[String: String]], [["text": "Instructions"]])
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            XCTAssertEqual(contents[0]["parts"] as? [[String: String]], [["text": "Text"]])
            return (200, Data(#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"private"},{"text":"Answer"}]},"finishReason":"STOP"}]}"#.utf8))
        }
        let result = try await complete(.gemini)
        XCTAssertEqual(result, "Answer")
    }

    func testGeminiDefaultUsesAIStudioGenerateContentEndpoint() async throws {
        // Intercept the real default host: this checks URL construction without a live API request.
        host = "generativelanguage.googleapis.com"
        fixture { request in
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(#"{"candidates":[{"content":{"parts":[{"text":"Connected"}]},"finishReason":"STOP"}]}"#.utf8))
        }
        let result = try await client.complete(text: "Hello", rule: Rule(instructions: "Reply briefly"),
                                               provider: ProviderConfiguration(kind: .gemini), apiKey: "fixture-key")
        XCTAssertEqual(result, "Connected")
    }

    func testOllamaAndCompatibleWorkWithoutKeys() async throws {
        for kind in [ProviderKind.ollama, .compatible, .lmStudio] {
            fixture { request in
                XCTAssertEqual(request.url?.path, kind == .ollama ? "/api/chat" : "/v1/chat/completions")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(try self.body(request)["stream"] as? Bool, false)
                let json = kind == .ollama ? #"{"message":{"content":"Local"},"done":true}"# : #"{"choices":[{"message":{"content":"Local"}}]}"#
                return (200, Data(json.utf8))
            }
            let result = try await client.complete(text: "Text", rule: Rule(), provider: provider(kind), apiKey: nil)
            XCTAssertEqual(result, "Local")
        }
    }

    func testHTTPAndTransportErrorsAreSafe() async throws {
        for status in [302, 400, 401, 403, 404, 408, 429, 500, 504] {
            fixture { _ in (status, Data("secret-key and selected-private-text".utf8)) }
            do { _ = try await complete(.openAI); XCTFail("Expected HTTP failure") }
            catch {
                XCTAssertTrue(error is FrogError)
                XCTAssertFalse(error.localizedDescription.contains("secret-key"))
                XCTAssertFalse(error.localizedDescription.contains("selected-private-text"))
            }
        }
        fixture { _ in throw URLError(.timedOut) }
        do { _ = try await complete(.openAI); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        fixture { _ in throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "secret-key"]) }
        do { _ = try await complete(.openAI); XCTFail("Expected connection failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret-key")) }
    }

    func testMalformedEmptyBlockedAndTruncatedResponsesNeverReplaceText() async throws {
        let cases: [(ProviderKind, String)] = [
            (.openAI, "not JSON"), (.openAI, "{}"),
            (.openAI, #"{"choices":[{"message":{"content":" \n"}}]}"#),
            (.openAI, #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#),
            (.anthropic, #"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"SAFETY"}]}"#),
            (.gemini, #"{"candidates":[]}"#),
            (.ollama, #"{"message":{"content":"partial"},"done":false}"#)
        ]
        for (kind, json) in cases {
            fixture { _ in (200, Data(json.utf8)) }
            do { _ = try await complete(kind); XCTFail("Expected invalid response for \(kind)") }
            catch { XCTAssertTrue(error is FrogError) }
        }
    }

    func testValidationFailsBeforeNetworking() async throws {
        fixture { _ in XCTFail("Invalid request reached network"); return (500, Data()) }
        var invalidURL = provider(.openAI); invalidURL.endpoint = "https://user:password@example.com/v1?key=secret"
        var insecure = provider(.openAI); insecure.endpoint = "http://example.com/v1"
        var invalidModel = provider(.gemini); invalidModel.model = "../../bad?key=secret"
        let cases: [(String, Rule, ProviderConfiguration, String?)] = [
            (" ", Rule(), provider(.openAI), "key"),
            ("Text", Rule(instructions: ""), provider(.openAI), "key"),
            ("Text", Rule(instructions: "Translate {{language}}"), provider(.openAI), "key"),
            ("Text", Rule(), provider(.openAI), nil),
            ("Text", Rule(), provider(.openAI), "a\nb"),
            ("Text", Rule(), invalidURL, "key"), ("Text", Rule(), insecure, "key"),
            ("Text", Rule(), invalidModel, "key")
        ]
        for (text, rule, provider, key) in cases {
            do { _ = try await client.complete(text: text, rule: rule, provider: provider, apiKey: key); XCTFail("Expected validation failure") }
            catch { XCTAssertTrue(error is FrogError) }
        }
    }

    func testCancellationRemainsCancellation() async throws {
        fixture { _ in throw URLError(.cancelled) }
        do { _ = try await complete(.openAI); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellingAnInFlightTaskCancelsURLSession() async throws {
        let started = expectation(description: "Request started")
        fixture { _ in started.fulfill(); return nil }
        let task = Task { try await complete(.openAI) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLocalModelDiscoveryUsesCorrectEndpointsAndNoTextPayload() async throws {
        for kind in [ProviderKind.ollama, .lmStudio] {
            fixture { request in
                XCTAssertEqual(request.url?.path, kind == .ollama ? "/api/tags" : "/v1/models")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let json = kind == .ollama
                    ? #"{"models":[{"name":"local-b"},{"name":"local-a"},{"name":"local-a"}]}"#
                    : #"{"data":[{"id":"local-b"},{"id":"local-a"},{"id":"local-a"}]}"#
                return (200, Data(json.utf8))
            }
            var draft = provider(kind); draft.model = ""; draft.models = []
            let models = try await client.localModels(provider: draft, apiKey: nil)
            XCTAssertEqual(models.map(\.id), ["local-a", "local-b"])
        }
    }

    func testModelDiscoveryRejectsUnsafeEndpointsBeforeNetworkAndSanitizesFailures() async throws {
        fixture { _ in XCTFail("Unsafe request reached the network"); return (200, Data()) }
        var unsafe = provider(.lmStudio); unsafe.endpoint = "http://remote.example/v1"
        do { _ = try await client.localModels(provider: unsafe, apiKey: nil); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error is FrogError) }
        fixture { _ in (401, Data("private-secret".utf8)) }
        do { _ = try await client.localModels(provider: provider(.lmStudio), apiKey: "fixture-key"); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private-secret")) }
        fixture { _ in (200, Data(#"{"unexpected":[]}"#.utf8)) }
        do { _ = try await client.localModels(provider: provider(.ollama), apiKey: nil); XCTFail("Expected invalid list") }
        catch { XCTAssertTrue(error is FrogError) }
    }

    private var client: LLMClient { LLMClient(session: session) }
    private func provider(_ kind: ProviderKind) -> ProviderConfiguration {
        let path = kind == .gemini ? "/v1beta" : ([.openAI, .compatible, .lmStudio].contains(kind) ? "/v1" : "")
        return ProviderConfiguration(kind: kind, endpoint: "https://\(host!)\(path)", model: kind == .gemini ? "models/gemini-test" : "test-model")
    }
    private func complete(_ kind: ProviderKind) async throws -> String {
        try await client.complete(text: "Text", rule: Rule(instructions: "Instructions"), provider: provider(kind), apiKey: "key")
    }
    private func fixture(_ handler: @escaping (URLRequest) throws -> (Int, Data)?) {
        FixtureProtocol.lock.lock(); defer { FixtureProtocol.lock.unlock() }
        FixtureProtocol.handlers[host] = handler
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
