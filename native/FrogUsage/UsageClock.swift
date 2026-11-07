import Foundation

/// The time limits, resets and charts are measured from: FrogCore's `FrogClock` for this module, which does not link
/// FrogCore. In a debug or test build `FROG_FIXED_NOW` ("2026-11-07T13:40", local time) pins it for pictures of the UI;
/// a release build always reads the real clock. Polling and scan schedules keep the real clock.
public enum UsageClock {
    #if DEBUG
    public static var now: Date {
        guard let value = getenv("FROG_FIXED_NOW") else { return Date() }
        return parse(String(cString: value)) ?? Date()
    }
    #else
    @inline(__always) public static var now: Date { Date() }
    #endif

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return Date(timeIntervalSince1970: seconds) }
        let parts = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4],
                                                  second: parts.count > 5 ? parts[5] : 0))
    }
}
