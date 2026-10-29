import Foundation

public enum CompanionClipKind: String, Sendable, Codable, Hashable {
    case text
    case image
    case file
}

public struct CompanionClipHeader: Equatable, Sendable {
    public var id: String
    public var kind: CompanionClipKind
    public var mime: String
    public var name: String?
    public var size: Int

    public init(id: String, kind: CompanionClipKind, mime: String, name: String? = nil, size: Int) {
        self.id = id; self.kind = kind; self.mime = mime; self.name = name; self.size = size
    }
}

/// The plaintext of a frame: u32 H || JSON header || body (protocol §5).
public enum CompanionMessage: Equatable, Sendable {
    case hello(name: String, platform: String, version: Int)
    case clip(CompanionClipHeader, body: Data)
    case ack(id: String)
    case ping
    case pong
    case unpair
    /// A type, or clip kind, this version does not know. Receivers ignore it.
    case unknown(type: String)

    public enum DecodeError: Error, Equatable {
        case truncated
        case badHeader
        case missingField(String)
    }

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .clip: "clip"
        case .ack: "ack"
        case .ping: "ping"
        case .pong: "pong"
        case .unpair: "unpair"
        case .unknown(let type): type
        }
    }

    public func encoded() -> Data {
        var header: [String: Any] = ["type": typeName]
        var body = Data()
        switch self {
        case .hello(let name, let platform, let version):
            header["name"] = name
            header["platform"] = platform
            header["version"] = version
        case .clip(let clip, let clipBody):
            header["id"] = clip.id
            header["kind"] = clip.kind.rawValue
            header["mime"] = clip.mime
            if let name = clip.name { header["name"] = name }
            header["size"] = clip.size
            body = clipBody
        case .ack(let id):
            header["id"] = id
        case .ping, .pong, .unpair, .unknown:
            break
        }
        // Sorted keys keep the output deterministic: ping is exactly {"type":"ping"}. Strings and
        // numbers always serialize.
        let json = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(#"{"type":"ping"}"#.utf8)
        var out = Data(capacity: 4 + json.count + body.count)
        out.append(CompanionBytes.bigEndian(UInt32(json.count)))
        out.append(json)
        out.append(body)
        return out
    }

    public static func decode(_ plaintext: Data) throws -> CompanionMessage {
        let data = plaintext.startIndex == 0 ? plaintext : Data(plaintext)
        guard data.count >= 4 else { throw DecodeError.truncated }
        let h = Int(CompanionBytes.uint32(data, at: 0))
        guard data.count >= 4 + h else { throw DecodeError.truncated }
        guard let object = try? JSONSerialization.jsonObject(with: data.subdata(in: 4..<4 + h)),
              let header = object as? [String: Any] else { throw DecodeError.badHeader }
        guard let type = header["type"] as? String else { throw DecodeError.missingField("type") }
        let body = data.subdata(in: 4 + h..<data.count)

        func string(_ key: String) throws -> String {
            guard let value = header[key] as? String else { throw DecodeError.missingField(key) }
            return value
        }
        func int(_ key: String) throws -> Int {
            guard let number = header[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw DecodeError.missingField(key)
            }
            return number.intValue
        }

        switch type {
        case "hello":
            return .hello(name: (header["name"] as? String) ?? "", platform: (header["platform"] as? String) ?? "",
                          version: (try? int("version")) ?? 0)
        case "clip":
            guard let kind = CompanionClipKind(rawValue: try string("kind")) else { return .unknown(type: type) }
            let clip = CompanionClipHeader(id: try string("id"), kind: kind, mime: try string("mime"),
                                           name: header["name"] as? String, size: try int("size"))
            return .clip(clip, body: body)
        case "ack": return .ack(id: try string("id"))
        case "ping": return .ping
        case "pong": return .pong
        case "unpair": return .unpair
        default: return .unknown(type: type)
        }
    }
}

/// The QR code's text (protocol §1):
/// `frog://pair?v=1&id=<mac uuid>&n=<name>&k=<secret base64url>&p=<port>&h=<ipv4,ipv4>`
public struct CompanionPairingURL: Equatable, Sendable {
    public var macID: UUID
    public var macName: String
    public var secret: Data
    public var port: UInt16
    public var hosts: [String]

    /// RFC 3986 unreserved characters; everything else in the name is percent-encoded as UTF-8.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(macID: UUID, macName: String, secret: Data, port: UInt16, hosts: [String]) {
        self.macID = macID; self.macName = macName; self.secret = secret; self.port = port; self.hosts = hosts
    }

    public var string: String {
        let name = macName.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        return "frog://pair?v=\(CompanionProtocol.version)"
            + "&id=\(macID.companionString)"
            + "&n=\(name)"
            + "&k=\(CompanionBytes.base64URL(secret))"
            + "&p=\(port)"
            + "&h=\(hosts.joined(separator: ","))"
    }

    /// Parses the QR text, the phone's job; here for round-trip tests.
    public init?(string: String) {
        guard let components = URLComponents(string: string), components.scheme == "frog", components.host == "pair",
              let items = components.queryItems else { return nil }
        var values: [String: String] = [:]
        for item in items { values[item.name] = item.value ?? "" }
        guard values["v"] == "1",
              let idString = values["id"], let id = UUID(uuidString: idString),
              let name = values["n"],
              let k = values["k"], let secret = CompanionBytes.data(base64URL: k), secret.count == CompanionProtocol.secretLength,
              let p = values["p"], let port = UInt16(p) else { return nil }
        let hosts = (values["h"] ?? "").split(separator: ",").map(String.init)
        self.init(macID: id, macName: name, secret: secret, port: port, hosts: hosts)
    }
}
