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
}
