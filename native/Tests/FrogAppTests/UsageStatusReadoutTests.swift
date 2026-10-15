import XCTest
@testable import FrogApp
@testable import FrogUsage

/// The menu-bar readout is checked every 15 seconds and on every change of the usage model.
/// Most checks find it as it was; those must not draw it again.
final class UsageStatusReadoutTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_800_000_000)

    private func face(session: Double, week: Double = 41.6, weekReset: Date? = nil,
                      dimmed: Bool = false) -> UsageStatusReadout.Face {
        UsageStatusReadout.Face(provider: "Claude", windows: [
            UsageWindow(id: "five_hour", title: "Session", percentage: session, resetsAt: nil, duration: 5 * 3600),
            UsageWindow(id: "seven_day", title: "Week", percentage: week, resetsAt: weekReset ?? reset, duration: 7 * 86_400)
        ], dimmed: dimmed)
    }

    func testAnUnchangedReadingKeepsTheSameFace() {
        XCTAssertEqual(face(session: 12), face(session: 12))
        // A session that renewed after the last reading is unknown (NaN, which never equals itself).
        XCTAssertEqual(face(session: .nan), face(session: .nan))
        // The image shows no reset time; only the description does.
        XCTAssertEqual(face(session: 12), face(session: 12, weekReset: reset.addingTimeInterval(3600)))
        let estimate = UsageStatusReadout.Estimate(range: "7d", value: "$185")
        XCTAssertEqual(UsageStatusReadout.Face(provider: "OpenAI", windows: [], estimate: estimate),
                       UsageStatusReadout.Face(provider: "OpenAI", windows: [], estimate: estimate))
    }

    func testEveryChangeTheImageShowsChangesTheFace() {
        XCTAssertNotEqual(face(session: 12), face(session: 13), "The number")
        XCTAssertNotEqual(face(session: 12.2), face(session: 12.7), "The track, though the number stays 12%")
        XCTAssertNotEqual(face(session: 12), face(session: .nan), "A session that renewed")
        XCTAssertNotEqual(face(session: 12), face(session: 12, dimmed: true), "A reading that could not be refreshed")
        XCTAssertNotEqual(UsageStatusReadout.Face(provider: "Claude", windows: []),
                          UsageStatusReadout.Face(provider: "OpenAI", windows: []), "The provider shown without a reading")
        XCTAssertNotEqual(UsageStatusReadout.Face(provider: "Claude", windows: [],
                                                  estimate: .init(range: "7d", value: "$185")),
                          UsageStatusReadout.Face(provider: "Claude", windows: [],
                                                  estimate: .init(range: "7d", value: "$186")), "The estimate")
    }

    // MARK: Several Claude accounts

    private func account(_ label: String, session: Double, week: Double, stale: Bool = false,
                         included: Bool = true) -> UsageAccountSummary {
        UsageAccountSummary(
            id: "/fixture/\(label)", label: label, shortLabel: String(label.prefix(6)),
            windows: [UsageWindow(id: "five_hour", title: "Session", percentage: session,
                                  resetsAt: reset.addingTimeInterval(3600), duration: 5 * 3600),
                      UsageWindow(id: "seven_day", title: "Week", percentage: week,
                                  resetsAt: reset.addingTimeInterval(3 * 86_400), duration: 7 * 86_400)],
            plan: nil, sources: ["Claude app · Claude-Account-\(label)"], age: reset.addingTimeInterval(-7200),
            readingSource: "Claude app", stale: stale, status: nil, included: included,
            needsLiveSetup: false, mergedNote: nil)
    }

    func testEachAccountShowsItsChosenWindow() {
        let accounts = [account("A", session: 37.4, week: 12), account("B", session: 81.9, week: 64)]
        let session = UsageStatusReadout.Face(accounts: accounts, window: "session")
        XCTAssertEqual(session.labels, ["A", "B"])
        XCTAssertEqual(session.values, ["37%", "81%"])
        XCTAssertEqual(session.fractions[0], 0.374, accuracy: 0.0001)
        XCTAssertEqual(session.fractions[1], 0.819, accuracy: 0.0001)
        let week = UsageStatusReadout.Face(accounts: accounts, window: "week")
        XCTAssertEqual(week.values, ["12%", "64%"])
        XCTAssertNotEqual(session, week)
        // An excluded account leaves the menu bar.
        let excluded = UsageStatusReadout.Face(accounts: [accounts[0], account("B", session: 81, week: 64, included: false)], window: "session")
        XCTAssertEqual(excluded.labels, ["A"])
    }

    func testAStaleAccountRecedesOnItsOwn() {
        let face = UsageStatusReadout.Face(accounts: [account("A", session: 37, week: 12),
                                                      account("B", session: 81, week: 64, stale: true)], window: "session")
        XCTAssertEqual(face.dimmedEntries, [false, true])
        XCTAssertFalse(face.dimmed)
        XCTAssertNotEqual(face, UsageStatusReadout.Face(accounts: [account("A", session: 37, week: 12),
                                                                   account("B", session: 81, week: 64)], window: "session"))
    }

    func testAtMostThreeAccountsAreDrawnAndAllAreDescribed() {
        let accounts = ["A", "B", "C", "D"].map { account($0, session: 10, week: 20) }
        XCTAssertEqual(UsageStatusReadout.Face(accounts: accounts, window: "session").labels, ["A", "B", "C"])
        let description = UsageStatusReadout.description(accounts: accounts, now: reset)
        for label in ["A", "B", "C", "D"] {
            XCTAssertTrue(description.contains("\n\(label) · Session 10% used"), description)
            XCTAssertTrue(description.contains("\n\(label) · Week 20% used"), description)
        }
    }

    func testTheDescriptionNamesEachAccountWindowAndSource() {
        let accounts = [account("A", session: 30, week: 12), account("B", session: 81, week: 64)]
        let lines = UsageStatusReadout.description(accounts: accounts, now: reset).components(separatedBy: "\n")
        let clock = reset.addingTimeInterval(3600).formatted(Date.FormatStyle().hour().minute())
        XCTAssertTrue(lines.contains("B · Session 81% used · resets \(clock) · Claude app, 2h ago"), lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("@") }, "No e-mail address")

        let combined = ["five_hour", "seven_day"].map { id in
            ClaudeAccountsCombination.combine(accounts.map {
                ClaudeAccountsCombination.Account(label: $0.label, plan: nil, windows: $0.windows)
            }, window: id, now: reset)
        }
        let combinedLines = UsageStatusReadout.description(accounts: accounts, combined: combined, now: reset)
            .components(separatedBy: "\n")
        XCTAssertEqual(combinedLines.first, "A + B combined")
        XCTAssertTrue(combinedLines.contains("Session: 55% used · A 30% · B 81%"), combinedLines.joined(separator: "\n"))
        XCTAssertTrue(combinedLines.contains("Treats A and B as plans of the same size"))
        XCTAssertTrue(combinedLines.contains { $0.hasPrefix("B · Week 64% used") })
        // The combined face looks like the one account's: the window lengths, no per-entry dimming.
        let face = UsageStatusReadout.Face(provider: "Claude", windows: combined.map(\.window))
        XCTAssertEqual(face.labels, ["5h", "7d"])
        XCTAssertEqual(face.dimmedEntries, [])
    }

    func testOneAccountKeepsTodaysFace() {
        let today = face(session: 37, week: 41.6)
        XCTAssertEqual(today.labels, ["5h", "7d"])
        XCTAssertEqual(today.values, ["37%", "41%"])
        XCTAssertEqual(today.dimmedEntries, [])
        XCTAssertEqual(today, face(session: 37, week: 41.6))
    }
}
