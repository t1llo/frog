import Foundation

/// How the command bar behaves; what it learns stays on this Mac, outside the configuration.
public struct CommandBarPreferences: Codable, Equatable, Sendable {
    /// Rows picked for typed text lead later searches for it. Off, the bar ranks as it always has.
    public var learnChoices = false

    public init() {}

    public var normalized: Self { self }

    /// Nothing can be out of range yet; the configuration file checks it like the other groups.
    public func validate() throws {}

    private enum CodingKeys: String, CodingKey {
        case learnChoices
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        learnChoices = try values.decodeIfPresent(Bool.self, forKey: .learnChoices) ?? false
        self = normalized
    }
}
