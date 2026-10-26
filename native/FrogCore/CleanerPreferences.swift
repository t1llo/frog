import Foundation

/// Portable switches of the App cleaner. Each is read only while feature.cleaner is on.
public struct CleanerPreferences: Codable, Equatable, Sendable {
    /// Also list files whose names only resemble the app; they are never ticked.
    public var possibleMatches = false

    public init() {}

    public var normalized: Self {
        var value = self
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case possibleMatches
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        possibleMatches = try values.decodeIfPresent(Bool.self, forKey: .possibleMatches) ?? false
        self = normalized
    }
}

extension Preferences {
    public var cleanerSettings: CleanerPreferences { toolkitSettings.cleaner ?? CleanerPreferences() }
}
