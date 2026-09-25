import Foundation

public enum RecordingShortcut {
    public enum Action: Equatable { case start, stop }
    public static func action(mode: RecordingMode, pressed: Bool, target: UUID, active: UUID?) -> Action? {
        if mode == .hold {
            if pressed { return active == nil ? .start : nil }
            return active == target ? .stop : nil
        }
        guard pressed else { return nil }
        if active == target { return .stop }
        return active == nil ? .start : nil
    }
}
