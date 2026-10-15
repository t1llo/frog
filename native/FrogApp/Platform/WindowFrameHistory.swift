import CoreGraphics
import FrogCore

/// Where recently moved windows were before Frog moved them, for Restore previous size. Kept
/// in memory only and bounded, most recently moved last.
struct WindowFrameHistory {
    struct Entry: Equatable {
        let key: WindowKey
        /// The frame Restore returns to.
        let frame: CGRect
        /// The action that left `frame` behind.
        let move: WindowGeometry.Move
        /// The action that made that move, nil when it is not known.
        var action: WindowAction? = nil
        /// The size a cycled half reached, an index into `WindowSizeCycle.fractions`.
        var step = 0
    }

    let limit = 50
    private(set) var entries: [Entry] = []

    func entry(for key: WindowKey) -> Entry? { entries.last { $0.key == key } }

    /// Replaces what was kept for the window and makes it the most recent.
    mutating func record(_ key: WindowKey, before frame: CGRect, move: WindowGeometry.Move, action: WindowAction? = nil, step: Int = 0) {
        remove(key)
        entries.append(Entry(key: key, frame: frame, move: move, action: action, step: step))
        entries = Array(entries.suffix(limit))
    }

    mutating func remove(_ key: WindowKey) { entries.removeAll { $0.key == key } }
}
