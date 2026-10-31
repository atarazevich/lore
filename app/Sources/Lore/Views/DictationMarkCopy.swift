import Foundation

/// Every string of the mark for later (#324), word for word from the copy
/// table of `docs/design/prototypes/dictation-mark.html` v2. One action, one
/// name: "Mark for later" sets it ("Mark for Later" in a menu, macOS's title
/// case), "Unmark" clears it, and "Marked for later" is the state, in the
/// bubble and on the row alike.
enum DictationMarkCopy {
    /// The unlit K's tooltip in the bubble (B1).
    static let markWithKey = "Mark for later (Fn+K)"
    /// The state: the lit K's tooltip (B3) and the row's meta line.
    static let marked = "Marked for later"
    /// The row's outline bookmark, on rows not marked and on taken rows.
    static let mark = "Mark for later"
    /// The row's lit bookmark, on a mark still waiting.
    static let unmark = "Unmark"
    /// The right-click menu's first item.
    static let menuMark = "Mark for Later"

    /// "Taken by" before the agent's name, which the row draws in the primary
    /// tone, and " · <time>" after it.
    static let takenBy = "Taken by "

    static func takenTail(_ take: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        " \u{00B7} " + receiptTime(take, now: now, calendar: calendar)
    }

    /// The receipt's time: today's time alone ("14:02"), a weekday and time
    /// within the week ("Mon 14:02"), a date after ("19 Oct").
    static func receiptTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let time: Date.FormatString = "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
        let format: Date.FormatString = switch days {
        case 0: time
        case 1..<7: "\(weekday: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
        default: "\(day: .defaultDigits) \(month: .abbreviated)"
        }
        return date.formatted(Date.VerbatimFormatStyle(
            format: format, locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: calendar))
    }
}
