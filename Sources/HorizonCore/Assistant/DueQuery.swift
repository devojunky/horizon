import Foundation

/// The stretches of time people ask about ("what's due this week?"), and what falls in them. Shared by the App
/// Intents, the widgets and anything else that answers from outside the app's own pages.
public enum DuePeriod: String, Sendable, CaseIterable, Codable {
    case today, tomorrow, thisWeek, nextSevenDays, nextTwoWeeks, thisMonth

    /// The stretch at `now`: whole days, from the start of today (what is due later today is still due today).
    public func interval(at now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        func days(_ n: Int, from start: Date = today) -> DateInterval {
            DateInterval(start: start, end: calendar.date(byAdding: .day, value: n, to: start) ?? start)
        }
        switch self {
        case .today: return days(1)
        case .tomorrow: return days(1, from: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        case .thisWeek:   // to the end of the calendar week (the region's first weekday starts the next)
            let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? days(7)
            return DateInterval(start: today, end: max(week.end, today))
        case .nextSevenDays: return days(7)
        case .nextTwoWeeks: return days(14)
        case .thisMonth:
            let month = calendar.dateInterval(of: .month, for: now) ?? days(30)
            return DateInterval(start: today, end: max(month.end, today))
        }
    }
}

public enum DueQuery {
    /// Live items due in `interval` (its start held, its end not: midnight belongs to one day), in date order and, on
    /// the same moment, the heavier first. Done ones only when asked for; items in review are in, the caller says so.
    public static func items(_ items: [ObligationSnapshot], in interval: DateInterval, course: UUID? = nil, includeDone: Bool = false) -> [ObligationSnapshot] {
        items.filter { item in
            guard item.deletedAt == nil, let due = item.due, interval.holds(due) else { return false }
            if let course, item.courseID != course { return false }
            return includeDone || item.completedAt == nil
        }
        .sorted { ($0.due!, -($0.pointsAtStake ?? 0), $0.title) < ($1.due!, -($1.pointsAtStake ?? 0), $1.title) }
    }

    /// Open items whose date has gone by, most recent first: what a "what am I behind on?" answers.
    public static func overdue(_ items: [ObligationSnapshot], now: Date, course: UUID? = nil) -> [ObligationSnapshot] {
        items.filter { item in
            guard item.deletedAt == nil, item.completedAt == nil, let due = item.due, due < now else { return false }
            return course == nil || item.courseID == course
        }
        .sorted { $0.due! > $1.due! }
    }

    /// How far ahead "next" looks: the two weeks Coverage counts. A heavy final in December is not next in October.
    public static let nextWindow: TimeInterval = 14 * 86400

    /// The one item that matters most next (SPEC §7: the Lock Screen's single obligation, "ranked by points at stake,
    /// not by date"): the heaviest open item still ahead within `window`, the earlier of two equally heavy; when none in
    /// the window carries a weight, the soonest. Nil when nothing is due in it.
    public static func nextByWeight(_ items: [ObligationSnapshot], now: Date, window: TimeInterval = nextWindow, course: UUID? = nil) -> ObligationSnapshot? {
        let ahead = items.filter { item in
            guard item.deletedAt == nil, item.completedAt == nil, let due = item.due, due >= now, due < now.addingTimeInterval(window) else { return false }
            return course == nil || item.courseID == course
        }
        let weighted = ahead.filter { ($0.pointsAtStake ?? 0) > 0 }
        if !weighted.isEmpty {
            return weighted.min { ($0.pointsAtStake!, $1.due!) > ($1.pointsAtStake!, $0.due!) }
        }
        return ahead.min { $0.due! < $1.due! }
    }

    /// Open items still ahead in `interval`, the heaviest first and the earlier of equals ("what matters most?"); the
    /// ones no document weighs follow, soonest first. Its first is `nextByWeight`'s over the same stretch.
    public static func byWeight(_ items: [ObligationSnapshot], in interval: DateInterval, now: Date, course: UUID? = nil) -> [ObligationSnapshot] {
        Self.items(items, in: interval, course: course).filter { $0.due! >= now }.sorted { a, b in
            let (wa, wb) = (a.pointsAtStake ?? 0, b.pointsAtStake ?? 0)
            if (wa > 0) != (wb > 0) { return wa > 0 }
            if wa != wb { return wa > wb }
            return (a.due!, a.title) < (b.due!, b.title)
        }
    }
}
