import XCTest
@testable import FrogUsage

/// How the usage status sentences write a time. The dates are fixed in this Mac's time zone and
/// written in a named locale, so the result does not depend on the Mac running the test.
final class UsageClockTests: XCTestCase {
    /// A Friday afternoon.
    private let now = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 15, minute: 40))!
    private let british = Locale(identifier: "en_GB")

    private func days(_ count: Int) -> Date { Calendar.current.date(byAdding: .day, value: count, to: now)! }

    func testATimeMoreThanSixDaysAwayIsWrittenAsItsDateAlsoInThePast() {
        XCTAssertEqual(resetClock(days(-10), now: now, locale: british), "5 Jan", "Not a weekday that reads like the coming one")
        XCTAssertEqual(resetClock(days(10), now: now, locale: british), "25 Jan")
        XCTAssertEqual(resetClock(days(-3), now: now, locale: british), "Tue 15:40")
        XCTAssertEqual(resetClock(days(3), now: now, locale: british), "Mon 15:40")
    }

    func testOneSentenceWritesEveryTimeOfDayTheSameWay() {
        XCTAssertEqual(resetClock(now, now: now, locale: british), "15:40")
        XCTAssertEqual(clock(now, locale: british), "15:40")
        let american = Locale(identifier: "en_US")
        XCTAssertEqual(resetClock(now, now: now, locale: american), clock(now, locale: american))
        XCTAssertEqual(resetClock(now, now: now), clock(now), "Both follow the person's own locale and clock setting")
    }
}
