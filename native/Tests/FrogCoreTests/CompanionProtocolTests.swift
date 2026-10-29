import CryptoKit
import Foundation
import XCTest
@testable import FrogCore

/// Fixed inputs shared with the Android test suite (docs/companion-protocol.md).
enum CompanionVector {
    static let secret = Data((1...32).map { UInt8($0) })
    static let clientNonce = Data(repeating: 0xAA, count: 32)
    static let serverNonce = Data(repeating: 0xBB, count: 32)

    static let c2sKey = "5355498ae5f203661e50e4e064acb33cbbeb43f4851f39e2dc2d2ed5668984b5"
    static let s2cKey = "8055a20a0dfd55bffdc36ad3d33186134b5e86d31f725fa423f05d4305ac5567"
    /// `{"type":"ping"}`: u32 15 || JSON, no body.
    static let pingPlaintext = "0000000f7b2274797065223a2270696e67227d"
    /// ciphertext || tag of the ping plaintext with c2sKey, counter 0.
    static let pingSealedC2S = "a19c5320891251aad8d438e524d9aac75ab0589cb4e3edcf9857dc1e616bce7fa29458"

    static var keys: CompanionKeys { CompanionKeys.derive(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce) }
}

final class CompanionKeyTests: XCTestCase {
    func testFixedVector() {
        let keys = CompanionVector.keys
        XCTAssertEqual(CompanionBytes.hex(keys.clientToServer.companionData), CompanionVector.c2sKey)
        XCTAssertEqual(CompanionBytes.hex(keys.serverToClient.companionData), CompanionVector.s2cKey)
    }

    func testSaltOrderAndDirectionMatter() {
        let a = CompanionVector.keys
        let b = CompanionKeys.derive(secret: CompanionVector.secret, clientNonce: CompanionVector.serverNonce, serverNonce: CompanionVector.clientNonce)
        XCTAssertNotEqual(a.clientToServer.companionData, b.clientToServer.companionData)
        XCTAssertNotEqual(a.clientToServer.companionData, a.serverToClient.companionData)
    }

    /// HKDF-SHA256 per RFC 5869, written out by hand, agrees with CryptoKit.
    func testMatchesManualHKDF() {
        let salt = CompanionVector.clientNonce + CompanionVector.serverNonce
        let prk = Data(HMAC<SHA256>.authenticationCode(for: CompanionVector.secret, using: SymmetricKey(data: salt)))
        let t1 = Data(HMAC<SHA256>.authenticationCode(for: Data("frog-companion/v1/c2s".utf8) + Data([1]), using: SymmetricKey(data: prk)))
        XCTAssertEqual(CompanionVector.keys.clientToServer.companionData, t1)
    }
}

final class CompanionFrameTests: XCTestCase {
    private let keys = CompanionVector.keys

    func testNonceLayout() {
        XCTAssertEqual(CompanionBytes.hex(Data(CompanionFrameCrypto.nonce(counter: 0x0102030405060708))), "000000000102030405060708")
        XCTAssertEqual(CompanionBytes.hex(Data(CompanionFrameCrypto.nonce(counter: 0))), String(repeating: "0", count: 24))
    }

    func testPingVector() throws {
        let plaintext = CompanionMessage.ping.encoded()
        XCTAssertEqual(CompanionBytes.hex(plaintext), CompanionVector.pingPlaintext)
        let sealed = try CompanionFrameCrypto.seal(plaintext, key: keys.clientToServer, counter: 0)
        XCTAssertEqual(CompanionBytes.hex(sealed), CompanionVector.pingSealedC2S)
        XCTAssertEqual(try CompanionFrameCrypto.open(sealed, key: keys.clientToServer, counter: 0), plaintext)

        var sealer = CompanionFrameSealer(key: keys.clientToServer)
        let frame = try sealer.seal(plaintext)
        XCTAssertEqual(CompanionBytes.hex(frame.prefix(4)), "00000023")
        XCTAssertEqual(CompanionBytes.hex(frame.dropFirst(4)), CompanionVector.pingSealedC2S)
    }

    func testCountersAdvanceAndMustMatch() throws {
        var sealer = CompanionFrameSealer(key: keys.serverToClient)
        let messages: [CompanionMessage] = [.ping, .pong, .ack(id: "x"), .unpair]
        var wire = Data()
        for message in messages { wire.append(try sealer.seal(message.encoded())) }
        XCTAssertEqual(sealer.counter, 4)

        var reader = CompanionFrameReader()
        var opener = CompanionFrameOpener(key: keys.serverToClient)
        var opened: [CompanionMessage] = []
        var index = wire.startIndex
        while index < wire.endIndex {
            let end = min(index + 7, wire.endIndex)
            reader.append(wire[index..<end])
            index = end
            while let sealed = try reader.readSealedFrame() {
                opened.append(try CompanionMessage.decode(try opener.open(sealed)))
            }
        }
        XCTAssertEqual(opened, messages)

        var fresh = CompanionFrameSealer(key: keys.serverToClient)
        let frame = Data(try fresh.seal(CompanionMessage.ping.encoded()).dropFirst(4))
        XCTAssertThrowsError(try CompanionFrameCrypto.open(frame, key: keys.serverToClient, counter: 1))
        XCTAssertThrowsError(try CompanionFrameCrypto.open(frame, key: keys.clientToServer, counter: 0))
        var tampered = frame
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try CompanionFrameCrypto.open(tampered, key: keys.serverToClient, counter: 0))
    }

    func testFrameLengthLimits() throws {
        var small = CompanionFrameReader()
        small.append(CompanionBytes.bigEndian(UInt32(15)))
        XCTAssertThrowsError(try small.readSealedFrame()) { XCTAssertEqual($0 as? CompanionFrameError, .invalidLength(15)) }

        var big = CompanionFrameReader()
        big.append(CompanionBytes.bigEndian(UInt32(268_436_481)))
        XCTAssertThrowsError(try big.readSealedFrame()) { XCTAssertEqual($0 as? CompanionFrameError, .invalidLength(268_436_481)) }

        var max = CompanionFrameReader()
        max.append(CompanionBytes.bigEndian(UInt32(268_436_480)))
        XCTAssertNil(try max.readSealedFrame(), "A valid length waits for its bytes")
    }

    func testHandshakeRoundTrip() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let handshake = CompanionHandshake(deviceID: id, nonce: CompanionVector.clientNonce)
        let bytes = handshake.encoded()
        XCTAssertEqual(bytes.count, 52)
        XCTAssertEqual(CompanionBytes.hex(bytes.prefix(20)), "46524731" + "00112233445566778899aabbccddeeff")
        XCTAssertEqual(try CompanionHandshake.decode(bytes), handshake)

        var bad = bytes
        bad[0] = 0x47
        XCTAssertThrowsError(try CompanionHandshake.decode(bad)) { XCTAssertEqual($0 as? CompanionHandshake.DecodeError, .wrongMagic) }

        var reader = CompanionFrameReader()
        var sealer = CompanionFrameSealer(key: keys.clientToServer)
        reader.append(bytes + (try sealer.seal(CompanionMessage.ping.encoded())))
        XCTAssertEqual(try reader.readHandshake(), handshake)
        XCTAssertNotNil(try reader.readSealedFrame())
    }
}

final class CompanionMessageTests: XCTestCase {
    func testPingIsExact() {
        let data = CompanionMessage.ping.encoded()
        XCTAssertEqual(String(data: data.dropFirst(4), encoding: .utf8), #"{"type":"ping"}"#)
    }

    func testRoundTrips() throws {
        let body = Data("héllo ✓".utf8)
        let messages: [CompanionMessage] = [
            .hello(name: "Test Mac", platform: "macos", version: 1),
            .clip(CompanionClipHeader(id: "clip-1", kind: .text, mime: "text/plain", size: body.count), body: body),
            .clip(CompanionClipHeader(id: "clip-2", kind: .file, mime: "application/pdf", name: "a/b.pdf", size: 3), body: Data([1, 2, 3])),
            .clip(CompanionClipHeader(id: "clip-3", kind: .image, mime: "image/png", size: 0), body: Data()),
            .ack(id: "clip-1"),
            .ping, .pong, .unpair,
        ]
        for message in messages {
            XCTAssertEqual(try CompanionMessage.decode(message.encoded()), message)
        }
    }

    func testLayout() throws {
        let body = Data([0xDE, 0xAD])
        let encoded = CompanionMessage.clip(CompanionClipHeader(id: "i", kind: .image, mime: "image/png", size: 2), body: body).encoded()
        let h = Int(CompanionBytes.uint32(encoded, at: 0))
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.subdata(in: 4..<4 + h)) as? [String: Any])
        XCTAssertEqual(header["type"] as? String, "clip")
        XCTAssertEqual(header["kind"] as? String, "image")
        XCTAssertEqual(header["size"] as? Int, 2)
        XCTAssertNil(header["name"])
        XCTAssertEqual(encoded.suffix(2), body)
    }

    func testUnknownTypesAndFieldsAreTolerated() throws {
        func frame(_ json: String) -> Data {
            let j = Data(json.utf8)
            return CompanionBytes.bigEndian(UInt32(j.count)) + j
        }
        XCTAssertEqual(try CompanionMessage.decode(frame(#"{"type":"future","x":1}"#)), .unknown(type: "future"))
        XCTAssertEqual(try CompanionMessage.decode(frame(#"{"type":"ping","extra":[1,2]}"#)), .ping)
        XCTAssertEqual(try CompanionMessage.decode(frame(#"{"type":"clip","id":"a","kind":"video","mime":"v","size":0}"#)), .unknown(type: "clip"))
        XCTAssertEqual(try CompanionMessage.decode(frame(#"{"type":"hello","name":"Test phone","platform":"android","version":1,"model":"x"}"#)),
                       .hello(name: "Test phone", platform: "android", version: 1))
        XCTAssertThrowsError(try CompanionMessage.decode(frame(#"{"kind":"x"}"#)))
        XCTAssertThrowsError(try CompanionMessage.decode(Data([0, 0, 0, 9, 1])))
    }
}

final class CompanionPairingURLTests: XCTestCase {
    func testFormat() {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let url = CompanionPairingURL(macID: id, macName: "Test’s Mac", secret: CompanionVector.secret,
                                      port: 47321, hosts: ["192.0.2.10", "198.51.100.7"])
        XCTAssertEqual(url.string,
                       "frog://pair?v=1&id=00000000-0000-4000-8000-000000000001&n=Test%E2%80%99s%20Mac"
                       + "&k=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA&p=47321&h=192.0.2.10,198.51.100.7")
        XCTAssertEqual(CompanionPairingURL(string: url.string), url)
    }

    func testReservedCharactersInName() {
        let url = CompanionPairingURL(macID: UUID(), macName: "A&B=C?D#E+F/G", secret: CompanionVector.secret, port: 1, hosts: [])
        XCTAssertTrue(url.string.contains("&n=A%26B%3DC%3FD%23E%2BF%2FG&"))
        XCTAssertTrue(url.string.hasSuffix("&h="))
        XCTAssertEqual(CompanionPairingURL(string: url.string)?.macName, "A&B=C?D#E+F/G")
    }

    func testBase64URL() {
        let data = Data([0xFB, 0xFF, 0xBF, 0x00])
        XCTAssertEqual(CompanionBytes.base64URL(data), "-_-_AA")
        XCTAssertEqual(CompanionBytes.data(base64URL: "-_-_AA"), data)
        XCTAssertNil(CompanionBytes.data(base64URL: "-_-_AA=="))
    }
}

@MainActor
final class PhonePairingStoreTests: XCTestCase {
    func testPhonesPersistAndSecretsStayOutOfTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("frog-phone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = PhonePairingStore.defaultFile(in: folder)
        let secrets = InMemoryPhoneSecretStore()
        let store = PhonePairingStore(fileURL: file, secrets: secrets)
        let phoneID = UUID()
        try store.save(id: phoneID, name: "Test phone", secret: CompanionVector.secret)

        let reloaded = PhonePairingStore(fileURL: file, secrets: secrets)
        XCTAssertEqual(reloaded.macID, store.macID, "The Mac keeps its companion ID")
        XCTAssertEqual(reloaded.phones.map(\.name), ["Test phone"])
        XCTAssertEqual(reloaded.secret(for: phoneID), CompanionVector.secret)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(CompanionBytes.base64URL(CompanionVector.secret)))
        XCTAssertFalse(text.contains(CompanionVector.secret.base64EncodedString()))

        try reloaded.remove(phoneID)
        XCTAssertNil(try secrets.read(phoneID: phoneID))
        XCTAssertTrue(PhonePairingStore(fileURL: file, secrets: secrets).phones.isEmpty)
    }

    func testFileNamesAreSafeAndUnique() throws {
        XCTAssertEqual(CompanionFileSaver.sanitized("../a/b:c"), "-a-b-c")
        XCTAssertEqual(CompanionFileSaver.sanitized("  "), "Phone file")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("frog-phone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try CompanionFileSaver.save(Data([1]), suggestedName: "photo.jpg", in: folder)
        let second = try CompanionFileSaver.save(Data([2]), suggestedName: "photo.jpg", in: folder)
        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        XCTAssertEqual(second.lastPathComponent, "photo 2.jpg")
    }
}
