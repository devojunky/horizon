import Foundation

/// What the widgets show (SPEC §7: the Lock Screen's one item that matters most next, the Home Screen's coming week of
/// the strip), worked out by the app whenever the store changes and kept in the App Group as a small file. The widget
/// extension only draws it: it never opens the store, so it cannot race the app's writes or meet a store from another
/// build. Entries run a week ahead, one wherever what is shown changes by itself (midnight, an item's due moment), so
/// the widgets stay right while the app sleeps.
public struct Glance: Codable, Sendable, Equatable {
    public var written: Date
    public var entries: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        /// Shown from this moment until the next entry's.
        public var date: Date
        /// The open item that matters most within two weeks (`DueQuery.nextByWeight`); nil when nothing is due in them.
        public var next: Item?
        /// Today and the six days after it, open items only.
        public var week: [Day]
        public init(date: Date, next: Item?, week: [Day]) { self.date = date; self.next = next; self.week = week }
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var course: String?
        public var due: Date
        public var dueHasTime: Bool
        /// Percentage points of the final grade; nil when no document gave a weight.
        public var points: Double?
        /// Still waiting for the user's eye in Review.
        public var inReview: Bool
        public init(id: UUID, title: String, course: String?, due: Date, dueHasTime: Bool, points: Double?, inReview: Bool) {
            self.id = id; self.title = title; self.course = course; self.due = due; self.dueHasTime = dueHasTime; self.points = points; self.inReview = inReview
        }
    }

    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public var id: Date { day }
        public var day: Date
        public var count: Int
        /// The day's share of the grade, summed.
        public var points: Double
        /// The strip's colour for the day (`Strip.heat`), 0 when nothing is due.
        public var heat: Double
        /// Two heavy items within a day of each other start here (`Strip.collisions`).
        public var pileup: Bool
        /// The day's heaviest item, by name.
        public var heaviest: String?
        public init(day: Date, count: Int, points: Double, heat: Double, pileup: Bool, heaviest: String?) {
            self.day = day; self.count = count; self.points = points; self.heat = heat; self.pileup = pileup; self.heaviest = heaviest
        }
    }

    public init(written: Date, entries: [Entry]) { self.written = written; self.entries = entries }

    /// What to show at `moment`: the last entry that has begun (the first, before any has).
    public func entry(at moment: Date) -> Entry? {
        entries.last { $0.date <= moment } ?? entries.first
    }

    /// No more entries than this: a week of midnights and due moments fits easily.
    public static let maximumEntries = 60

    /// The glance from `items` at `now`: an entry now, at every midnight of the coming week, and at every due moment in
    /// it (when an item's moment passes, the next one takes over).
    public static func build(items: [ObligationSnapshot], now: Date, calendar: Calendar) -> Glance {
        let live = items.filter { $0.deletedAt == nil && $0.completedAt == nil && $0.due != nil }
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 7, to: today) ?? now.addingTimeInterval(7 * 86400)
        let midnights = (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let dueMoments = live.compactMap(\.due).filter { $0 > now && $0 < horizon }.map { $0.addingTimeInterval(1) }   // just after: the item has gone by
        let moments = Array(Set([now] + midnights + dueMoments)).sorted().prefix(maximumEntries)
        let strip = live.map { StripItem(id: $0.id, title: $0.title, courseID: $0.courseID, courseCode: $0.courseCode ?? "", courseName: $0.courseName, due: $0.due!,
                                         dueHasTime: $0.dueHasTime, points: $0.pointsAtStake, state: $0.state) }
        let pileupDays = Set(Strip.collisions(strip, calendar: calendar).map(\.day))
        let entries = moments.map { moment -> Entry in
            let next = DueQuery.nextByWeight(live, now: moment).map(item)
            let start = calendar.startOfDay(for: moment)
            let week = (0..<7).compactMap { offset -> Day? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: start), let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                let due = live.filter { $0.due! >= max(day, moment) && $0.due! < end }   // what has gone by today is not ahead
                let points = due.reduce(0) { $0 + ($1.pointsAtStake ?? 0) }
                let heaviest = due.max { ($0.pointsAtStake ?? 0, $1.due!) < ($1.pointsAtStake ?? 0, $0.due!) }
                return Day(day: day, count: due.count, points: points, heat: due.isEmpty ? 0 : Strip.heat(points: points), pileup: pileupDays.contains(day), heaviest: heaviest?.title)
            }
            return Entry(date: moment, next: next, week: week)
        }
        return Glance(written: now, entries: entries)
    }

    private static func item(_ o: ObligationSnapshot) -> Item {
        Item(id: o.id, title: o.title, course: o.courseName, due: o.due!, dueHasTime: o.dueHasTime, points: o.pointsAtStake, inReview: o.state == .pendingReview)
    }

    // MARK: The file

    /// Where the app leaves it for the widgets: the App Group's container (nil without one, as on a Mac).
    public static var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup)?
            .appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent("Glance.json")
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> Glance? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Glance.self, from: data)
    }
}
