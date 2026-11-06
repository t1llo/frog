import Foundation

/// When something happened, as lists show it: in the Mac's own date and time format, relative while it is recent.
/// "Just now", "12 min ago", "Today 13:14", "Yesterday 09:02", "Monday 18:40", then "Nov 2, 13:14" (and the year
/// once it is not this year's).
enum RecentTimestamp {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds >= 0, seconds < 60 { return L10n.text("Just now") }
        if seconds >= 0, seconds < 3_600 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.minutes], width: .abbreviated)) + " " + L10n.text("ago")
        }
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        if calendar.isDate(date, inSameDayAs: now) { return L10n.text("Today") + " " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.text("Yesterday") + " " + time
        }
        if seconds > 0, seconds < 6 * 86_400 {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide)) + " " + time
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return date.formatted(day) + ", " + time
    }
}
