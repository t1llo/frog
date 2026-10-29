import Foundation

/// Constants of the Frog Companion protocol, version 1 (docs/companion-protocol.md). Everything under
/// `Companion/` is pure Foundation and CryptoKit, so the tests run it over in-memory pipes.
public enum CompanionProtocol {
    public static let version = 1

    /// `FRG1`
    public static let magic = Data([0x46, 0x52, 0x47, 0x31])
    public static let nonceLength = 32
    public static let deviceIDLength = 16
    public static let handshakeLength = 4 + 16 + 32
    public static let secretLength = 32

    public static let tagLength = 16
    public static let minSealedLength = 16
    /// 256 MiB + 1 KiB
    public static let maxSealedLength = 268_436_480

    public static let maxClipTCP = 200 * 1024 * 1024
    public static let maxClipBluetooth = 1024 * 1024

    public static let pingIntervalTCP: TimeInterval = 15
    public static let pingIntervalBluetooth: TimeInterval = 25
    public static let receiveTimeout: TimeInterval = 60

    public static let rememberedClipIDs = 64

    public static let defaultTCPPort: UInt16 = 47321
    public static let bonjourType = "_frogcompanion._tcp"

    public static let bleServiceUUID = "F0C00001-2A32-4AC4-AF29-8824B655BF6F"
    public static let bleRxUUID = "F0C00002-2A32-4AC4-AF29-8824B655BF6F"
    public static let bleTxUUID = "F0C00003-2A32-4AC4-AF29-8824B655BF6F"
    /// An ATT value is at most 512 bytes, whatever the MTU.
    public static let maxBluetoothChunk = 512

    public static let infoC2S = Data("frog-companion/v1/c2s".utf8)
    public static let infoS2C = Data("frog-companion/v1/s2c".utf8)
}

/// The two ways a phone reaches the Mac.
public enum CompanionTransport: String, Sendable, Codable, Hashable {
    case tcp
    case bluetooth

    public var maxClipSize: Int {
        switch self {
        case .tcp: CompanionProtocol.maxClipTCP
        case .bluetooth: CompanionProtocol.maxClipBluetooth
        }
    }

    public var pingInterval: TimeInterval {
        switch self {
        case .tcp: CompanionProtocol.pingIntervalTCP
        case .bluetooth: CompanionProtocol.pingIntervalBluetooth
        }
    }
}

extension UUID {
    /// The 16 raw bytes used on the wire.
    public var companionBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    public init?(companionBytes data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                         b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Lowercase hyphenated form, as used everywhere except the wire.
    public var companionString: String { uuidString.lowercased() }
}

/// Byte helpers of the protocol, kept out of `Data`'s own namespace.
public enum CompanionBytes {
    /// RFC 4648 §5 without padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64URL string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if s.contains("=") { return nil }
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    public static func data(hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let pair = String(bytes: chars[i..<i + 2], encoding: .ascii), let byte = UInt8(pair, radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return out
    }

    public static func bigEndian(_ value: UInt32) -> Data {
        Swift.withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    public static func bigEndian(_ value: UInt64) -> Data {
        Swift.withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// The big-endian u32 `offset` bytes from the start of `data`.
    public static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }

    public static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
