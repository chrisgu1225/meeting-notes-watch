import Foundation

/// All exported timestamps are Australia/Adelaide wall time, including the
/// daylight-saving offset (ACDT +10:30 or ACST +09:30).
enum AdelaideClock {
    static let timeZoneIdentifier = "Australia/Adelaide"

    static let timeZone: TimeZone = {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            preconditionFailure("Missing time zone \(timeZoneIdentifier)")
        }
        return zone
    }()

    /// `2026-10-22T14:30:00+10:30`
    static func formatISO(_ date: Date) -> String {
        let parts = components(date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let absolute = abs(offset)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second,
            sign, absolute / 3600, (absolute % 3600) / 60
        )
    }

    /// Parses timestamps produced by `formatISO`.
    static func parseISO(_ text: String) -> Date? {
        guard text.count >= 25 else { return nil }
        let chars = Array(text)
        guard chars[10] == "T", chars[19] == "+" || chars[19] == "-" else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            Int(String(chars[start..<(start + length)]))
        }
        guard
            let year = number(0, 4),
            let month = number(5, 2),
            let day = number(8, 2),
            let hour = number(11, 2),
            let minute = number(14, 2),
            let second = number(17, 2),
            let offsetHour = number(20, 2),
            chars[22] == ":",
            let offsetMinute = number(23, 2)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let utc = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))
        guard let utc else { return nil }
        let sign: Int = chars[19] == "-" ? -1 : 1
        let offset = sign * ((offsetHour * 3600) + (offsetMinute * 60))
        return utc.addingTimeInterval(TimeInterval(-offset))
    }

    static func formatDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    static func roundedSeconds(_ interval: TimeInterval) -> Int {
        max(0, Int(interval.rounded()))
    }

    /// `20261022-143000` in Adelaide.
    static func fileStamp(_ date: Date) -> String {
        let parts = components(date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second
        )
    }

    /// `2026年10月22日 14:30`
    static func formatDisplay(_ date: Date) -> String {
        let parts = components(date)
        return String(
            format: "%04d年%d月%d日 %02d:%02d",
            parts.year, parts.month, parts.day, parts.hour, parts.minute
        )
    }

    static func formatDay(_ date: Date) -> String {
        let parts = components(date)
        return String(format: "%04d年%d月%d日", parts.year, parts.month, parts.day)
    }

    static func dayLabel(for date: Date, now: Date = Date()) -> String {
        if isSameDay(date, now) { return "今天" }
        if let yesterday = calendar().date(byAdding: .day, value: -1, to: now),
           isSameDay(date, yesterday) {
            return "昨天"
        }
        return formatDay(date)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar().isDate(lhs, inSameDayAs: rhs)
    }

    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private struct Parts {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
    }

    private static func components(_ date: Date) -> Parts {
        let parts = calendar().dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return Parts(
            year: parts.year ?? 0,
            month: parts.month ?? 0,
            day: parts.day ?? 0,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0
        )
    }
}
