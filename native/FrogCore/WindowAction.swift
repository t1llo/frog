import Foundation

public enum WindowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, minimize, center, restore, nextDisplay, previousDisplay, toggleFullScreen
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case centeredSmall, centeredMedium, centeredLarge
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
        case .leftThird: "Left third"
        case .centerThird: "Center third"
        case .rightThird: "Right third"
        case .leftTwoThirds: "Left two-thirds"
        case .rightTwoThirds: "Right two-thirds"
        case .centeredSmall: "Centered · 50%"
        case .centeredMedium: "Centered · 70%"
        case .centeredLarge: "Centered · 90%"
        }
    }
    private var ruleNumber: Int {
        switch self {
        case .leftHalf: 1
        case .rightHalf: 2
        case .topHalf: 3
        case .bottomHalf: 4
        case .topLeft: 5
        case .topRight: 6
        case .bottomLeft: 7
        case .bottomRight: 8
        case .maximize: 9
        case .minimize: 10
        case .center: 11
        case .restore: 12
        case .nextDisplay: 13
        case .previousDisplay: 14
        case .toggleFullScreen: 15
        case .leftThird: 16
        case .centerThird: 17
        case .rightThird: 18
        case .leftTwoThirds: 19
        case .rightTwoThirds: 20
        case .centeredSmall: 21
        case .centeredMedium: 22
        case .centeredLarge: 23
        }
    }
    public var rule: Rule {
        // Explicit IDs preserve existing saved shortcuts even if the list is reordered.
        let id = UUID(uuidString: String(format: "AC57F600-63D0-4E76-9900-%012d", ruleNumber))!
        var rule = Rule(id: id, name: title, instructions: "", enabled: false)
        rule.action = RuleAction(category: .window); rule.action?.windowAction = self
        return rule
    }
}
