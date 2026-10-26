import Foundation
import FrogCore
import XCTest

/// Answers requests from a table instead of the network, and records what was asked.
final class PluginStubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var redirect: String?
    }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        let answer = Self.answers[url.absoluteString] ?? Answer(status: 404)
        if let redirect = answer.redirect, let target = URL(string: redirect) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PluginNetworkTests: XCTestCase {
    private var network: PluginNetwork!

    override func setUp() {
        PluginStubProtocol.answers = [:]
        PluginStubProtocol.requests = []
        network = PluginNetwork(userAgent: "Frog test", protocolClasses: [PluginStubProtocol.self])
    }

    func testAnApprovedHostAnswersWithoutCookies() async throws {
        PluginStubProtocol.answers["https://api.example.com/items"] = .init(headers: ["Content-Type": "application/json", "Set-Cookie": "a=b"], body: Data("[1,2]".utf8))
        let response = try await network.fetch(PluginFetchRequest(url: URL(string: "https://api.example.com/items")!, headers: ["Authorization": "Bearer x"]),
                                               hosts: ["api.example.com"])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, "[1,2]")
        XCTAssertNil(response.headers["set-cookie"])
        XCTAssertEqual(PluginStubProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent"), "Frog test")
        XCTAssertEqual(PluginStubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer x")
    }

    func testOtherHostsPlainHTTPAndReservedHeadersAreRefusedBeforeSending() async {
        let cases: [(PluginFetchRequest, [String])] = [
            (PluginFetchRequest(url: URL(string: "https://evil.example.org/")!), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "http://api.example.com/")!), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "https://api.example.com:8443/")!), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "https://api.example.com/")!, headers: ["Cookie": "a=b"]), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "https://api.example.com/")!, headers: ["X-Test": "a\r\nHost: b"]), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "https://api.example.com/")!, headers: ["X-Test": "a\nb"]), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "https://api.example.com/")!, method: "CONNECT"), ["api.example.com"]),
            (PluginFetchRequest(url: URL(string: "file:///etc/passwd")!), ["api.example.com"]),
        ]
        for (request, hosts) in cases {
            do { _ = try await network.fetch(request, hosts: hosts); XCTFail("\(request.url) \(request.headers) was sent.") } catch {}
        }
        XCTAssertTrue(PluginStubProtocol.requests.isEmpty)
    }

    func testARedirectToAnotherHostIsNotFollowed() async throws {
        PluginStubProtocol.answers["https://api.example.com/go"] = .init(redirect: "https://evil.example.org/steal")
        PluginStubProtocol.answers["https://evil.example.org/steal"] = .init(body: Data("stolen".utf8))
        // A server's redirect comes back as the 302 itself; the stub ends the load instead. Either way the other
        // host is never asked.
        if let response = try? await network.fetch(PluginFetchRequest(url: URL(string: "https://api.example.com/go")!), hosts: ["api.example.com"]) {
            XCTAssertEqual(response.status, 302)
        }
        XCTAssertFalse(PluginStubProtocol.requests.contains { $0.url?.host == "evil.example.org" })
    }

    func testALargeResponseIsCutOff() async {
        PluginStubProtocol.answers["https://api.example.com/big"] = .init(body: Data(count: PluginNetwork.maximumResponseBytes + 1))
        do {
            _ = try await network.fetch(PluginFetchRequest(url: URL(string: "https://api.example.com/big")!), hosts: ["api.example.com"])
            XCTFail("A response over the limit was returned.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The response is larger than 5 MB.")
        }
    }
}
