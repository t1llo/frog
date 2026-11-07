import Foundation

/// The time the app shows: reset times, "ago", "Until 15:25", chart ranges and their dates. In a debug or test build
/// `FROG_FIXED_NOW` pins it, so pictures of the UI read the same time every run: "2026-11-07T13:40" (local time, seconds
/// optional) or seconds since 1970. A release build always reads the real clock. Timers, retries and other scheduling
/// keep the real clock in every build.
public enum FrogClock {
    public static let variable = "FROG_FIXED_NOW"

    #if DEBUG
    /// The pinned time, or nil for the real clock.
    public static var fixed: Date? { getenv(variable).flatMap { parse(String(cString: $0)) } }
    public static var now: Date { fixed ?? Date() }
    /// `date` (a TimelineView's tick, say), or the pinned time.
    public static func now(or date: Date) -> Date { fixed ?? date }
    #else
    public static var fixed: Date? { nil }
    @inline(__always) public static var now: Date { Date() }
    @inline(__always) public static func now(or date: Date) -> Date { date }
    #endif

    /// "2026-11-07T13:40[:00]" or "2026-11-07 13:40" in the local time zone, or seconds since 1970.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return Date(timeIntervalSince1970: seconds) }
        let parts = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4],
                                                  second: parts.count > 5 ? parts[5] : 0))
    }
}
