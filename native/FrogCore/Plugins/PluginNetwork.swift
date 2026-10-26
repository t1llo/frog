import Foundation

/// A request a plugin page makes with `frog.fetch`.
public struct PluginFetchRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// The body comes back as base64 instead of text.
    public var base64: Bool

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, base64: Bool = false) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.base64 = base64
    }
}

public struct PluginFetchResponse: Sendable {
    public var status: Int
    public var url: String
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: String

    public var dictionary: [String: Any] { ["status": status, "ok": (200..<300).contains(status), "url": url, "headers": headers, "body": body] }
}

/// The only way a plugin reaches the internet: requests to the hosts its manifest lists and the user approved,
/// over https (or http to this Mac), without cookies, cache or credentials Frog holds, and with a size limit.
public final class PluginNetwork: Sendable {
    public static let maximumResponseBytes = 5 * 1024 * 1024
    public static let maximumRequestBytes = 1024 * 1024
    public static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]
    /// Headers URLSession or the network owns; a plugin cannot set them.
    static let reservedHeaders: Set<String> = ["host", "cookie", "cookie2", "content-length", "connection", "keep-alive", "transfer-encoding",
                                               "te", "trailer", "upgrade", "expect", "proxy-authorization", "proxy-connection", "via", "origin", "referer"]
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String, protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    deinit { session.invalidateAndCancel() }

    /// Checks the request against `hosts` before anything is sent, and every redirect it follows.
    public func fetch(_ request: PluginFetchRequest, hosts: [String]) async throws -> PluginFetchResponse {
        guard PluginHost.allows(request.url, hosts: hosts) else {
            throw PluginError.invalid("This plugin may not connect to \(request.url.host ?? request.url.absoluteString). It can reach \(hosts.joined(separator: ", ")).")
        }
        let method = request.method.uppercased()
        guard Self.methods.contains(method) else { throw PluginError.invalid("\(request.method) is not a request method a plugin can use.") }
        guard (request.body?.count ?? 0) <= Self.maximumRequestBytes else { throw PluginError.invalid("A request body can be at most 1 MB.") }
        guard request.headers.count <= 50 else { throw PluginError.invalid("A request can have at most 50 headers.") }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            let lower = name.lowercased()
            guard !name.isEmpty, name.count <= 100, value.utf8.count <= 8 * 1024,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
                  !value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) else {
                throw PluginError.invalid("The header “\(name.prefix(100))” is not allowed.")
            }
            guard !Self.reservedHeaders.contains(lower), !lower.hasPrefix("sec-"), !lower.hasPrefix("proxy-") else {
                throw PluginError.invalid("Frog sets the \(name) header itself.")
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body = request.body, method != "GET", method != "HEAD" { urlRequest.httpBody = body }

        let (bytes, response) = try await session.bytes(for: urlRequest, delegate: RedirectCheck(hosts: hosts))
        guard let http = response as? HTTPURLResponse else { throw PluginError.invalid("The server did not answer over HTTP.") }
        if http.expectedContentLength > Int64(Self.maximumResponseBytes) { throw PluginError.invalid("The response is larger than 5 MB.") }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumResponseBytes { throw PluginError.invalid("The response is larger than 5 MB.") }
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, key.lowercased() != "set-cookie" else { continue }
            headers[key.lowercased()] = "\(value)"
        }
        let body = request.base64 ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
        return PluginFetchResponse(status: http.statusCode, url: http.url?.absoluteString ?? request.url.absoluteString, headers: headers, body: body)
    }
}

/// Follows a redirect only to a host the plugin may reach; otherwise the redirect itself is the answer.
private final class RedirectCheck: NSObject, URLSessionTaskDelegate, Sendable {
    let hosts: [String]
    init(hosts: [String]) { self.hosts = hosts }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, PluginHost.allows(url, hosts: hosts) else { return nil }
        return request
    }
}
