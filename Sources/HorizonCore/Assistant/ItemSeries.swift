import Foundation
import IngestKit

/// Items announced as a rhythm rather than a list ("a quiz every Thursday at 4 until the midterm"): what a lecture says
/// and no document prints, given to Siri or Shortcuts in one breath. The rhythm becomes numbered items, one per date,
/// each its own obligation with its own reminder, because that is what a course's graded work is ("Quiz 1", "Quiz 2").
public enum ItemSeries {
    /// No series runs longer than a term's weeks twice over: a rule with no end, or a wrong one, cannot flood Reminders.
    public static let limit = 30

    public struct Item: Sendable, Equatable {
        public var title: String
        public var due: Date
        public var dueHasTime: Bool
        public init(title: String, due: Date, dueHasTime: Bool) { self.title = title; self.due = due; self.dueHasTime = dueHasTime }
    }

    /// The dates `rule` gives from `start` on, up to `end` (a moment: an item's due date stops the series before that
    /// day, a day the user named includes it), leaving out the days the course does not meet. At most `limit`.
    public static func dates(rule: Calendar.RecurrenceRule, start: Date, end: Date?, skipping closed: [ClosedDateRange], calendar: Calendar, limit: Int = limit) -> [Date] {
        var out: [Date] = []
        for date in rule.recurrences(of: start) {
            if let end, date >= end { break }
            if closed.contains(where: { calendar.startOfDay(for: $0.start) <= date && date < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0.end)) ?? $0.end) }) { continue }
            out.append(date)
            if out.count >= limit { break }
        }
        return out
    }

    /// Where a series stops: before the day of the item it runs up to ("until the exam"), or at the end of the day the
    /// user named ("until December 4" includes the 4th).
    public static func end(beforeDayOf item: Date, calendar: Calendar) -> Date { calendar.startOfDay(for: item) }
    public static func end(throughDay day: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
    }

    /// A due moment from date components as Siri or Shortcuts give them: with an hour, that time (`dueHasTime`);
    /// without, the day, kept at 23:59 as every date-only deadline is. Components short of a full date (a weekday, a
    /// month and day with no year) mean the next such day from today on. Nil when they name no day.
    public static func due(from components: DateComponents, now: Date, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        let hasTime = components.hour != nil
        var wanted = DateComponents()
        wanted.year = components.year; wanted.month = components.month; wanted.day = components.day; wanted.weekday = components.weekday
        let day: Date?
        if wanted.year != nil, wanted.month != nil, wanted.day != nil {
            day = calendar.date(from: DateComponents(year: wanted.year, month: wanted.month, day: wanted.day))
        } else if wanted.month != nil || wanted.day != nil || wanted.weekday != nil {
            let before = calendar.startOfDay(for: now).addingTimeInterval(-1)
            day = calendar.nextDate(after: before, matching: wanted, matchingPolicy: .nextTime)
        } else {
            day = hasTime ? calendar.startOfDay(for: now) : nil   // a time alone is today's
        }
        guard let day else { return nil }
        let date = calendar.date(bySettingHour: components.hour ?? 23, minute: hasTime ? components.minute ?? 0 : 59, second: 0, of: day)
        return date.map { ($0, hasTime) }
    }

    /// One item per date, numbered from `first`: "Quiz 4", "Quiz 5"…
    public static func items(stem: String, first: Int, dates: [Date], hasTime: Bool) -> [Item] {
        let stem = Normalize.collapseWhitespace(stem)
        return dates.enumerated().map { Item(title: "\(stem) \(first + $0.offset)", due: $0.element, dueHasTime: hasTime) }
    }

    /// The name a title numbers, and its number: "Quiz 3" is ("Quiz", 3), "Problem Set #2" is ("Problem Set", 2), "Lab
    /// Report" is ("Lab Report", nil).
    public static func stem(of title: String) -> (stem: String, number: Int?) {
        let trimmed = Normalize.collapseWhitespace(title)
        var words = trimmed.split(separator: " ").map(String.init)
        guard let last = words.last else { return (trimmed, nil) }
        let digits = last.trimmingCharacters(in: CharacterSet(charactersIn: "#№:.)"))
        guard words.count > 1, let number = Int(digits), number >= 0 else { return (trimmed, nil) }
        words.removeLast()
        if words.last == "#" || words.last?.lowercased() == "no." { words.removeLast() }
        return (words.joined(separator: " "), number)
    }

    /// The number after the highest the course already has under the same name ("Quiz 3" on file: 4), or 1.
    public static func nextNumber(for stem: String, existing titles: [String]) -> Int {
        let key = Normalize.key(stem)
        let numbers = titles.compactMap { title -> Int? in
            let parsed = Self.stem(of: title)
            return Normalize.key(parsed.stem) == key ? parsed.number : nil
        }
        return (numbers.max() ?? 0) + 1
    }

    /// The grade row the name falls under, when one plainly does ("Quiz" under "Quizzes", "Homework" under "Weekly
    /// Homework"): the item then carries its share of the grade.
    public static func component(for stem: String, in components: [GradeComponent]) -> String? {
        let words = Normalize.tokens(stem).map(singular)
        guard !words.isEmpty else { return nil }
        let fits = components.filter { component in
            let row = Set(Normalize.tokens(component.name).map(singular))
            return words.allSatisfy(row.contains)
        }
        return fits.count == 1 ? fits[0].name : nil   // two rows that fit is no answer
    }

    private static func singular(_ word: String) -> String {
        if word.hasSuffix("zzes") { return String(word.dropLast(3)) }     // quizzes
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }   // studies
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { return String(word.dropLast()) }
        return word
    }
}
