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

    // MARK: Rows (the strip fits the load: the page under it is a list that needs its room)

    /// The height of one band (its label line, its cells, the gap under them) when `rows` of them share `available`
    /// points: roomy for a course or two, compact for a full load, never too small for a count to fit in a cell. Past
    /// the minimum the strip simply grows, and the page scrolls.
    public static func rowHeight(rows: Int, available: Double, minimum: Double = 44, maximum: Double = 96) -> Double {
        min(maximum, max(minimum, (available / Double(max(rows, 1))).rounded(.down)))
    }

    /// Whether a band for everything belongs above the courses' own: only when there are several to add up.
    public static func showsTotal(bands: Int) -> Bool { bands >= 2 }

    // MARK: Levels (one to read, one to work from)

    /// Two levels for two intents. `weeks` is the overview: the whole term across the screen, as dense as it needs
    /// to be, read rather than tapped; the whole of it is one control, and a touch means "look closer here", which
    /// forgives a miss by a week. `days` is where work is picked out: a bar is a day, a control of its own, never
    /// narrower than the HIG's control size, and the strip scrolls.
    public enum Level: Sendable, Equatable, CaseIterable { case weeks, days }

    /// The least a bar that is a control may measure across: the HIG's default control size, 44 points for a finger,
    /// 28 for a pointer.
    public static func minimumBar(touch: Bool) -> Double { touch ? 44 : 28 }

    /// How wide one bar is at a level. Weeks: the term's weeks share `width` exactly, however narrow that makes them
    /// (they are read, not hit). Days: two weeks across `width`, or as many days as stay wide enough to hit.
    public static func barWidth(_ level: Level, width: Double, weeks: Int, minimumBar: Double) -> Double {
        switch level {
        case .weeks: width / Double(max(weeks, 1))
        case .days: max(minimumBar, (width / 14).rounded(.down))
        }
    }

    /// The week a touch on the overview means: the one under it, unless that one is empty and a week with something
    /// in it is within half a control's width (`reach`), since nobody looks closer at nothing on purpose.
    public static func week(at x: Double, barWidth: Double, weeks: Int, hasItems: (Int) -> Bool, reach: Double) -> Int? {
        guard weeks > 0, barWidth > 0 else { return nil }
        let under = min(max(Int(x / barWidth), 0), weeks - 1)
        if hasItems(under) { return under }
        let near = (0..<weeks).filter(hasItems).min { abs((Double($0) + 0.5) * barWidth - x) < abs((Double($1) + 0.5) * barWidth - x) }
        if let near, abs((Double(near) + 0.5) * barWidth - x) <= reach + barWidth / 2 { return near }
        return under
    }

    /// Every week or day the span touches, in order, whole: the strip's bars, with or without anything in them.
    public static func periods(in span: ClosedRange<Date>, level: Level, calendar: Calendar) -> [DateInterval] {
        var periods: [DateInterval] = []
        var period = self.period(containing: span.lowerBound, level: level, calendar: calendar)
        while period.start <= span.upperBound, periods.count < 1000 {
            periods.append(period)
            period = self.period(containing: period.end.addingTimeInterval(3600), level: level, calendar: calendar)   // an hour in: past a daylight-saving seam
        }
        return periods
    }

    /// Colour intensity in 0.2...1 for a cell or a mark: the accent at this opacity. Load is colour, not size.
    public static func heat(points: Double?) -> Double { 0.2 + 0.8 * mass(points: points) }

    /// One week or one day of one band: its items (heaviest first) and the points at stake that are not done yet.
    public struct Cell: Identifiable, Sendable, Equatable {
        public var id: Date { period.start }
        public var period: DateInterval
        public var items: [StripItem]
        public var points: Double
        public var count: Int { items.count }
        public init(period: DateInterval, items: [StripItem], points: Double) { self.period = period; self.items = items; self.points = points }
    }

    /// The period the strip reads as one unit at this level: the week or the day holding `day`.
    public static func period(containing day: Date, level: Level, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: level == .weeks ? .weekOfYear : .day, for: day) ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
    }

    /// Items grouped into the level's periods, in time order; empty periods are not returned.
    public static func cells(_ items: [StripItem], level: Level, calendar: Calendar) -> [Cell] {
        var groups: [Date: (period: DateInterval, items: [StripItem])] = [:]
        for item in items {
            let period = self.period(containing: item.due, level: level, calendar: calendar)
            groups[period.start, default: (period, [])].items.append(item)
        }
        return groups.keys.sorted().map { start in
            let group = groups[start]!
            let sorted = group.items.sorted { ($0.points ?? 0) > ($1.points ?? 0) }
            let points = sorted.filter { !$0.completed }.reduce(0) { $0 + ($1.points ?? 0) }
            return Cell(period: group.period, items: sorted, points: points)
        }
    }
}
