import XCTest
@testable import FrogUsage

final class ClaudeAccountsCombinationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ label: String, plan: String? = nil, included: Bool = true,
                         session: Double, resets: TimeInterval? = 3600) -> ClaudeAccountsCombination.Account {
        .init(label: label, included: included, plan: plan, windows: [
            UsageWindow(id: "five_hour", title: "Session", percentage: session,
                        resetsAt: resets.map { now.addingTimeInterval($0) }, duration: 5 * 3600),
        ])
    }

    func testEqualWeightsWhenAPlanIsUnknown() {
        let combined = ClaudeAccountsCombination.combine([account("A", session: 30), account("B", plan: "Max 20×", session: 80)],
                                                         window: "five_hour", now: now)
        XCTAssertEqual(combined.percentage, 55, accuracy: 1e-9)
        XCTAssertEqual(combined.basis, .equal)
        XCTAssertEqual(combined.basisDescription, "Treats A and B as plans of the same size")
        XCTAssertEqual(combined.breakdown, "A 30% · B 80%")
        XCTAssertEqual(combined.missing, [])
        XCTAssertEqual(combined.window.title, "Session")

        let team = ClaudeAccountsCombination.combine([account("A", plan: "Team", session: 30), account("B", plan: "Pro", session: 80)],
                                                     window: "five_hour", now: now)
        XCTAssertEqual(team.basis, .equal, "Team and Enterprise plans have no known size")
    }

    func testPlanSizesWeighWhenEveryPlanIsKnown() {
        let combined = ClaudeAccountsCombination.combine([account("A", plan: "Max 20×", session: 40), account("B", plan: "Pro", session: 82)],
                                                         window: "five_hour", now: now)
        XCTAssertEqual(combined.percentage, (20 * 40 + 1 * 82) / 21, accuracy: 1e-9)
        XCTAssertEqual(combined.basis, .planSize)
        XCTAssertEqual(combined.basisDescription, "Weighted by plan size")
        XCTAssertEqual(ClaudeAccountsCombination.weight(plan: "Max 5×"), 5)
        XCTAssertEqual(ClaudeAccountsCombination.weight(plan: "Max"), 5)
        XCTAssertNil(ClaudeAccountsCombination.weight(plan: "Enterprise"))
    }

    func testAccountsWithoutACurrentReadingAreLeftOutAndNamed() {
        let combined = ClaudeAccountsCombination.combine([
            account("A", plan: "Pro", session: 30),
            account("B", plan: "Pro", session: .nan),
            account("C", plan: "Pro", session: 90, resets: -60),
            account("D", plan: "Pro", included: false, session: 100),
            .init(label: "E", plan: "Pro", windows: []),
        ], window: "five_hour", now: now)
        XCTAssertEqual(combined.percentage, 30)
        XCTAssertEqual(combined.missing, ["B", "C", "E"], "An excluded account is not missing, it is left out")
        XCTAssertEqual(combined.breakdown, "A 30%")

        let nobody = ClaudeAccountsCombination.combine([account("A", session: .nan)], window: "five_hour", now: now)
        XCTAssertTrue(nobody.percentage.isNaN)
        XCTAssertEqual(nobody.window.usedText, "—")
        XCTAssertEqual(nobody.missing, ["A"])
    }

    func testCombinedRowRoundsLikeEveryRowAndHasNoRenewalOrPace() {
        let combined = ClaudeAccountsCombination.combine([account("A", session: 33.9), account("B", session: 66.8, resets: nil)],
                                                         window: "five_hour", now: now)
        XCTAssertEqual(combined.window.usedText, "50%")
        XCTAssertEqual(combined.window.leftText, "50% left")
        XCTAssertEqual(combined.breakdown, "A 33% · B 66%")
        XCTAssertNil(combined.window.resetsAt)
        XCTAssertNil(combined.window.pace(at: now))
        XCTAssertEqual(combined.renewals, "A 33% · resets \(resetClock(now.addingTimeInterval(3600), now: now)) · B 66%")
    }
}
