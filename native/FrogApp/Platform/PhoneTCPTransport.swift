import FrogCore
import Foundation
import Network
import os

/// One accepted TCP connection from a phone.
@MainActor
final class PhoneTCPPipe: CompanionPipe {
    let transport = CompanionTransport.tcp
    let label = "tcp"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private var closed = false

    init(connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.onReceive?(data) }
                if isComplete || error != nil { self.close() } else if !self.closed { self.receiveNext() }
            }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        onReceive = nil
        handler?()
    }
}

/// Listens on TCP 47321, or any free port when that one is taken, and advertises
/// `_frogcompanion._tcp` with TXT `id=<mac uuid>`. Created only while Phone is on.
@MainActor
final class PhoneTCPServer {
    var onNewPipe: ((PhoneTCPPipe) -> Void)?
    /// The bound port, nil while not listening.
    var onPortChange: ((UInt16?) -> Void)?

    private(set) var port: UInt16?
    private var listener: NWListener?
    private let deviceID: UUID
    private var retryTask: Task<Void, Never>?
    private var stopped = false
    private let log = Logger(subsystem: "frog", category: "phone")

    init(deviceID: UUID) { self.deviceID = deviceID }

    func start() {
        stopped = false
        listen(on: NWEndpoint.Port(rawValue: CompanionProtocol.defaultTCPPort)!)
    }

    func stop() {
        stopped = true
        retryTask?.cancel(); retryTask = nil
        listener?.cancel(); listener = nil
        setPort(nil)
    }

    private func listen(on port: NWEndpoint.Port) {
        guard !stopped else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            log.error("Phone listener could not start: \(error.localizedDescription, privacy: .public)")
            if port != .any { listen(on: .any) } else { scheduleRetry() }
            return
        }
        var txt = NWTXTRecord()
        txt["id"] = deviceID.companionString
        listener.service = NWListener.Service(name: nil, type: CompanionProtocol.bonjourType, domain: nil, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.setPort(listener.port?.rawValue)
                case .failed(let error):
                    self.log.error("Phone listener failed: \(error.localizedDescription, privacy: .public)")
                    listener.cancel()
                    self.listener = nil
                    self.setPort(nil)
                    if port != .any, case .posix(.EADDRINUSE) = error { self.listen(on: .any) } else { self.scheduleRetry() }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { connection.cancel(); return }
                self.onNewPipe?(PhoneTCPPipe(connection: connection))
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.stopped, self.listener == nil else { return }
            self.start()
        }
    }

    private func setPort(_ value: UInt16?) {
        guard port != value else { return }
        port = value
        onPortChange?(value)
    }
}

enum PhoneNetwork {
    /// IPv4 addresses of interfaces that are up, Ethernet and Wi-Fi first; no loopback, link-local,
    /// VPN tunnel or AirDrop interfaces.
    static func ipv4Addresses() -> [String] {
        var result: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !address.hasPrefix("169.254.") else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            result.append((name, address))
        }
        let sorted = result.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }
        var seen = Set<String>()
        return sorted.map(\.address).filter { seen.insert($0).inserted }
    }
}
