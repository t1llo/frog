import Foundation

public struct AppearancePreferences: Codable, Equatable, Sendable {
    /// Six-digit RGB, without '#'.
    public var accentHex = "A3D8AF"
    /// Zero is opaque; one is the strongest material translucency.
    public var transparency = 0.0
    public init() {}
    public var valid: Bool {
        accentHex.count == 6 && UInt32(accentHex, radix: 16) != nil && transparency.isFinite && (0...1).contains(transparency)
    }
}
