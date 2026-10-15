import Foundation

/// How answer rules behave. Each field decodes with its default when it is missing, so a file
/// written before a field existed keeps working.
public struct ExplainSettings: Codable, Equatable, Sendable {
    /// Sends the sentence or paragraph around the selection with it.
    public var includeContext = true

    public init() {}

    public var normalized: Self { self }

    private enum CodingKeys: String, CodingKey {
        case includeContext
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includeContext = try values.decodeIfPresent(Bool.self, forKey: .includeContext) ?? true
        self = normalized
    }

    public func validate() throws {}
}

extension Preferences {
    public var explainSettings: ExplainSettings { toolkitSettings.explain ?? ExplainSettings() }
}
