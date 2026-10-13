import XCTest
@testable import FrogCore

private final class SpeechFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            let (status, data) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SpeechClientTests: XCTestCase {
    private var session: URLSession!
    private var host: String!
    override func setUp() {
        host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        SpeechFixtureProtocol.lock.lock(); defer { SpeechFixtureProtocol.lock.unlock() }
        SpeechFixtureProtocol.handlers.removeValue(forKey: host)
    }

    func testTranscriptIsReadFromTheServiceAnswer() async throws {
        fixture { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test")
            return (200, Data(#"{"text":"  Spoken words.\n"}"#.utf8))
        }
        let text = try await transcribe()
        XCTAssertEqual(text, "Spoken words.")
    }

    func testBusyServiceCanBeAskedAgainButAWrongKeyOrModelCannot() async throws {
        for (status, transient) in [(408, true), (429, true), (500, true), (502, true), (503, true), (504, true),
                                    (400, false), (401, false), (403, false), (404, false), (422, false)] {
            fixture { _ in (status, Data(#"{"error":"fixture"}"#.utf8)) }
            do { _ = try await transcribe(); XCTFail("HTTP \(status) is a failure") }
            catch {
                XCTAssertEqual(error as? SpeechClient.StatusFailure, SpeechClient.StatusFailure(status: status))
                XCTAssertEqual(error.localizedDescription, "Speech request failed (HTTP \(status)). Check the model, endpoint and API key.")
                XCTAssertEqual(SpeechClient.isTransient(error), transient, "HTTP \(status)")
            }
        }
    }

    func testRequestThatNeverArrivedCanBeSentAgain() async throws {
        fixture { _ in throw URLError(.networkConnectionLost) }
        do { _ = try await transcribe(); XCTFail("The connection was lost") }
        catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
            XCTAssertTrue(SpeechClient.isTransient(error))
        }
        XCTAssertTrue(SpeechClient.isTransient(URLError(.timedOut)))
        XCTAssertTrue(SpeechClient.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(SpeechClient.isTransient(URLError(.cancelled)))
        XCTAssertFalse(SpeechClient.isTransient(CancellationError()))
    }

    func testMissingKeyOrEmptyAnswerIsNotWorthRepeating() async throws {
        var requests = 0
        fixture { _ in requests += 1; return (200, Data(#"{"text":"  "}"#.utf8)) }
        do { _ = try await transcribe(apiKey: " "); XCTFail("A cloud service needs a key") }
        catch {
            XCTAssertEqual(error as? FrogError, .message("Add an API key for Fixture."))
            XCTAssertFalse(SpeechClient.isTransient(error))
        }
        XCTAssertEqual(requests, 0)
        do { _ = try await transcribe(); XCTFail("An empty transcript is a failure") }
        catch {
            XCTAssertEqual(error as? FrogError, .message("The speech model returned no transcript."))
            XCTAssertFalse(SpeechClient.isTransient(error))
        }
        XCTAssertEqual(requests, 1)
    }

    private func transcribe(apiKey: String? = "secret-test") async throws -> String {
        let provider = ProviderConfiguration(name: "Fixture", kind: .openAI, endpoint: "https://\(host!)/v1", model: "fixture-speech")
        return try await SpeechClient(session: session).transcribe(samples: Array(repeating: 0.1, count: 1600), provider: provider,
                                                                  model: "fixture-speech", language: "auto", apiKey: apiKey)
    }

    private func fixture(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        SpeechFixtureProtocol.lock.lock(); defer { SpeechFixtureProtocol.lock.unlock() }
        SpeechFixtureProtocol.handlers[host] = handler
    }
}
