import Foundation

/// Deterministic date resolution. The model's ISO date is cross-checked against a re-parse of the exact wording it
/// copied from the document. The wording wins when they disagree, with one exception: wording that names several
/// dates without saying "due" lets the model choose among them.
struct DateResolver: Sendable {
    var calendar: Calendar
    /// Year for dates written without one. The term label's year when the document has one.
    var defaultYear: Int
    var termStart: Date?
    var termEnd: Date?

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
        let fromText = day(in: asWritten, spans: spans)
        var flags: [ParseFlag] = []
        var day: DateComponents?
        if let t = fromText {
            let dueAnchored = asWritten.range(of: #"(?i)\bdue\b"#, options: .regularExpression) != nil
            if let m = fromModel, m != t, !dueAnchored, spans.contains(where: { $0.start == m || $0.end == m }) {
                day = m   // several dates named, none marked "due": the model's choice among them stands
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
        if let termStart, date < calendar.date(byAdding: .day, value: -14, to: termStart)! { flags.append(.dateOutsideTerm) }
        if let termEnd, date > calendar.date(byAdding: .day, value: 21, to: termEnd)! { flags.append(.dateOutsideTerm) }
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

    /// "TBD", "TBA", "to be announced/determined" as whole words. Empty text is not TBD; it is simply no wording.
    static func isTBD(_ s: String) -> Bool {
        let k = " " + Normalize.key(s) + " "
        return k.contains(" tbd ") || k.contains(" tba ") || k.contains("to be announced") || k.contains("to be determined")
    }

    /// "YYYY-MM-DD" → components, nil for malformed or impossible dates (2026-09-31 must not roll into October).
    func ymd(iso: String) -> DateComponents? {
        let parts = iso.trimmingCharacters(in: .whitespaces).prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1900...2200).contains(y) else { return nil }
        let components = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }

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
        let candidate = candidate(for: text)   // span locations are offsets into this string
        if let due = candidate.range(of: #"(?i)\bdue\b"#, options: .regularExpression) {
            let offset = NSRange(due, in: candidate).location
            if let after = spans.first(where: { $0.location >= offset }) { return after.end }
        }
        return spans.last!.end
    }

    struct Span: Sendable {
        var location: Int
        /// The matched wording as written (any injected year removed).
        var text: String
        var start: DateComponents
        var end: DateComponents
    }

    /// The text the detector runs on: numeric M/D dates get the term year appended so they are recognized, and "due"
    /// gets a colon. The detector reads "due <date>" as a span from today to that date and returns nothing at all
    /// once the date is behind today (a syllabus read in October lost every September deadline); "due:" is read as
    /// the date alone, whatever the day. Span locations and the "due" search below both use this text.
    private func candidate(for text: String) -> String {
        text.replacingOccurrences(of: #"\b(\d{1,2})/(\d{1,2})\b(?!/)"#, with: "$1/$2/\(defaultYear)", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bdue\b(?!:)"#, with: "due:", options: .regularExpression)
    }

    /// Detector matches that name a specific day (a month with a day number, or numeric M/D). Bare weekday names are
    /// ignored because the detector resolves them relative to today. A span written without a 4-digit year takes
    /// `defaultYear`; the detector's own guess is never used.
    func explicitSpans(in text: String) -> [Span] {
        let candidate = candidate(for: text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let ns = candidate as NSString
        return detector.matches(in: candidate, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let date = match.date else { return nil }
            let written = ns.substring(with: match.range).replacingOccurrences(of: "/\(defaultYear)", with: "")
            guard written.range(of: Self.daySpecific, options: .regularExpression) != nil else { return nil }
            let writtenYear = written.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil
            var cal = calendar
            if let tz = match.timeZone { cal.timeZone = tz }
            func day(_ d: Date) -> DateComponents {
                var c = cal.dateComponents([.year, .month, .day], from: d)
                if !writtenYear { c.year = defaultYear }
                return c
            }
            let end = match.duration > 0 ? date.addingTimeInterval(match.duration) : date
            return Span(location: match.range.location, text: written, start: day(date), end: day(end))
        }
    }

    private static let daySpecific = #"(?i)\b\d{1,2}[/.-]\d{1,2}\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?\b|\b\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b|\b\d{4}-\d{2}-\d{2}\b"#
    private static let weekdayPattern = #"(?i)\b(mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)\b"#
    /// A clock time with a meridiem, possibly the start of a range ("2:00–3:50 PM"), else a bare H:MM.
    private static let timePattern = #"\b(\d{1,2})(?::(\d{2}))?(?:\s*[–\-]\s*\d{1,2}(?::\d{2})?)?\s*([ap])\.?m\.?(?![a-z])|\b(\d{1,2}):(\d{2})\b"#

    /// "Week 3, Thursday" relative to the Monday of the term's first week. The first weekday mentioned wins.
    func weekRelativeDay(in text: String) -> DateComponents? {
        guard let termStart,
              let weekMatch = text.range(of: #"(?i)\bweek\s*(\d{1,2})\b"#, options: .regularExpression),
              let week = Int(text[weekMatch].filter(\.isNumber)) else { return nil }
        let weekdays = ["mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7, "sun": 1]
        let weekday = text.range(of: Self.weekdayPattern, options: .regularExpression).flatMap { weekdays[String(text[$0].lowercased().prefix(3))] }
        var cal = calendar; cal.firstWeekday = 2
        guard let monday = cal.dateInterval(of: .weekOfYear, for: termStart)?.start else { return nil }
        let offset = (week - 1) * 7 + ((weekday ?? 2) - 2 + 7) % 7
        guard let date = cal.date(byAdding: .day, value: offset, to: monday) else { return nil }
        return cal.dateComponents([.year, .month, .day], from: date)
    }

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

    /// Textual forms of a day that a document might use, for "does the source mention this date" checks.
    func mentions(_ date: Date) -> [String] {
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let m = c.month, let d = c.day else { return [] }
        var english = calendar; english.locale = Locale(identifier: "en_US_POSIX")
        let name = english.monthSymbols[m - 1], short = english.shortMonthSymbols[m - 1]
        var forms = ["\(m)/\(d)", String(format: "%02d/%02d", m, d), String(format: "%d/%02d", m, d), "\(name) \(d)", "\(short) \(d)", "\(short)\(d)", "\(d) \(name)", "\(d) \(short)"]
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
}
