import Foundation

/// Deterministic date resolution. The model's ISO date is cross-checked against a re-parse of the exact wording it
/// copied from the document. The wording wins when they disagree, with one exception: wording that names several
/// dates without saying "due" lets the model choose among them.
struct DateResolver: Sendable {
    var calendar: Calendar
    /// Year for dates written without one, when nothing better decides it (`year(month:day:)`). The term label's year
    /// when the document has one.
    var defaultYear: Int
    var termStart: Date?
    var termEnd: Date?
    /// A label that names two years ("Academic Year 2026–2027"): with the term's own dates unknown, a date written
    /// without a year falls in the first from August on, in the second before it.
    var termYears: ClosedRange<Int>?
    /// The months a label's season covers ("Fall 2026": August to December 2026), for when the term's own dates are
    /// not known: a Fall term's "January 8" is still the January after it.
    var season: DateInterval?
    /// Numeric dates read day first ("9/4" is 9 April): only when the document proves it (`readsDayFirst`). Month first
    /// otherwise, whatever the device's region: the detector reads "9/4" by the region, so it is handed every numeric
    /// date in the order it expects (`regionReadsDayFirst`), never the document's digits as they stand.
    var dayFirst = false

    init(calendar: Calendar = .current, defaultYear: Int, termStart: Date? = nil, termEnd: Date? = nil) {
        self.calendar = calendar; self.defaultYear = defaultYear; self.termStart = termStart; self.termEnd = termEnd
    }

    struct Resolution: Sendable {
        var date: Date?
        var hasTime: Bool
        var flags: [ParseFlag]
        /// True when the copied wording itself named the day (explicit date or week-relative reference).
        var resolvedFromText: Bool
    }

    func resolve(iso: String?, asWritten: String) -> Resolution {
        let fromModel = iso.flatMap(ymd(iso:))
        let spans = explicitSpans(in: asWritten)
        var flags: [ParseFlag] = []
        var fromText = day(in: asWritten, spans: spans)
        // "Week 3", "end of Week 3": a week, not a day. The model's day stands when it falls in that week; otherwise the
        // week's Monday is only a guess, and the item goes to review.
        if fromText != nil, explicitDay(in: asWritten, spans: spans) == nil, let week = weekReference(in: asWritten), week.weekday == nil {
            if let m = fromModel, week.contains(m, calendar: calendar) { fromText = m } else { flags.append(.dateAmbiguous) }
        }
        var day: DateComponents?
        if let t = fromText {
            let dueAnchored = asWritten.range(of: #"(?i)\bdue\b"#, options: .regularExpression) != nil
            if let m = fromModel, m != t, !dueAnchored, spans.contains(where: { $0.start == m || $0.end == m }) {
                day = m   // several dates named, none marked "due": the model's choice among them stands
            } else if let m = fromModel, m.month == t.month, m.day == t.day, let my = m.year, let ty = t.year, abs(my - ty) == 1,
                      !knowsTermYears, !spans.contains(where: \.yearWritten) {
                day = m   // the wording names no year and nothing about the term decides it: the model's, a year either side, stands
            } else {
                day = t
                if let m = fromModel, m != t { flags.append(.dateDisagreement) }
            }
        } else if Self.isTBD(asWritten) {
            day = nil     // the document says TBD; a model-supplied date would be invented
        } else {
            day = fromModel
        }
        guard let day else {
            if !asWritten.isEmpty, !Self.isTBD(asWritten) { flags.append(.dateUnresolved) }
            return Resolution(date: nil, hasTime: false, flags: flags, resolvedFromText: false)
        }
        let clock = Self.time(in: asWritten)
        var components = day
        components.hour = clock?.hour ?? 23
        components.minute = clock?.minute ?? 59
        components.second = 0
        guard let date = calendar.date(from: components) else { return Resolution(date: nil, hasTime: false, flags: flags + [.dateUnresolved], resolvedFromText: false) }
        // By the day: an exam at 9 AM three weeks after the last class is still inside.
        let dayOf = calendar.startOfDay(for: date)
        if let termStart, dayOf < calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: termStart))! { flags.append(.dateOutsideTerm) }
        if let termEnd, dayOf > calendar.date(byAdding: .day, value: 21, to: calendar.startOfDay(for: termEnd))! { flags.append(.dateOutsideTerm) }
        return Resolution(date: date, hasTime: clock != nil, flags: flags, resolvedFromText: fromText != nil)
    }

    /// Resolve a date-only value (used for term bounds and no-class dates).
    func resolveDay(iso: String?, asWritten: String) -> Date? {
        guard var day = iso.flatMap(ymd(iso:)) ?? day(in: asWritten, spans: explicitSpans(in: asWritten)) else { return nil }
        day.hour = 0; day.minute = 0; day.second = 0
        return calendar.date(from: day)
    }

    /// First and last day in a range like "Wednesday, November 25 – Friday, November 27".
    func dayRange(in text: String) -> (first: Date, last: Date)? {
        let spans = explicitSpans(in: text)
        guard var a = spans.first?.start, var b = spans.last?.end else { return nil }
        a.hour = 0; a.minute = 0; a.second = 0; b.hour = 0; b.minute = 0; b.second = 0
        guard let first = calendar.date(from: a), let last = calendar.date(from: b) else { return nil }
        return (first, max(first, last))
    }

    /// Wording that says the date is still to come, as whole words: "TBD", "TBA", "TBC", "to be announced / determined /
    /// decided / confirmed / posted / scheduled / arranged", "finals week" or "final exam period" (the registrar's
    /// timetable, not yet out), and "per the registrar". Empty text is not TBD; it is simply no wording.
    static func isTBD(_ s: String) -> Bool {
        (" " + Normalize.key(s) + " ").range(of: awaitingDate, options: .regularExpression) != nil
    }
    private static let awaitingDate = #" (tbd|tba|tbc) |\bto be (announced|determined|decided|confirmed|posted|scheduled|arranged)\b|\bfinals (week|period)\b|\bfinal exams? (week|period)\b|\bfinal examination (week|period)\b|\bexam(ination)? period\b|\b(per|by|from) (the )?([a-z]+ )?registrar\b"#

    /// "YYYY-MM-DD" → components, nil for malformed or impossible dates (2026-09-31 must not roll into October).
    func ymd(iso: String) -> DateComponents? {
        let parts = iso.trimmingCharacters(in: .whitespaces).prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1900...2200).contains(y) else { return nil }
        return exists(y, m, d) ? DateComponents(year: y, month: m, day: d) : nil
    }

    /// Whether the day is on the calendar (29 February only in a leap year).
    private func exists(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        let components = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == components
    }

    // MARK: The year of a date written without one

    /// Whether anything about the term places a date: its dates, or a label naming two years.
    var knowsTermYears: Bool { termWindow != nil || termYears != nil }

    /// The term's days, padded as `resolve` pads them for `dateOutsideTerm`. With one end unknown, the term is taken to
    /// run twenty weeks from the other; with both unknown, the label's season stands in.
    var termWindow: DateInterval? {
        let day: TimeInterval = 86_400, term = 140 * day
        let lower: Date, upper: Date
        switch (termStart, termEnd) {
        case let (start?, end?): lower = start - 14 * day; upper = end + 21 * day
        case let (start?, nil): lower = start - 14 * day; upper = start + term + 21 * day
        case let (nil, end?): lower = end - term - 14 * day; upper = end + 21 * day
        default:
            guard let season else { return nil }
            lower = season.start - 14 * day; upper = season.end + 21 * day
        }
        return upper > lower ? DateInterval(start: lower, end: upper) : nil
    }

    /// The months a term label's season covers: Fall or Autumn August to December, Spring January to May, Summer May to
    /// August, Winter January to March, of the label's year. Nil for a label with no season, or two years.
    static func season(of term: String?, calendar: Calendar) -> DateInterval? {
        guard let term, years(inTerm: term) == nil, let range = term.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression), let year = Int(term[range]) else { return nil }
        let key = " " + Normalize.key(term) + " "
        let months: (Int, Int)
        if key.contains(" fall ") || key.contains(" autumn ") { months = (8, 12) }
        else if key.contains(" spring ") { months = (1, 5) }
        else if key.contains(" summer ") { months = (5, 8) }
        else if key.contains(" winter ") { months = (1, 3) }
        else { return nil }
        guard let start = calendar.date(from: DateComponents(year: year, month: months.0, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: months.1 + 1, day: 1)) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The year of a month and day printed without one: of the default year, the year after and the year before, the one
    /// inside the term, else the nearest to it (a Fall term's "January 8" is the January after it; a ties goes to the
    /// default year). With the term's dates unknown, a two-year label's half (`termYears`), else the default year. Nil
    /// when the day exists in none of them (a 29 February two years from a leap year).
    func year(month: Int, day: Int) -> Int? {
        let candidates = [defaultYear, defaultYear + 1, defaultYear - 1].filter { exists($0, month, day) }
        guard let first = candidates.first else { return nil }
        if let window = termWindow {
            func distance(_ year: Int) -> TimeInterval {
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return .infinity }
                return date < window.start ? window.start.timeIntervalSince(date) : date > window.end ? date.timeIntervalSince(window.end) : 0
            }
            return candidates.min { distance($0) < distance($1) }   // the first of equals: the default year wins a tie
        }
        if let years = termYears {
            let half = month >= 8 ? years.lowerBound : years.upperBound
            return exists(half, month, day) ? half : first
        }
        return first
    }

    // MARK: Days in the wording

    /// Year-month-day named by free text: an explicit date first (the one after "due" when present, else the last),
    /// then a week-relative reference ("Week 3, Thursday"). TBD wording yields nil unless a single day is written anyway
    /// ("Friday, December 18, room TBA" is dated; "TBA (December 16–22)" is not).
    func day(in text: String) -> DateComponents? { day(in: text, spans: explicitSpans(in: text)) }

    func day(in text: String, spans: [Span]) -> DateComponents? {
        if let explicit = explicitDay(in: text, spans: spans) {
            if Self.isTBD(text), spans.allSatisfy({ $0.start != $0.end }) { return nil }
            return explicit
        }
        if Self.isTBD(text) { return nil }
        return weekRelativeDay(in: text)
    }

    /// The span after "due" when present, else the last span. A span's end is used because the detector
    /// reads "due Wed 9/9" as today-through-9/9.
    func explicitDay(in text: String, spans: [Span]) -> DateComponents? {
        guard !spans.isEmpty else { return nil }
        let candidate = prepared(text).text   // span locations are offsets into this string
        if let due = candidate.range(of: #"(?i)\bdue\b"#, options: .regularExpression) {
            let offset = NSRange(due, in: candidate).location
            if let after = spans.first(where: { $0.location >= offset }) { return after.end }
        }
        return spans.last!.end
    }

    struct Span: Sendable {
        var location: Int
        /// The matched wording as printed (the rewrites the detector needed undone).
        var text: String
        var start: DateComponents
        var end: DateComponents
        /// The wording printed the year; otherwise `year(month:day:)` chose it.
        var yearWritten = false
    }

    /// The text the detector reads, in pieces: each either the document's own words or a rewrite of them, so that a match
    /// is traced back to the wording as printed. Rewritten: numeric dates, into the region's order with their year
    /// (`numericDate`); a 29 February with no year, given a leap year (the detector puts a bare "Feb 29" in the next year
    /// that comes, and in a common year that is 1 March); and "due", which gets a colon. The detector reads "due
    /// <date>" as a span from today to that date and returns nothing at all once the date is behind today (a syllabus
    /// read in October lost every September deadline); "due:" is read as the date alone, whatever the day.
    struct Prepared {
        var text: String
        /// Each piece's place in `text` (UTF-16, as the detector counts) and the words as printed there.
        var pieces: [(range: NSRange, original: String, rewritten: Bool)]

        /// The words as printed under a stretch of `text`. A rewritten piece the stretch touches counts whole.
        func original(of range: NSRange) -> String {
            let ns = text as NSString
            var out = ""
            for piece in pieces {
                let overlap = NSIntersectionRange(piece.range, range)
                guard overlap.length > 0 else { continue }
                out += piece.rewritten ? piece.original : ns.substring(with: overlap)
            }
            return out
        }
    }

    func prepared(_ text: String) -> Prepared {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var edits: [(range: NSRange, text: String)] = []
        if let numeric = try? NSRegularExpression(pattern: Self.numericPattern) {
            for m in numeric.matches(in: text, range: all) {
                func part(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
                guard let a = part(1).flatMap(Int.init), let b = part(2).flatMap(Int.init),
                      let rewrite = numericDate(a, b, year: part(3)) else { continue }
                // After a number and a space ("Quiz 2 10/4") the detector finds no date at all; set apart, it does.
                let afterNumber = m.range.location >= 2 && ns.substring(with: NSRange(location: m.range.location - 2, length: 2)).range(of: #"^\d\s$"#, options: .regularExpression) != nil
                edits.append((m.range, afterNumber ? "(\(rewrite))" : rewrite))
            }
        }
        if let leap = try? NSRegularExpression(pattern: Self.leapDayPattern) {
            let year = self.year(month: 2, day: 29) ?? Self.nearestLeapYear(to: defaultYear)
            for m in leap.matches(in: text, range: all) { edits.append((m.range, ns.substring(with: m.range) + " \(year)")) }
        }
        if let due = try? NSRegularExpression(pattern: #"(?i)\bdue\b(?!:)"#) {
            for m in due.matches(in: text, range: all) { edits.append((m.range, "due:")) }
        }
        var out = "", pieces: [(range: NSRange, original: String, rewritten: Bool)] = [], at = 0
        func append(_ piece: String, original: String, rewritten: Bool) {
            let length = (piece as NSString).length
            pieces.append((NSRange(location: (out as NSString).length, length: length), original, rewritten))
            out += piece
        }
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) where edit.range.location >= at {
            if edit.range.location > at {
                let plain = ns.substring(with: NSRange(location: at, length: edit.range.location - at))
                append(plain, original: plain, rewritten: false)
            }
            append(edit.text, original: ns.substring(with: edit.range), rewritten: true)
            at = edit.range.location + edit.range.length
        }
        if at < ns.length { let rest = ns.substring(from: at); append(rest, original: rest, rewritten: false) }
        return Prepared(text: out, pieces: pieces)
    }

    /// "9/4", "9/4/26", "9/4/2026": two numbers and perhaps a year, not inside a longer run of them.
    private static let numericPattern = #"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])"#
    private static let leapDayPattern = #"(?i)\b(?:feb|february)\.?\s+29(?:st|nd|rd|th)?\b(?!,?\s*\d{4})|\b29(?:st|nd|rd|th)?\s+(?:feb|february)\b\.?(?!,?\s*\d{4})"#

    /// A numeric date in the document's order (`dayFirst`) as the detector will read it: in the region's order, with its
    /// year (as printed, else `year(month:day:)`). Nil for numbers that are no date ("13/20", "2/30").
    func numericDate(_ a: Int, _ b: Int, year printed: String?) -> String? {
        let (month, day) = dayFirst ? (b, a) : (a, b)
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year: Int
        if let printed, let y = Int(printed) { year = printed.count == 2 ? 2000 + y : y }
        else if let chosen = self.year(month: month, day: day) { year = chosen }
        else { return nil }
        guard exists(year, month, day) else { return nil }
        return Self.regionReadsDayFirst ? "\(day)/\(month)/\(year)" : "\(month)/\(day)/\(year)"
    }

    static func nearestLeapYear(to year: Int) -> Int {
        let leap = { (y: Int) in y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
        return [year, year + 1, year - 1, year + 2, year - 2, year + 3, year - 3, year + 4].first(where: leap) ?? year
    }

    /// Detector matches that name a specific day (a month with a day number, or a numeric date). Bare weekday names are
    /// ignored because the detector resolves them relative to today. A span written without a 4-digit year takes the
    /// year `year(month:day:)` chooses; the detector's own guess is never used.
    func explicitSpans(in text: String) -> [Span] {
        let prepared = prepared(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let ns = prepared.text as NSString
        return detector.matches(in: prepared.text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let date = match.date else { return nil }
            let written = prepared.original(of: match.range)
            guard written.range(of: Self.daySpecific, options: .regularExpression) != nil else { return nil }
            let yearWritten = written.range(of: #"\b(19|20)\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2}\b"#, options: .regularExpression) != nil
            var cal = calendar
            cal.timeZone = match.timeZone ?? .current   // the detector places a day in the device's zone, not the calendar's: read it there
            func day(_ d: Date) -> DateComponents {
                var c = cal.dateComponents([.year, .month, .day], from: d)
                if !yearWritten, let m = c.month, let dd = c.day, let y = year(month: m, day: dd) { c.year = y }
                return c
            }
            let end = match.duration > 0 ? date.addingTimeInterval(match.duration) : date
            return Span(location: match.range.location, text: written, start: day(date), end: day(end), yearWritten: yearWritten)
        }
    }

    private static let daySpecific = #"(?i)\b\d{1,2}[/.-]\d{1,2}\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?\b|\b\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b|\b\d{4}-\d{2}-\d{2}\b"#
    private static let weekdayPattern = #"(?i)\b(mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)\b"#
    /// A clock time with a meridiem, possibly the start of a range ("2:00–3:50 PM"), else a bare H:MM.
    private static let timePattern = #"\b(\d{1,2})(?::(\d{2}))?(?:\s*[–\-]\s*\d{1,2}(?::\d{2})?)?\s*([ap])\.?m\.?(?![a-z])|\b(\d{1,2}):(\d{2})\b"#

    // MARK: The order of numeric dates

    /// Whether the detector, in the device's region, reads "1/2/2030" as 1 February: numeric dates are then handed to it
    /// day first. Asked once per region.
    static var regionReadsDayFirst: Bool { regionOrder.dayFirst() }
    private static let regionOrder = RegionOrder()

    private final class RegionOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var known: (region: String, dayFirst: Bool)?
        func dayFirst() -> Bool {
            let region = Locale.current.identifier
            lock.lock(); defer { lock.unlock() }
            if let known, known.region == region { return known.dayFirst }
            let probe = "1/2/2030"
            let date = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue))?
                .firstMatch(in: probe, range: NSRange(location: 0, length: (probe as NSString).length))?.date
            let value = date.map { Calendar(identifier: .gregorian).component(.month, from: $0) == 2 } ?? false
            known = (region, value)
            return value
        }
    }

    /// Whether a document writes its numeric dates day first. For it: a first number over 12 ("13/9"), or a weekday
    /// printed before a date that only the day-first reading puts on that weekday; against: a second number over 12, or a
    /// weekday only month first fits. Month first when nothing decides, as a US syllabus writes them.
    static func readsDayFirst(_ text: String, year: Int, calendar: Calendar) -> Bool {
        guard let pattern = try? NSRegularExpression(pattern: #"(?i)(?:\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])"#) else { return false }
        let ns = text as NSString
        let weekdays = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var dayFirst = 0, monthFirst = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func part(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let a = part(2).flatMap(Int.init), let b = part(3).flatMap(Int.init), (1...31).contains(a), (1...31).contains(b) else { continue }
            if a > 12, b <= 12 { dayFirst += 1; continue }
            if b > 12, a <= 12 { monthFirst += 1; continue }
            guard a != b, let name = part(1), let weekday = weekdays[name.lowercased()] else { continue }
            let y = part(4).flatMap(Int.init).map { $0 < 100 ? 2000 + $0 : $0 } ?? year
            func weekdayOf(month: Int, day: Int) -> Int? { calendar.date(from: DateComponents(year: y, month: month, day: day, hour: 12)).map { calendar.component(.weekday, from: $0) } }
            let asMonthFirst = weekdayOf(month: a, day: b), asDayFirst = weekdayOf(month: b, day: a)
            if asDayFirst == weekday, asMonthFirst != weekday { dayFirst += 1 } else if asMonthFirst == weekday, asDayFirst != weekday { monthFirst += 1 }
        }
        return dayFirst > monthFirst
    }

    // MARK: Weeks

    /// A week of the term named in the wording ("Week 3"), relative to the Monday of the term's first week, and the
    /// weekday printed with it (the first one mentioned), if any.
    struct WeekReference {
        var monday: Date
        var weekday: Int?
        var day: DateComponents
        func contains(_ components: DateComponents, calendar: Calendar) -> Bool {
            guard let date = calendar.date(from: components), let end = calendar.date(byAdding: .day, value: 7, to: monday) else { return false }
            return date >= monday && date < end
        }
    }

    func weekReference(in text: String) -> WeekReference? {
        guard let termStart,
              let weekMatch = text.range(of: #"(?i)\bweek\s*(\d{1,2})\b"#, options: .regularExpression),
              let week = Int(text[weekMatch].filter(\.isNumber)) else { return nil }
        let weekdays = ["mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7, "sun": 1]
        let weekday = text.range(of: Self.weekdayPattern, options: .regularExpression).flatMap { weekdays[String(text[$0].lowercased().prefix(3))] }
        var cal = calendar; cal.firstWeekday = 2
        guard let first = cal.dateInterval(of: .weekOfYear, for: termStart)?.start,
              let monday = cal.date(byAdding: .day, value: (week - 1) * 7, to: first),
              let date = cal.date(byAdding: .day, value: ((weekday ?? 2) - 2 + 7) % 7, to: monday) else { return nil }
        return WeekReference(monday: monday, weekday: weekday, day: cal.dateComponents([.year, .month, .day], from: date))
    }

    /// "Week 3, Thursday" relative to the Monday of the term's first week; a week named without its day is its Monday.
    func weekRelativeDay(in text: String) -> DateComponents? { weekReference(in: text)?.day }

    static func time(in text: String) -> (hour: Int, minute: Int)? {
        let lowered = text.lowercased()
        if lowered.range(of: #"\bnoon\b"#, options: .regularExpression) != nil { return (12, 0) }
        if lowered.range(of: #"\bmidnight\b"#, options: .regularExpression) != nil { return (23, 59) }
        guard let match = lowered.range(of: timePattern, options: .regularExpression) else { return nil }
        let s = String(lowered[match])
        let digits = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let hourRaw = digits.first, hourRaw <= 24 else { return nil }
        let minute = s.contains(":") && digits.count > 1 ? digits[1] : 0
        var hour = hourRaw
        if s.contains("p"), hour < 12 { hour += 12 }
        if s.contains("a"), hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// Textual forms of a day that a document might use, for "does the source mention this date" checks. Numeric forms
    /// follow the document's order (`dayFirst`).
    func mentions(_ date: Date) -> [String] {
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let m = c.month, let d = c.day else { return [] }
        var english = calendar; english.locale = Locale(identifier: "en_US_POSIX")
        let name = english.monthSymbols[m - 1], short = english.shortMonthSymbols[m - 1]
        let (a, b) = dayFirst ? (d, m) : (m, d)
        var forms = ["\(a)/\(b)", String(format: "%02d/%02d", a, b), String(format: "%d/%02d", a, b), "\(name) \(d)", "\(short) \(d)", "\(short)\(d)", "\(d) \(name)", "\(d) \(short)"]
        if m == 9 { forms.append("Sept \(d)") }
        if let localized = calendar.locale, localized.language.languageCode != .english {
            forms += ["\(calendar.monthSymbols[m - 1]) \(d)", "\(calendar.shortMonthSymbols[m - 1]) \(d)"]
        }
        return forms.map(Normalize.key)
    }

    /// The term year: a 4-digit year in the term label, else the fallback.
    static func year(inTerm term: String?, fallback: Int) -> Int {
        guard let term, let range = term.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression), let y = Int(term[range]) else { return fallback }
        return y
    }

    /// The two years of a label that spans them: "2026–2027", "2026-27", "2026/27". Nil for a label with one year.
    static func years(inTerm term: String?) -> ClosedRange<Int>? {
        guard let term, let m = term.firstMatch(of: /\b((?:19|20)\d{2})\s*[-–—\/]\s*(\d{4}|\d{2})\b/), let first = Int(m.output.1), let raw = Int(m.output.2) else { return nil }
        let second = m.output.2.count == 2 ? first / 100 * 100 + raw : raw
        return second == first + 1 ? first...second : nil
    }
}
