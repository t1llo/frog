import Foundation

public enum WindowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, minimize, center, restore, nextDisplay, previousDisplay, toggleFullScreen
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .topLeft: "Top-left quarter"
        case .topRight: "Top-right quarter"
        case .bottomLeft: "Bottom-left quarter"
        case .bottomRight: "Bottom-right quarter"
        case .maximize: "Maximize on display"
        case .minimize: "Minimize"
        case .center: "Center"
        case .restore: "Restore previous size"
        case .nextDisplay: "Move to next display"
        case .previousDisplay: "Move to previous display"
        case .toggleFullScreen: "Toggle full screen"
        }
    }
    public var rule: Rule {
        // Stable identity keeps unsaved rows stable. These actions have no default shortcuts.
        let index = Self.allCases.firstIndex(of: self)! + 1
        let id = UUID(uuidString: String(format: "AC57F600-63D0-4E76-9900-%012d", index))!
        var rule = Rule(id: id, name: title, instructions: "", enabled: false)
        rule.action = RuleAction(category: .window); rule.action?.windowAction = self
        return rule
    }
}
