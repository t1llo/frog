import CryptoKit
import Foundation

/// The 52-byte cleartext greeting each side sends first (protocol §2).
public struct CompanionHandshake: Equatable, Sendable {
    public enum DecodeError: Error, Equatable {
        case wrongLength
        case wrongMagic
    }

    public var deviceID: UUID
    public var nonce: Data

    public init(deviceID: UUID, nonce: Data) {
        precondition(nonce.count == CompanionProtocol.nonceLength)
        self.deviceID = deviceID
        self.nonce = nonce
    }

    public static func random(deviceID: UUID) -> CompanionHandshake {
        CompanionHandshake(deviceID: deviceID, nonce: CompanionBytes.random(count: CompanionProtocol.nonceLength))
    }

    public func encoded() -> Data {
        var out = Data(capacity: CompanionProtocol.handshakeLength)
        out.append(CompanionProtocol.magic)
        out.append(deviceID.companionBytes)
        out.append(nonce)
        return out
    }

    public static func decode(_ data: Data) throws -> CompanionHandshake {
        guard data.count == CompanionProtocol.handshakeLength else { throw DecodeError.wrongLength }
        let bytes = Data(data) // indices from 0
        guard bytes.prefix(4) == CompanionProtocol.magic else { throw DecodeError.wrongMagic }
        guard let id = UUID(companionBytes: bytes.subdata(in: 4..<20)) else { throw DecodeError.wrongLength }
        return CompanionHandshake(deviceID: id, nonce: bytes.subdata(in: 20..<52))
    }
}

/// Per-connection keys (protocol §3).
public struct CompanionKeys: Sendable {
    public let clientToServer: SymmetricKey
    public let serverToClient: SymmetricKey

    /// salt = clientNonce || serverNonce; c2s / s2c = HKDF-SHA256(secret, salt, info, 32).
    public static func derive(secret: Data, clientNonce: Data, serverNonce: Data) -> CompanionKeys {
        let ikm = SymmetricKey(data: secret)
        let salt = clientNonce + serverNonce
        let c2s = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: CompanionProtocol.infoC2S, outputByteCount: 32)
        let s2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: CompanionProtocol.infoS2C, outputByteCount: 32)
        return CompanionKeys(clientToServer: c2s, serverToClient: s2c)
    }
}

extension SymmetricKey {
    /// The key's bytes, for the test vector.
    public var companionData: Data { withUnsafeBytes { Data($0) } }
}

public enum CompanionFrameError: Error, Equatable {
    case invalidLength(UInt32)
    case decryptFailed
}

public enum CompanionFrameCrypto {
    /// 4 zero bytes followed by the u64 counter, big-endian (protocol §4).
    public static func nonce(counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        bytes.append(CompanionBytes.bigEndian(counter))
        // Twelve bytes always make a valid nonce.
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// AES-256-GCM, no additional data. Returns ciphertext || 16-byte tag.
    public static func seal(_ plaintext: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(counter: counter))
        var out = Data(capacity: plaintext.count + CompanionProtocol.tagLength)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public static func open(_ sealed: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        guard sealed.count >= CompanionProtocol.tagLength else { throw CompanionFrameError.decryptFailed }
        let split = sealed.endIndex - CompanionProtocol.tagLength
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce(counter: counter), ciphertext: sealed[sealed.startIndex..<split], tag: sealed[split...])
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CompanionFrameError.decryptFailed
        }
    }
}

/// Seals outgoing plaintexts into length-prefixed frames, one counter per direction.
public struct CompanionFrameSealer: Sendable {
    public let key: SymmetricKey
    public private(set) var counter: UInt64

    public init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    /// The whole wire frame: u32 N || sealed.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let sealed = try CompanionFrameCrypto.seal(plaintext, key: key, counter: counter)
        counter += 1
        var frame = Data(capacity: 4 + sealed.count)
        frame.append(CompanionBytes.bigEndian(UInt32(sealed.count)))
        frame.append(sealed)
        return frame
    }
}

/// Opens incoming sealed frames in order.
public struct CompanionFrameOpener: Sendable {
    public let key: SymmetricKey
    public private(set) var counter: UInt64

    public init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    public mutating func open(_ sealed: Data) throws -> Data {
        let plaintext = try CompanionFrameCrypto.open(sealed, key: key, counter: counter)
        counter += 1
        return plaintext
    }
}

/// A growable byte queue that reads from the front without shifting on every read.
public struct CompanionByteQueue: Sendable {
    private var storage = Data()
    private var offset = 0

    public init() {}

    public var count: Int { storage.count - offset }

    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    public func peekUInt32() -> UInt32? {
        guard count >= 4 else { return nil }
        return CompanionBytes.uint32(storage, at: offset)
    }

    public mutating func read(_ n: Int) -> Data? {
        guard count >= n else { return nil }
        let start = storage.startIndex + offset
        let out = storage.subdata(in: start..<start + n)
        offset += n
        if offset == storage.count {
            storage = Data()
            offset = 0
        } else if offset >= 64 * 1024 && offset * 2 >= storage.count {
            storage = storage.subdata(in: storage.startIndex + offset..<storage.endIndex)
            offset = 0
        }
        return out
    }

    public mutating func removeAll() {
        storage = Data()
        offset = 0
    }
}

/// Splits an incoming byte stream into the 52-byte handshake and then sealed frames.
/// Chunk boundaries mean nothing; append whatever arrives.
public struct CompanionFrameReader: Sendable {
    private var queue = CompanionByteQueue()

    public init() {}

    public var bufferedCount: Int { queue.count }

    public mutating func append(_ data: Data) {
        queue.append(data)
    }

    public mutating func readHandshake() throws -> CompanionHandshake? {
        guard let bytes = queue.read(CompanionProtocol.handshakeLength) else { return nil }
        return try CompanionHandshake.decode(bytes)
    }

    /// The next `sealed` payload without its length, or nil while incomplete. Throws as soon as a
    /// length outside 16...268,436,480 is seen.
    public mutating func readSealedFrame() throws -> Data? {
        guard let n = queue.peekUInt32() else { return nil }
        guard n >= UInt32(CompanionProtocol.minSealedLength), n <= UInt32(CompanionProtocol.maxSealedLength) else {
            throw CompanionFrameError.invalidLength(n)
        }
        guard queue.count >= 4 + Int(n) else { return nil }
        _ = queue.read(4)
        return queue.read(Int(n))
    }
}
