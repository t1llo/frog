import Foundation

public enum RecordingShortcut {
    /// `busy`: the press starts nothing because the active recording is still being finished,
    /// and the person should be told so.
    public enum Action: Equatable { case start, stop, busy }
    /// `finishing` is true while the active recording is being transcribed or cleaned up.
    public static func action(mode: RecordingMode, pressed: Bool, target: UUID, active: UUID?, finishing: Bool = false) -> Action? {
        if pressed, active != nil, finishing { return .busy }
        if mode == .hold {
            if pressed { return active == nil ? .start : nil }
            return active == target ? .stop : nil
        }
        guard pressed else { return nil }
        if active == target { return .stop }
        return active == nil ? .start : nil
    }
}
