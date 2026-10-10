import Foundation

/// Retains extension fields in portable JSON, including fields inside identified rules/models.
indirect enum ConfigurationJSON: Codable, Equatable, Sendable {
    case object([String: ConfigurationJSON]), array([ConfigurationJSON]), string(String), number(Decimal), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    /// Only unknown fields survive; deleting a known optional field or array item stays deleted.
    static func preserving(_ original: Self, known: Self, updated: Self) -> Self {
        if case .object(let old) = original, case .object(let baseline) = known, case .object(let new) = updated {
            var result = old.filter { baseline[$0.key] == nil }
            for (key, value) in new {
                result[key] = old[key].flatMap { prior in baseline[key].map { preserving(prior, known: $0, updated: value) } } ?? value
            }
            return .object(result)
        }
        if case .array(let old) = original, case .array(let baseline) = known, case .array(let new) = updated {
            return .array(new.map { value in
                guard case .object(let fields) = value, let id = fields["id"],
                      let index = baseline.firstIndex(where: { if case .object(let f) = $0 { return f["id"] == id }; return false }),
                      index < old.count else { return value }
                return preserving(old[index], known: baseline[index], updated: value)
            })
        }
        return updated
    }

    func remappingProviders(_ ids: [UUID: UUID]) -> Self {
        guard case .object(var root) = self, case .array(let providers) = root["providers"] else { return self }
        root["providers"] = .array(providers.map { provider in
            guard case .object(var fields) = provider, case .string(let raw) = fields["id"],
                  let id = UUID(uuidString: raw), let new = ids[id] else { return provider }
            fields["id"] = .string(new.uuidString)
            return .object(fields)
        })
        return .object(root)
    }
}
