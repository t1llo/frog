import FrogCore
import SwiftUI

/// When something happened, as lists show it, in one short form that reads down a column as Mail's does: relative
/// while it is recent, then the time today, then the day. "Just now", "12 min ago", "13:14", "Yesterday", "Monday",
/// then "Nov 2" (and the year once it is not this year's), in the Mac's own date and time format. `full` is the
/// whole date and time, for a tooltip.
enum RecentTimestamp {
    static func text(_ date: Date, now: Date = FrogClock.now, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds >= 0, seconds < 60 { return L10n.text("Just now") }
        if seconds >= 0, seconds < 3_600 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.minutes], width: .abbreviated)) + " " + L10n.text("ago")
        }
        if calendar.isDate(date, inSameDayAs: now) {
            // A 24-hour clock keeps its leading zero ("00:09", "09:41"), so an early time never reads as a
            // duration such as "0:09" beside "4 min ago"; a 12-hour clock says AM or PM, which does the same.
            if uses24HourClock(locale) {
                return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar)
                    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            }
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.text("Yesterday")
        }
        if seconds > 0, seconds < 6 * 86_400 {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide))
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return date.formatted(day)
    }

    /// Whether the locale, with the Mac's own clock setting, writes the hour on a 24-hour clock.
    private static func uses24HourClock(_ locale: Locale) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return pattern.contains("H") || pattern.contains("k")
    }

    /// The whole date and time, for the tooltip of a short timestamp: "6 Nov 2026 at 19:40".
    static func full(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A `RecentTimestamp` in a list row that stays true while the list is open: it is worked out again every minute,
/// and whenever `shownAt` changes, such as a reused panel opening again.
struct RecentTimestampText: View {
    let date: Date
    var shownAt: Date = .distantPast

    var body: some View {
        // The clock, not the schedule's minute-aligned date, which can fall before an item copied this minute.
        TimelineView(.everyMinute) { _ in Text(RecentTimestamp.text(date, now: max(FrogClock.now, shownAt))) }
            .monospacedDigit().lineLimit(1).help(RecentTimestamp.full(date))
    }
}
