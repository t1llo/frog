import Foundation

/// A command that asks before it runs: the first press arms it, a second press on the same command within
/// `window` seconds runs it. A press on another command, or one that comes too late, arms again.
public struct CommandConfirmation: Equatable, Sendable {
    public struct Arm: Equatable, Sendable {
        public let id: String
        public let at: Date
    }
    public static let window: TimeInterval = 3
    public private(set) var armed: Arm?

    public init() {}

    /// Returns true when the action should run now; otherwise arms (or re-arms) for `id`.
    public mutating func press(_ id: String, now: Date) -> Bool {
        if let armed, armed.id == id, now >= armed.at, now.timeIntervalSince(armed.at) <= Self.window {
            self.armed = nil
            return true
        }
        armed = Arm(id: id, at: now)
        return false
    }

    public mutating func disarm() { armed = nil }
}
