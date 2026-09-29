import Foundation

public enum SystemAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case lockScreen
    public var id: String { rawValue }
    public var title: String { "Lock Screen" }
    public var symbol: String { "lock.fill" }
    public var rule: Rule {
        var rule = Rule(id: UUID(uuidString: "AC57F600-63D0-4E76-9901-000000000001")!, name: title, instructions: "", enabled: false)
        rule.action = RuleAction(category: .system); rule.action?.systemAction = self
        return rule
    }
}
