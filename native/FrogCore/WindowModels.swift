import Foundation

/// The identity of one window: its owner and a number that stays the same while the window
/// exists, across reads and moves.
public struct WindowKey: Hashable, Codable, Sendable {
    public let pid: Int32
    public let number: UInt32

    public init(pid: Int32, number: UInt32) {
        self.pid = pid; self.number = number
    }
}

/// One display in Accessibility's global coordinates, whose origin is the top left of the
/// primary display.
public struct WindowDisplay: Equatable, Sendable {
    public var id: String
    public var name: String
    public var frame: CGRect
    /// The frame without the menu bar and the Dock.
    public var visibleFrame: CGRect

    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
    }

    /// Names a display the same way on every Mac it is plugged into, without its serial number.
    public var signature: String { "\(name) \(Int(frame.width))×\(Int(frame.height))" }

    /// Left to right, and top to bottom where displays share a left edge. Every list of
    /// displays Frog moves windows between is in this order.
    public static func ordered(_ displays: [WindowDisplay]) -> [WindowDisplay] {
        displays.sorted { left, right in
            if left.visibleFrame.minX == right.visibleFrame.minX { return left.visibleFrame.minY < right.visibleFrame.minY }
            return left.visibleFrame.minX < right.visibleFrame.minX
        }
    }
}
