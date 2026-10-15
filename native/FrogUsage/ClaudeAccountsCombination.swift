// One value for several Claude accounts' limit of the same kind, such as everyone's session.
import Foundation

/// Each account renews on its own clock, so a combined window has no renewal time and no pace;
/// each account's renewal is listed in its caption instead.
public enum ClaudeAccountsCombination {
    public struct Account {
        public let label: String
        public let included: Bool
        /// `claudePlanName` of the account's linked profile, nil when no profile names one.
        public let plan: String?
        public let windows: [UsageWindow]

        public init(label: String, included: Bool = true, plan: String?, windows: [UsageWindow]) {
            self.label = label; self.included = included; self.plan = plan; self.windows = windows
        }
    }

    public enum Basis: Equatable, Sendable {
        /// Weighted by how much each plan allows, Pro as one.
        case planSize
        /// At least one plan is unknown, so each account counts the same.
        case equal
    }

    public struct Combined {
        /// The share of all counted accounts' limits used, NaN when no account counts.
        public let percentage: Double
        public let basis: Basis
        /// Included accounts without a current reading for this window.
        public let missing: [String]
        /// "A 30% · B 80%".
        public let breakdown: String
        /// "A 30% · resets 15:40 · B 80% · resets Thu 09:00".
        public let renewals: String
        /// "Treats A and B as plans of the same size", or "Weighted by plan size".
        public let basisDescription: String
        /// The combined row: its used and left texts round as every other row does.
        public let window: UsageWindow
    }

    /// How much more a plan allows than Pro. Team, Enterprise and an unknown plan have no size.
    static func weight(plan: String?) -> Double? {
        switch plan {
        case "Pro": 1
        case "Max", "Max 5×": 5
        case "Max 20×": 20
        default: nil
        }
    }

    /// Combines the window with id `window` (such as "five_hour") over the included accounts that
    /// have a current reading of it: Σ wᵢ·usedᵢ / Σ wᵢ, with plan sizes as weights when every
    /// counted plan is known, else equal weights.
    public static func combine(_ accounts: [Account], window id: String, now: Date = Date()) -> Combined {
        let included = accounts.filter(\.included)
        var counted: [(account: Account, window: UsageWindow)] = []
        var missing: [String] = []
        for account in included {
            if let window = account.windows.first(where: { $0.id == id }), window.percentage.isFinite,
               window.resetsAt.map({ $0 > now }) ?? true {
                counted.append((account, window))
            } else {
                missing.append(account.label)
            }
        }
        let weights = counted.map { weight(plan: $0.account.plan) }
        let known = !counted.isEmpty && weights.allSatisfy { $0 != nil }
        let basis: Basis = known ? .planSize : .equal
        let used = zip(counted, weights).map { entry, weight in (known ? weight! : 1, entry.window.percentage) }
        let total = used.reduce(0) { $0 + $1.0 }
        let percentage = total > 0 ? used.reduce(0) { $0 + $1.0 * $1.1 } / total : .nan
        let breakdown = counted.map { "\($0.account.label) \($0.window.usedText)" }.joined(separator: " · ")
        let renewals = counted.map { entry in
            "\(entry.account.label) \(entry.window.usedText)" + (entry.window.resetsAt.map { " · resets \(resetClock($0, now: now))" } ?? "")
        }.joined(separator: " · ")
        let labels = counted.isEmpty ? included.map(\.label) : counted.map(\.account.label)
        let basisDescription = basis == .planSize ? "Weighted by plan size"
            : "Treats \(labels.joined(separator: " and ")) as plans of the same size"
        let title = counted.first?.window.title
            ?? included.lazy.compactMap { $0.windows.first { $0.id == id }?.title }.first ?? id
        return Combined(percentage: percentage, basis: basis, missing: missing, breakdown: breakdown, renewals: renewals,
                        basisDescription: basisDescription,
                        window: UsageWindow(id: id, title: title, percentage: percentage, resetsAt: nil, duration: nil))
    }
}
