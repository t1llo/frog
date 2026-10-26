import Darwin
import Foundation

public enum AgentSocketError: Error, Equatable, LocalizedError {
    /// Nothing listens at the path: Frog is not running, or agent access is off.
    case unavailable
    case pathTooLong(String)
    case occupied(String)
    case timedOut
    case malformed
    case tooLarge
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Frog is not listening for commands."
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .occupied(let path): "A file that is not Frog's socket is in the way: \(path)"
        case .timedOut: "Frog did not answer in time."
        case .malformed: "Frog sent an answer the tool could not read."
        case .tooLarge: "The message is larger than 16 MB."
        case .system(let message): message
        }
    }
}

/// Plain POSIX calls for one Unix-domain stream socket.
enum UnixSocket {
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw AgentSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func failure(_ call: String) -> AgentSocketError {
        if errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
        return .system("\(call) failed: \(String(cString: strerror(errno)))")
    }

    static func make() throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw failure("socket") }
        noSignalOnClosedPeer(socket)
        return socket
    }

    /// A peer that went away fails the write instead of ending the process.
    static func noSignalOnClosedPeer(_ socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeout(_ socket: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var time = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    static func connect(_ socket: Int32, to path: String) throws {
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result != 0 else { return }
        if errno == ENOENT || errno == ECONNREFUSED { throw AgentSocketError.unavailable }
        throw failure("connect")
    }

    static func writeAll(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("write")
                }
                offset += written
            }
        }
    }

    /// Whether the other end closed the connection. Bytes it sent after its message are read and dropped.
    static func peerClosed(_ socket: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count > 0 { _ = recv(socket, &byte, 1, MSG_DONTWAIT); return false }
        return count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }

    /// Everything up to the first newline; one message per connection.
    static func readLine(_ socket: Int32, limit: Int) throws -> Data {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read")
            }
            guard count > 0 else { throw AgentSocketError.malformed }
            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[0..<newline])
                return line
            }
            line.append(contentsOf: chunk[0..<count])
            if line.count > limit { throw AgentSocketError.tooLarge }
        }
    }
}

/// Sends one command to the running app and waits for its answer.
public enum AgentClient {
    /// Long enough for a script or a writing rule to finish.
    public static let defaultTimeout: TimeInterval = 900

    public static func send(_ request: AgentRequest, to socketURL: URL, timeout: TimeInterval = defaultTimeout) throws -> AgentResponse {
        let socket = try UnixSocket.make()
        defer { close(socket) }
        try UnixSocket.connect(socket, to: socketURL.path)
        UnixSocket.setTimeout(socket, seconds: timeout)
        try UnixSocket.writeAll(socket, AgentWire.encode(request))
        let line = try UnixSocket.readLine(socket, limit: AgentWire.maximumMessageBytes)
        do { return try AgentWire.decode(AgentResponse.self, from: line) }
        catch { throw AgentSocketError.malformed }
    }
}

/// Listens on a Unix-domain socket that only the same user can reach, and answers each
/// connection's one request with `handler`.
public final class AgentListener: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentRequest) async -> AgentResponse

    private let socket: Int32
    private let path: String
    private let identity: (device: dev_t, inode: ino_t)
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "xyz.beffa.frog.agent.accept")
    private let clientQueue = DispatchQueue(label: "xyz.beffa.frog.agent.clients", attributes: .concurrent)
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var stopped = false

    public init(socket url: URL, handler: @escaping Handler) throws {
        path = url.path
        self.handler = handler
        _ = try UnixSocket.address(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.removeStaleSocket(at: path)
        let socket = try UnixSocket.make()
        do {
            var address = try UnixSocket.address(for: path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw UnixSocket.failure("bind") }
            // Only this user may connect; each peer is checked again when it does.
            guard chmod(path, 0o600) == 0, listen(socket, 16) == 0 else {
                let error = UnixSocket.failure("listen"); unlink(path); throw error
            }
            var info = stat()
            guard lstat(path, &info) == 0 else { let error = UnixSocket.failure("lstat"); unlink(path); throw error }
            identity = (info.st_dev, info.st_ino)
            _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        } catch {
            close(socket)
            throw error
        }
        self.socket = socket
        source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptWaiting() }
        source.setCancelHandler { close(socket) }
        source.resume()
    }

    deinit { stop() }

    /// Closes the socket and removes its file, unless another listener has replaced it since.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        source.cancel()
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode { unlink(path) }
    }

    /// A socket left by an earlier run is replaced; any other file is left alone.
    private static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw AgentSocketError.occupied(path) }
        unlink(path)
    }

    private func acceptWaiting() {
        while true {
            let client = accept(socket, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit the listener's non-blocking mode; each client is read blocking with a timeout.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.noSignalOnClosedPeer(client)
            clientQueue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var user = uid_t(), group = gid_t()
        guard getpeereid(client, &user, &group) == 0, user == getuid() else { close(client); return }
        UnixSocket.setTimeout(client, seconds: 10)
        let request: AgentRequest
        do {
            request = try AgentWire.decode(AgentRequest.self, from: UnixSocket.readLine(client, limit: AgentWire.maximumMessageBytes))
        } catch {
            respond(client, .failure("Frog could not read the command.", exitCode: AgentExit.usage))
            return
        }
        let handler = handler
        let work = Task { await handler(request) }
        // The tool sends nothing after its request, so the socket turns readable only when it closes: killed, or
        // out of time. The command is cancelled then, which stops a script it started.
        let hangUp = DispatchSource.makeReadSource(fileDescriptor: client, queue: clientQueue)
        let watching = DispatchGroup()
        watching.enter()
        hangUp.setEventHandler {
            guard UnixSocket.peerClosed(client) else { return }
            work.cancel(); hangUp.cancel()
        }
        hangUp.setCancelHandler { watching.leave() }
        hangUp.resume()
        Task { [self] in
            let response = await work.value
            hangUp.cancel()
            // The socket is closed only once the watch on it has ended.
            watching.notify(queue: clientQueue) { [self] in respond(client, response) }
        }
    }

    private func respond(_ client: Int32, _ response: AgentResponse) {
        UnixSocket.setTimeout(client, seconds: 30)
        if let data = try? AgentWire.encode(response) { try? UnixSocket.writeAll(client, data) }
        close(client)
    }
}
