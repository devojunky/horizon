import Foundation

/// One obligation as the strip sees it (SPEC §6.2).
public struct StripItem: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var courseID: UUID?
    public var courseCode: String
    public var courseName: String
    public var due: Date
    public var dueHasTime: Bool
    /// Percentage points of the final grade; nil when the document gave no weight.
    public var points: Double?
    public var state: ObligationState
    public var completed: Bool

    public init(id: UUID, title: String, courseID: UUID?, courseCode: String, courseName: String? = nil, due: Date, dueHasTime: Bool, points: Double?, state: ObligationState, completed: Bool = false) {
        self.id = id; self.title = title; self.courseID = courseID; self.courseCode = courseCode; self.courseName = (courseName?.isEmpty == false ? courseName : nil) ?? courseCode
        self.due = due; self.dueHasTime = dueHasTime
        self.points = points; self.state = state; self.completed = completed
    }
}

/// The semester as one continuous strip: what carries mass, what collides, how far it runs. Pure; the view draws.
public enum Strip {
    /// Points at stake from which an item counts as heavy: a pileup needs two of these within a day of each other.
    public static let heavyPoints = 10.0

    /// Visual mass in 0...1, square-root scaled so a 4% problem set is a hairline and a 30% final dominates.
    /// An item with no stated weight reads light.
    public static func mass(points: Double?) -> Double {
        let p = max(points ?? 2, 0.5)
        return min(1, (p / 35).squareRoot())
    }

    /// Two or more heavy items within 24 hours of each other, called out by the day the first one falls on.
    public struct Collision: Identifiable, Sendable, Equatable {
        public var id: Date { day }
        public var day: Date
        public var items: [StripItem]
        public init(day: Date, items: [StripItem]) { self.day = day; self.items = items }
    }

    public static func collisions(_ items: [StripItem], calendar: Calendar) -> [Collision] {
        let heavy = items.filter { !$0.completed && ($0.points ?? 0) >= heavyPoints }.sorted { $0.due < $1.due }
        var result: [Collision] = []
        var group: [StripItem] = []
        func flush() {
            if group.count >= 2, let first = group.first { result.append(Collision(day: calendar.startOfDay(for: first.due), items: group)) }
            group = []
        }
        for item in heavy {
            if let last = group.last, item.due.timeIntervalSince(last.due) <= 86_400 { group.append(item) } else { flush(); group = [item] }
        }
        flush()
        return result
    }

    /// The span the strip draws: the earliest term start to the latest term end, widened to hold every item and
    /// today, with a week of air on each side.
    public static func span(termStarts: [Date], termEnds: [Date], items: [StripItem], now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let dates = termStarts + termEnds + items.map(\.due) + [now]
        let lower = calendar.startOfDay(for: dates.min() ?? now)
        let upper = calendar.startOfDay(for: dates.max() ?? now)
        let start = calendar.date(byAdding: .day, value: -7, to: lower) ?? lower
        let end = calendar.date(byAdding: .day, value: 8, to: upper) ?? upper
        return start...end
    }

    /// Items due on a day, heaviest first.
    public static func items(on day: Date, in items: [StripItem], calendar: Calendar) -> [StripItem] {
        items.filter { calendar.isDate($0.due, inSameDayAs: day) }.sorted { ($0.points ?? 0) > ($1.points ?? 0) }
    }
}
