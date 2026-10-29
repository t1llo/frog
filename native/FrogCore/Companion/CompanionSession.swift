import Foundation
import os

/// A two-way, ordered byte stream. TCP and the Bluetooth GATT pipe both look like this, so one
/// `CompanionSession` runs the protocol over either.
@MainActor
public protocol CompanionPipe: AnyObject {
    var transport: CompanionTransport { get }
    /// For logs only; it names no device.
    var label: String { get }
    /// Bytes in arrival order; chunk boundaries mean nothing.
    var onReceive: ((Data) -> Void)? { get set }
    /// Called once when the pipe goes away, whoever closed it.
    var onClose: (() -> Void)? { get set }

    func start()
    func send(_ data: Data)
    func close()
}

/// A secret the Mac may use for a client: the stored one, or the pending pairing secret.
public struct CompanionSecretCandidate: Sendable, Equatable {
    public var secret: Data
    public var isPending: Bool
    public init(secret: Data, isPending: Bool) { self.secret = secret; self.isPending = isPending }
}

public enum CompanionReceiveResult: Sendable, Equatable {
    /// Stored now: acknowledge it.
    case stored
    /// Seen before: dropped silently, still acknowledged.
    case duplicate
    /// Could not be stored: no acknowledgement, so the phone may send it again.
    case failed
}

@MainActor
public protocol CompanionSessionDelegate: AnyObject {
    func session(_ session: CompanionSession, secretsForClient clientID: UUID) -> [CompanionSecretCandidate]
    func sessionDidEstablish(_ session: CompanionSession, using candidate: CompanionSecretCandidate)
    func session(_ session: CompanionSession, didReceiveClip header: CompanionClipHeader, body: Data) -> CompanionReceiveResult
    func session(_ session: CompanionSession, didReceiveAck clipID: String)
    func sessionDidReceiveUnpair(_ session: CompanionSession)
    func sessionDidClose(_ session: CompanionSession)
}

/// Runs Frog Companion protocol v1 as the server, the Mac, over any `CompanionPipe`.
@MainActor
public final class CompanionSession {
    public enum Phase {
        case awaitingHandshake
        case awaitingHello(clientID: UUID, clientNonce: Data, serverNonce: Data, candidates: [CompanionSecretCandidate])
        case established
        case closed
    }

    public enum Failure: Error {
        case unknownClient
        case expectedHello
        case notEstablished
    }

    public let id = UUID()
    public let pipe: any CompanionPipe
    public weak var delegate: (any CompanionSessionDelegate)?

    public private(set) var phase: Phase = .awaitingHandshake
    public private(set) var peerID: UUID?
    public private(set) var peerName = ""
    public private(set) var peerPlatform = ""

    public var transport: CompanionTransport { pipe.transport }
    public var isEstablished: Bool { if case .established = phase { true } else { false } }
    public var isClosed: Bool { if case .closed = phase { true } else { false } }

    private let localID: UUID
    private let localName: String
    private var reader = CompanionFrameReader()
    private var sealer: CompanionFrameSealer?
    private var opener: CompanionFrameOpener?
    private var lastSent = Date()
    private var lastReceived = Date()
    private var ticker: Task<Void, Never>?
    private let clock: () -> Date
    private let tickInterval: Duration?
    private static let log = Logger(subsystem: "frog", category: "phone")

    /// `tickInterval` nil leaves the timers to `tick()`, which tests call with their own clock.
    public init(pipe: any CompanionPipe, localID: UUID, localName: String,
                clock: @escaping () -> Date = Date.init, tickInterval: Duration? = .seconds(1)) {
        self.pipe = pipe
        self.localID = localID
        self.localName = localName
        self.clock = clock
        self.tickInterval = tickInterval
    }

    public func start() {
        pipe.onReceive = { [weak self] data in self?.receive(data) }
        pipe.onClose = { [weak self] in self?.close(reason: "pipe closed") }
        lastSent = clock()
        lastReceived = clock()
        pipe.start()
        guard let tickInterval else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                self?.tick()
            }
        }
    }

    // MARK: Sending

    public func send(_ message: CompanionMessage) throws {
        guard isEstablished, var sealer else { throw Failure.notEstablished }
        let frame = try sealer.seal(message.encoded())
        self.sealer = sealer
        pipe.send(frame)
        lastSent = clock()
    }

    /// Sends `unpair`, as far as it goes, and closes.
    public func sendUnpairAndClose() {
        try? send(.unpair)
        close(reason: "unpaired here")
    }

    public func close(reason: String) {
        if case .closed = phase { return }
        Self.log.info("Phone session \(self.pipe.label, privacy: .public) closed: \(reason, privacy: .public)")
        phase = .closed
        ticker?.cancel()
        ticker = nil
        reader = CompanionFrameReader()
        pipe.onReceive = nil
        pipe.onClose = nil
        pipe.close()
        delegate?.sessionDidClose(self)
    }

    // MARK: Receiving

    private func receive(_ data: Data) {
        if case .closed = phase { return }
        lastReceived = clock()
        reader.append(data)
        do {
            try process()
        } catch {
            close(reason: "protocol error: \(error)")
        }
    }

    private func process() throws {
        while true {
            switch phase {
            case .closed:
                return

            case .awaitingHandshake:
                guard let hello = try reader.readHandshake() else { return }
                let candidates = delegate?.session(self, secretsForClient: hello.deviceID) ?? []
                guard !candidates.isEmpty else { throw Failure.unknownClient }
                let mine = CompanionHandshake.random(deviceID: localID)
                pipe.send(mine.encoded())
                lastSent = clock()
                phase = .awaitingHello(clientID: hello.deviceID, clientNonce: hello.nonce, serverNonce: mine.nonce, candidates: candidates)

            case let .awaitingHello(clientID, clientNonce, serverNonce, candidates):
                guard let sealed = try reader.readSealedFrame() else { return }
                // Each candidate secret, the stored one first, is tried on the client's first frame.
                var match: (CompanionKeys, CompanionSecretCandidate, Data)?
                for candidate in candidates {
                    let keys = CompanionKeys.derive(secret: candidate.secret, clientNonce: clientNonce, serverNonce: serverNonce)
                    if let plaintext = try? CompanionFrameCrypto.open(sealed, key: keys.clientToServer, counter: 0) {
                        match = (keys, candidate, plaintext)
                        break
                    }
                }
                guard let (keys, candidate, plaintext) = match else { throw CompanionFrameError.decryptFailed }
                guard case let .hello(name, platform, _) = try CompanionMessage.decode(plaintext) else { throw Failure.expectedHello }
                opener = CompanionFrameOpener(key: keys.clientToServer, counter: 1)
                sealer = CompanionFrameSealer(key: keys.serverToClient)
                peerID = clientID
                peerName = name
                peerPlatform = platform
                phase = .established
                try send(.hello(name: localName, platform: "macos", version: CompanionProtocol.version))
                delegate?.sessionDidEstablish(self, using: candidate)

            case .established:
                guard let sealed = try reader.readSealedFrame(), var opener else { return }
                let plaintext = try opener.open(sealed)
                self.opener = opener
                guard let message = try? CompanionMessage.decode(plaintext) else {
                    Self.log.error("Ignoring a malformed message")
                    continue
                }
                handle(message)
            }
        }
    }

    private func handle(_ message: CompanionMessage) {
        switch message {
        case let .clip(header, body):
            guard body.count == header.size else {
                Self.log.error("Ignoring a clip whose size \(header.size) is not its body's \(body.count)")
                return
            }
            guard body.count <= transport.maxClipSize else {
                Self.log.error("Ignoring a clip of \(body.count) bytes, over the \(self.transport.rawValue, privacy: .public) limit")
                return
            }
            switch delegate?.session(self, didReceiveClip: header, body: body) ?? .failed {
            case .stored, .duplicate: try? send(.ack(id: header.id))
            case .failed: break
            }
        case let .ack(id):
            delegate?.session(self, didReceiveAck: id)
        case .ping:
            try? send(.pong)
        case .unpair:
            delegate?.sessionDidReceiveUnpair(self)
            close(reason: "phone unpaired")
        case .pong, .hello, .unknown:
            break
        }
    }

    // MARK: Timers

    /// Closes after 60 s of silence and pings after 15 s (TCP) or 25 s (Bluetooth) without sending.
    public func tick() {
        let now = clock()
        if now.timeIntervalSince(lastReceived) >= CompanionProtocol.receiveTimeout {
            close(reason: "timeout")
            return
        }
        if isEstablished, now.timeIntervalSince(lastSent) >= transport.pingInterval {
            try? send(.ping)
        }
    }
}
