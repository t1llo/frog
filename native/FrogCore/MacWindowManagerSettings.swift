import Foundation

/// The Desktop & Dock settings that decide where macOS itself puts windows, as stored in the
/// `com.apple.WindowManager` defaults. Frog reads them and never changes them.
public struct MacWindowManagerSettings: Equatable, Sendable {
    /// Stage Manager is on and shows its strip on the left of the display.
    public var stageManager: Bool
    /// Dragging a window to a screen edge tiles it.
    public var edgeTiling: Bool
    /// Dragging a window to the top edge fills the screen.
    public var topEdgeTiling: Bool
    /// Holding Option while dragging tiles a window.
    public var optionAccelerator: Bool

    public static let stageManagerKey = "GloballyEnabled"
    public static let edgeTilingKey = "EnableTilingByEdgeDrag"
    public static let topEdgeTilingKey = "EnableTopTilingByEdgeDrag"
    public static let optionAcceleratorKey = "EnableTilingOptionAccelerator"
    public static let keys = [stageManagerKey, edgeTilingKey, topEdgeTilingKey, optionAcceleratorKey]

    public init(stageManager: Bool = false, edgeTiling: Bool = false, topEdgeTiling: Bool = false, optionAccelerator: Bool = false) {
        self.stageManager = stageManager; self.edgeTiling = edgeTiling
        self.topEdgeTiling = topEdgeTiling; self.optionAccelerator = optionAccelerator
    }

    /// The stored values by key. Window tiling arrived in macOS 15 and is on until the user
    /// switches it off, so a missing tiling key means on there and off on macOS 14. Stage
    /// Manager is off until switched on.
    public init(values: [String: Bool], osMajorVersion: Int) {
        let tiling = osMajorVersion >= 15
        self.init(stageManager: values[Self.stageManagerKey] ?? false,
                  edgeTiling: values[Self.edgeTilingKey] ?? tiling,
                  topEdgeTiling: values[Self.topEdgeTilingKey] ?? tiling,
                  optionAccelerator: values[Self.optionAcceleratorKey] ?? tiling)
    }
}
