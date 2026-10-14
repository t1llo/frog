import XCTest
@testable import FrogCore

private final class SpeechFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]
    /// Hosts that answer every request by sending it on with a 307 to another address.
    static var redirects: [String: URL] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        let location = Self.redirects[request.url?.host ?? ""]
        Self.lock.unlock()
        if let location {
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString])!
            var next = request
            next.url = location
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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
    private var elsewhere: String!
    override func setUp() {
        host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        elsewhere = "elsewhere-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        SpeechFixtureProtocol.lock.lock(); defer { SpeechFixtureProtocol.lock.unlock() }
        for host in [host!, elsewhere!] {
            SpeechFixtureProtocol.handlers.removeValue(forKey: host)
            SpeechFixtureProtocol.redirects.removeValue(forKey: host)
        }
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

    func testServiceThatRedirectsDoesNotGetTheRecordingSentOnElsewhere() async throws {
        var forwarded = 0
        SpeechFixtureProtocol.lock.lock()
        SpeechFixtureProtocol.redirects[host] = URL(string: "https://\(elsewhere!)/v1/audio/transcriptions")!
        SpeechFixtureProtocol.handlers[elsewhere] = { _ in forwarded += 1; return (200, Data(#"{"text":"Moved."}"#.utf8)) }
        SpeechFixtureProtocol.lock.unlock()
        do { _ = try await transcribe(); XCTFail("The redirect must be refused") }
        catch {
            XCTAssertEqual(error as? SpeechClient.StatusFailure, SpeechClient.StatusFailure(status: 307))
            XCTAssertEqual(error.localizedDescription, "The speech service redirected the request. Update its base URL to the final endpoint.")
            XCTAssertFalse(SpeechClient.isTransient(error))
        }
        XCTAssertEqual(forwarded, 0, "Neither the recording nor the key may reach the other address")
    }

    func testRequestSkipsTheCacheAndSendsNoCookies() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: host!, .path: "/", .name: "session", .value: "fixture", .secure: "TRUE"]))
        session.configuration.httpCookieStorage?.setCookie(cookie)
        var seen: [URLRequest] = []
        fixture { request in seen.append(request); return (200, Data(#"{"text":"Spoken words."}"#.utf8)) }
        _ = try await transcribe()
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.timeoutInterval, 120)
    }

    func testUnreadableOrOversizedAnswerIsReportedPlainly() async throws {
        fixture { _ in (200, Data("<html>Gateway</html>".utf8)) }
        do { _ = try await transcribe(); XCTFail("A page is not a transcript") }
        catch {
            XCTAssertEqual(error as? FrogError, .message("The speech service returned a response Frog cannot read. Check the endpoint and model."))
            XCTAssertFalse(SpeechClient.isTransient(error))
        }
        fixture { _ in (200, Data(#"{"text":""#.utf8) + Data(repeating: 0x61, count: 8 * 1_024 * 1_024) + Data(#""}"#.utf8)) }
        do { _ = try await transcribe(); XCTFail("An answer over 8 MB is refused") }
        catch {
            XCTAssertEqual(error as? FrogError, .message("The speech service's response was too large."))
            XCTAssertFalse(SpeechClient.isTransient(error))
        }
    }

    func testConnectionFailureNamesNoAddressAndCanStillBeRetried() async throws {
        fixture { request in throw URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString]) }
        do { _ = try await transcribe(); XCTFail("The host was not found") }
        catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotFindHost)
            XCTAssertEqual(error.localizedDescription, "Could not reach the speech service. Check its endpoint and your network connection.")
            XCTAssertFalse(String(describing: (error as NSError).userInfo).contains(host), "The error must not carry the endpoint address")
            XCTAssertTrue(SpeechClient.isTransient(error))
        }
        fixture { _ in throw URLError(.timedOut) }
        do { _ = try await transcribe(); XCTFail("The request timed out") }
        catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertEqual(error.localizedDescription, "The speech request timed out. Try again later.")
            XCTAssertTrue(SpeechClient.isTransient(error))
        }
    }

    func testKeyWithSpacesInsideIsRefusedBeforeTheRecordingIsSent() async throws {
        var requests = 0
        fixture { _ in requests += 1; return (200, Data(#"{"text":"Spoken words."}"#.utf8)) }
        do { _ = try await transcribe(apiKey: "secret test"); XCTFail("A key with a space would break the header") }
        catch { XCTAssertEqual(error as? FrogError, .message("Enter a nonempty API key without spaces or control characters.")) }
        XCTAssertEqual(requests, 0)
    }

    func testEndpointWithSurroundingSpaceIsUsedWithoutIt() async throws {
        fixture { request in
            XCTAssertEqual(request.url?.absoluteString, "https://\(self.host!)/v1/audio/transcriptions")
            return (200, Data(#"{"text":"Spoken words."}"#.utf8))
        }
        let text = try await transcribe(endpoint: " https://\(host!)/v1\n")
        XCTAssertEqual(text, "Spoken words.")
    }

    func testRecordingIsSentAsSixteenBitMonoWaveWithSilenceForUnreadableSamples() {
        let wave = SpeechClient.wave([0, 0.25, -0.25, 1, -1, 2, -2, .nan, .infinity, -.infinity, 0.5])
        XCTAssertEqual([UInt8](wave.prefix(44)), [0x52, 0x49, 0x46, 0x46, 58, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
                                                  0x66, 0x6D, 0x74, 0x20, 16, 0, 0, 0, 1, 0, 1, 0,
                                                  0x80, 0x3E, 0, 0, 0x00, 0x7D, 0, 0, 2, 0, 16, 0,
                                                  0x64, 0x61, 0x74, 0x61, 22, 0, 0, 0])
        let bytes = [UInt8](wave.dropFirst(44))
        let samples = stride(from: 0, to: bytes.count, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
        XCTAssertEqual(samples, [0, 8192, -8192, 32767, -32767, 32767, -32767, 0, 0, 0, 16384])
    }

    private func transcribe(apiKey: String? = "secret-test", endpoint: String? = nil) async throws -> String {
        let provider = ProviderConfiguration(name: "Fixture", kind: .openAI, endpoint: endpoint ?? "https://\(host!)/v1", model: "fixture-speech")
        return try await SpeechClient(session: session).transcribe(samples: Array(repeating: 0.1, count: 1600), provider: provider,
                                                                  model: "fixture-speech", language: "auto", apiKey: apiKey)
    }

    private func fixture(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        SpeechFixtureProtocol.lock.lock(); defer { SpeechFixtureProtocol.lock.unlock() }
        SpeechFixtureProtocol.handlers[host] = handler
    }
}
