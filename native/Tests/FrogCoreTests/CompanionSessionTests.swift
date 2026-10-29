import Foundation
import XCTest
@testable import FrogCore

/// What the session sends is collected; the test feeds bytes in.
@MainActor
final class MemoryCompanionPipe: CompanionPipe {
    let transport: CompanionTransport
    let label = "memory"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var sent = Data()
    var closed = false

    init(transport: CompanionTransport = .tcp) { self.transport = transport }
    func start() {}
    func send(_ data: Data) { sent.append(data) }
    func close() { closed = true; onClose?() }

    /// Feeds bytes a few at a time, like a slow Bluetooth link.
    func feed(_ data: Data, chunk: Int = 5) {
        var i = data.startIndex
        while i < data.endIndex {
            let end = min(i + chunk, data.endIndex)
            onReceive?(data[i..<end])
            i = end
        }
    }

    func takeSent() -> Data { defer { sent = Data() }; return sent }
}

@MainActor
final class RecordingCompanionDelegate: CompanionSessionDelegate {
    var candidates: [CompanionSecretCandidate] = []
    var established: CompanionSecretCandidate?
    var clips: [CompanionClipHeader] = []
    var acks: [String] = []
    var unpaired = false
    var closed = false
    var seen = Set<String>()

    func session(_ session: CompanionSession, secretsForClient clientID: UUID) -> [CompanionSecretCandidate] { candidates }
    func sessionDidEstablish(_ session: CompanionSession, using candidate: CompanionSecretCandidate) { established = candidate }
    func session(_ session: CompanionSession, didReceiveClip header: CompanionClipHeader, body: Data) -> CompanionReceiveResult {
        if !seen.insert(header.id).inserted { return .duplicate }
        clips.append(header)
        return .stored
    }
    func session(_ session: CompanionSession, didReceiveAck clipID: String) { acks.append(clipID) }
    func sessionDidReceiveUnpair(_ session: CompanionSession) { unpaired = true }
    func sessionDidClose(_ session: CompanionSession) { closed = true }
}

/// The phone's side of the protocol, written from docs/companion-protocol.md.
struct FakeCompanionClient {
    let id = UUID()
    let secret: Data
    let nonce = CompanionBytes.random(count: 32)
    var sealer: CompanionFrameSealer?
    var opener: CompanionFrameOpener?
    var reader = CompanionFrameReader()

    var handshake: CompanionHandshake { CompanionHandshake(deviceID: id, nonce: nonce) }

    mutating func receiveServerHandshake(_ bytes: Data, macID: UUID) throws {
        reader.append(bytes)
        let server = try XCTUnwrap(try reader.readHandshake())
        XCTAssertEqual(server.deviceID, macID)
        let keys = CompanionKeys.derive(secret: secret, clientNonce: nonce, serverNonce: server.nonce)
        sealer = CompanionFrameSealer(key: keys.clientToServer)
        opener = CompanionFrameOpener(key: keys.serverToClient)
    }

    mutating func frame(_ message: CompanionMessage) throws -> Data { try sealer!.seal(message.encoded()) }

    mutating func messages(_ bytes: Data) throws -> [CompanionMessage] {
        reader.append(bytes)
        var out: [CompanionMessage] = []
        while let sealed = try reader.readSealedFrame() { out.append(try CompanionMessage.decode(try opener!.open(sealed))) }
        return out
    }
}

@MainActor
final class CompanionSessionTests: XCTestCase {
    private let macID = UUID()
    private var now = Date(timeIntervalSince1970: 1_000)
    /// The app keeps its sessions; so does the test, since a pipe holds its session only weakly.
    private var sessions: [CompanionSession] = []

    private func makeSession(_ pipe: MemoryCompanionPipe, _ delegate: RecordingCompanionDelegate) -> CompanionSession {
        let session = CompanionSession(pipe: pipe, localID: macID, localName: "Test Mac",
                                       clock: { [unowned self] in self.now }, tickInterval: nil)
        session.delegate = delegate
        session.start()
        sessions.append(session)
        return session
    }

    private func connect(secret: Data, candidates: [CompanionSecretCandidate], transport: CompanionTransport = .tcp)
        throws -> (CompanionSession, MemoryCompanionPipe, RecordingCompanionDelegate, FakeCompanionClient) {
        let pipe = MemoryCompanionPipe(transport: transport)
        let delegate = RecordingCompanionDelegate()
        delegate.candidates = candidates
        let session = makeSession(pipe, delegate)
        var client = FakeCompanionClient(secret: secret)
        pipe.feed(client.handshake.encoded())
        let serverHandshake = pipe.takeSent()
        XCTAssertEqual(serverHandshake.count, 52)
        try client.receiveServerHandshake(serverHandshake, macID: macID)
        pipe.feed(try client.frame(.hello(name: "Test phone", platform: "android", version: 1)))
        return (session, pipe, delegate, client)
    }

    func testHandshakeHelloClipAckPing() throws {
        let secret = CompanionBytes.random(count: 32)
        var (session, pipe, delegate, client) = try connect(secret: secret, candidates: [.init(secret: secret, isPending: false)])
        XCTAssertTrue(session.isEstablished)
        XCTAssertEqual(session.peerName, "Test phone")
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.hello(name: "Test Mac", platform: "macos", version: 1)])

        let body = Data("hi".utf8)
        let clip = CompanionClipHeader(id: "c1", kind: .text, mime: "text/plain", size: 2)
        pipe.feed(try client.frame(.clip(clip, body: body)))
        pipe.feed(try client.frame(.clip(clip, body: body)))
        pipe.feed(try client.frame(.ping))
        XCTAssertEqual(delegate.clips.map(\.id), ["c1"], "A duplicate is dropped")
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.ack(id: "c1"), .ack(id: "c1"), .pong], "and still acknowledged")

        try session.send(.clip(CompanionClipHeader(id: "m1", kind: .text, mime: "text/plain", size: 1), body: Data("x".utf8)))
        pipe.feed(try client.frame(.ack(id: "m1")))
        XCTAssertEqual(delegate.acks, ["m1"])
        XCTAssertEqual(try client.messages(pipe.takeSent()).count, 1)
        session.close(reason: "test")
    }

    func testPendingSecretIsTriedAfterStoredOne() throws {
        let stale = CompanionBytes.random(count: 32)
        let pending = CompanionBytes.random(count: 32)
        let (session, _, delegate, _) = try connect(secret: pending, candidates: [
            .init(secret: stale, isPending: false), .init(secret: pending, isPending: true),
        ])
        XCTAssertTrue(session.isEstablished)
        XCTAssertEqual(delegate.established?.isPending, true)
        session.close(reason: "test")
    }

    func testUnknownClientIsDisconnected() {
        let pipe = MemoryCompanionPipe()
        let delegate = RecordingCompanionDelegate()
        _ = makeSession(pipe, delegate)
        pipe.feed(CompanionHandshake.random(deviceID: UUID()).encoded())
        XCTAssertTrue(pipe.sent.isEmpty)
        XCTAssertTrue(pipe.closed)
        XCTAssertTrue(delegate.closed)
    }

    func testWrongSecretCloses() throws {
        let (session, pipe, delegate, _) = try connect(secret: CompanionBytes.random(count: 32),
                                                       candidates: [.init(secret: CompanionBytes.random(count: 32), isPending: false)])
        XCTAssertFalse(session.isEstablished)
        XCTAssertTrue(pipe.closed && delegate.closed)
    }

    func testFirstFrameMustBeHello() throws {
        let secret = CompanionBytes.random(count: 32)
        let pipe = MemoryCompanionPipe()
        let delegate = RecordingCompanionDelegate()
        delegate.candidates = [.init(secret: secret, isPending: false)]
        _ = makeSession(pipe, delegate)
        var client = FakeCompanionClient(secret: secret)
        pipe.feed(client.handshake.encoded())
        try client.receiveServerHandshake(pipe.takeSent(), macID: macID)
        pipe.feed(try client.frame(.ping))
        XCTAssertTrue(pipe.closed)
    }

    func testOversizedBluetoothClipIsNotAcked() throws {
        let secret = CompanionBytes.random(count: 32)
        var (session, pipe, delegate, client) = try connect(secret: secret, candidates: [.init(secret: secret, isPending: false)], transport: .bluetooth)
        _ = pipe.takeSent()
        let big = Data(count: CompanionProtocol.maxClipBluetooth + 1)
        pipe.feed(try client.frame(.clip(CompanionClipHeader(id: "big", kind: .file, mime: "application/octet-stream", name: "b", size: big.count), body: big)), chunk: 4096)
        XCTAssertTrue(delegate.clips.isEmpty)
        XCTAssertTrue(pipe.sent.isEmpty)
        XCTAssertTrue(session.isEstablished)
        session.close(reason: "test")
    }

    func testUnpairForgetsAndCloses() throws {
        let secret = CompanionBytes.random(count: 32)
        var (_, pipe, delegate, client) = try connect(secret: secret, candidates: [.init(secret: secret, isPending: false)])
        pipe.feed(try client.frame(.unpair))
        XCTAssertTrue(delegate.unpaired)
        XCTAssertTrue(pipe.closed && delegate.closed)
    }

    func testPingsWhenIdleAndClosesAfterSilence() throws {
        let secret = CompanionBytes.random(count: 32)
        var (session, pipe, delegate, client) = try connect(secret: secret, candidates: [.init(secret: secret, isPending: false)])
        XCTAssertEqual(try client.messages(pipe.takeSent()).count, 1, "The Mac's hello")
        now += 14
        session.tick()
        XCTAssertTrue(pipe.sent.isEmpty, "No ping before 15 s on TCP")
        now += 1
        session.tick()
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.ping])
        now += 45
        session.tick()
        XCTAssertTrue(pipe.closed && delegate.closed, "Closed after 60 s without receiving anything")
    }
}
