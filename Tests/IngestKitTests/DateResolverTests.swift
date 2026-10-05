import Foundation
import Testing
@testable import IngestKit

struct DateResolverTests {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    static func ymd(_ y: Int, _ m: Int, _ d: Int) -> DateComponents { DateComponents(year: y, month: m, day: d) }
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: ymd(y, m, d))! }
    let resolver = DateResolver(calendar: calendar, defaultYear: 2026, termStart: date(2026, 9, 2), termEnd: date(2026, 12, 14))
    /// A term in a different year than today's, so year injection is actually exercised.
    let spring = DateResolver(calendar: calendar, defaultYear: 2031)

    @Test(arguments: [
        ("Wed 9/9", 2026, 9, 9), ("9/16", 2026, 9, 16), ("Sept 14", 2026, 9, 14), ("Sept 14th", 2026, 9, 14), ("Wednesday, October 7", 2026, 10, 7),
        ("Oct 7, 11:59 PM", 2026, 10, 7), ("Sep 25, 2026 11:59 PM", 2026, 9, 25), ("Thu Dec 3", 2026, 12, 3),
        ("March 3rd", 2027, 3, 3),                                     // no year printed: the March after a Fall term, not the one before it
        ("Week 1 (Sep 2): HW 1 due Wed 9/9", 2026, 9, 9),            // date after "due" wins over earlier dates
        ("Wednesday, November 25 – Friday, November 27", 2026, 11, 27), // last date when no "due"
        ("Friday, December 18, 2026, 10:00 AM–12:00 PM, room TBA", 2026, 12, 18),   // "TBA" about the room, not the date
        ("Week 3, Thursday", 2026, 9, 17),                             // week-relative: Monday of week 1 is Aug 31
        ("Week 2 Friday", 2026, 9, 11),
        ("Week 3, Thursday: Quiz 2 (covers Mon/Wed material)", 2026, 9, 17),   // first weekday mentioned wins
        ("Week 5 (this month we cover chapter 5)", 2026, 9, 28),       // "month" is not "mon": Monday of week 5
    ])
    func resolvesDays(text: String, y: Int, m: Int, d: Int) {
        #expect(resolver.day(in: text) == Self.ymd(y, m, d), "\(text)")
    }

    @Test(arguments: [("Oct 7, 11:59 PM", 10, 7), ("Feb 5", 2, 5), ("2/19", 2, 19), ("Thursday, February 25", 2, 25), ("Sep 16 at 11:59PM", 9, 16)])
    func injectsTheTermYearEvenAfterATime(text: String, m: Int, d: Int) {
        #expect(spring.day(in: text) == Self.ymd(2031, m, d), "\(text)")
    }

    @Test(arguments: ["TBA", "TBD", "date TBA by the registrar", "to be announced", "TBA (December 16–22)", "Finals Week", "Date/Time per NYU Registrar",
                      "to be confirmed", "TBC", "to be posted", "to be scheduled", "during the final exam period", "Finals week (December 16–22)"])
    func tbdIsNil(text: String) {
        #expect(resolver.day(in: text) == nil)
        #expect(DateResolver.isTBD(text))
    }

    @Test func emptyWordingIsNotTBD() {
        #expect(!DateResolver.isTBD("") && resolver.day(in: "") == nil)
        let r = resolver.resolve(iso: "2026-09-09", asWritten: "")
        #expect(Self.calendar.component(.day, from: r.date!) == 9 && !r.resolvedFromText)   // the model's date stands; Merger caps it to review
    }

    @Test func dueWordingIsAuthoritative() {
        // "Sep 23 … due Sep 30": the model picked the session date, which the wording also names, but "due" settles it.
        let r = resolver.resolve(iso: "2026-09-23", asWritten: "Sep 23 lab, report due Sep 30")
        #expect(Self.calendar.component(.day, from: r.date!) == 30 && r.flags == [.dateDisagreement])
        #expect(resolver.day(in: "9/4, 9/11 due 9/18") == Self.ymd(2026, 9, 18))   // "due" located in the same string the detector saw
        #expect(resolver.day(in: "9/2 9/4 due 9/9") == Self.ymd(2026, 9, 9))
    }

    @Test func yearIsDecidedPerSpan() {
        #expect(spring.day(in: "Sep 9 (room 2019)") == Self.ymd(2031, 9, 9))          // a stray 4-digit number is not the date's year
        #expect(spring.day(in: "September 9, 2026") == Self.ymd(2026, 9, 9))          // a year written with the date is kept
    }

    @Test func modelAndTextAgree() {
        let r = resolver.resolve(iso: "2026-09-09", asWritten: "Wed 9/9")
        #expect(Self.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: r.date!) == DateComponents(year: 2026, month: 9, day: 9, hour: 23, minute: 59))
        #expect(!r.hasTime && r.flags.isEmpty && r.resolvedFromText)
    }

    @Test func textWinsOverModelWhenTheyDisagree() {
        let r = resolver.resolve(iso: "2026-09-02", asWritten: "Wed 9/9")
        #expect(Self.calendar.component(.day, from: r.date!) == 9)
        #expect(r.flags == [.dateDisagreement])
    }

    @Test func modelMayPickAnyDateTheWordingNames() {
        let r = resolver.resolve(iso: "2026-10-07", asWritten: "Midterm 1: Wednesday, October 7 (review session Oct 5)")
        #expect(Self.calendar.component(.day, from: r.date!) == 7 && r.flags.isEmpty)
    }

    @Test func modelDateUsedWhenTextIsRelative() {
        let noTerm = DateResolver(calendar: Self.calendar, defaultYear: 2026)
        let r = noTerm.resolve(iso: "2026-10-09", asWritten: "Week 6 Friday")
        #expect(Self.calendar.component(.day, from: r.date!) == 9 && r.flags.isEmpty && !r.resolvedFromText)
    }

    @Test func tbdWordingRejectsAModelDate() {
        let r = resolver.resolve(iso: "2026-12-14", asWritten: "TBA")
        #expect(r.date == nil && r.flags.isEmpty)
    }

    @Test func impossibleISODatesAreRejected() {
        #expect(resolver.ymd(iso: "2026-09-31") == nil)
        #expect(resolver.ymd(iso: "2026-13-01") == nil)
        #expect(resolver.ymd(iso: "2026-02-28") == Self.ymd(2026, 2, 28))
        #expect(resolver.resolve(iso: "2026-09-31", asWritten: "sometime").date == nil)
    }

    @Test func timeOfDay() {
        #expect(DateResolver.time(in: "Oct 7, 11:59 PM")! == (23, 59))
        #expect(DateResolver.time(in: "9:00 am")! == (9, 0))
        #expect(DateResolver.time(in: "2pm")! == (14, 0))
        #expect(DateResolver.time(in: "Sep 16 at 11:59PM")! == (23, 59))
        #expect(DateResolver.time(in: "Thursday, December 17, 2026, 2:00–3:50 PM")! == (14, 0))   // start of a range, with the meridiem
        #expect(DateResolver.time(in: "10:00 AM–12:00 PM")! == (10, 0))
        #expect(DateResolver.time(in: "1:00-2:15pm")! == (13, 0))
        #expect(DateResolver.time(in: "due at noon")! == (12, 0))
        #expect(DateResolver.time(in: "by midnight")! == (23, 59))
        #expect(DateResolver.time(in: "Wed 9/9") == nil)
        let r = resolver.resolve(iso: nil, asWritten: "Friday, March 26, 5:00 PM")
        #expect(r.hasTime && Self.calendar.component(.hour, from: r.date!) == 17)
    }

    @Test func outsideTermIsFlagged() {
        #expect(resolver.resolve(iso: "2027-03-01", asWritten: "March 1, 2027").flags.contains(.dateOutsideTerm))
    }

    @Test func unresolvedNonTBDIsFlagged() {
        let r = resolver.resolve(iso: nil, asWritten: "sometime after the break")
        #expect(r.date == nil && r.flags == [.dateUnresolved])
    }

    @Test func ranges() {
        let r = resolver.dayRange(in: "Wednesday, November 25 – Friday, November 27")!
        #expect(Self.calendar.component(.day, from: r.first) == 25 && Self.calendar.component(.day, from: r.last) == 27)
        #expect(resolver.dayRange(in: "March 15–19, 2027")?.last == Self.date(2027, 3, 19))
        #expect(spring.dayRange(in: "March 15–19")?.first == Self.date(2031, 3, 15))
    }

    @Test func termYear() {
        #expect(DateResolver.year(inTerm: "Spring 2027", fallback: 2026) == 2027)
        #expect(DateResolver.year(inTerm: nil, fallback: 2026) == 2026)
        #expect(DateResolver.years(inTerm: "Academic Year 2026-2027") == 2026...2027 && DateResolver.years(inTerm: "2026–27") == 2026...2027)
        #expect(DateResolver.years(inTerm: "Fall 2026") == nil && DateResolver.years(inTerm: "2026-2029") == nil)
    }

    @Test func aDateWithoutAYearTakesTheYearThatPutsItInTheTerm() {
        // A Fall term's final in January is the January after it, and the model saying so is no disagreement.
        let fall = DateResolver(calendar: Self.calendar, defaultYear: 2026, termStart: Self.date(2026, 9, 8), termEnd: Self.date(2026, 12, 18))
        let final = fall.resolve(iso: "2027-01-08", asWritten: "January 8, 9:00 AM")
        #expect(Self.calendar.dateComponents([.year, .month, .day, .hour], from: final.date!) == DateComponents(year: 2027, month: 1, day: 8, hour: 9) && final.flags.isEmpty)
        #expect(fall.day(in: "September 15") == Self.ymd(2026, 9, 15) && fall.day(in: "1/8") == Self.ymd(2027, 1, 8))
        // A label naming two years: autumn in the first, the rest in the second.
        var academic = DateResolver(calendar: Self.calendar, defaultYear: 2026)
        academic.termYears = 2026...2027
        #expect(academic.day(in: "Essay 4 due March 12") == Self.ymd(2027, 3, 12) && academic.day(in: "October 2") == Self.ymd(2026, 10, 2))
        // Only the label's season known: still the January after a Fall term.
        var season = DateResolver(calendar: Self.calendar, defaultYear: 2026)
        season.season = DateResolver.season(of: "Fall 2026", calendar: Self.calendar)
        #expect(season.day(in: "Final Exam: January 8") == Self.ymd(2027, 1, 8) && season.day(in: "Dec 3") == Self.ymd(2026, 12, 3))
        #expect(DateResolver.season(of: "Academic Year 2026-2027", calendar: Self.calendar) == nil)
        // Nothing known about the term: the model's year, one either side of the default, stands where the wording has none.
        let blind = DateResolver(calendar: Self.calendar, defaultYear: 2026)
        let r = blind.resolve(iso: "2027-01-20", asWritten: "Jan 20")
        #expect(Self.calendar.component(.year, from: r.date!) == 2027 && r.flags.isEmpty)
        #expect(Self.calendar.component(.year, from: blind.resolve(iso: "2024-01-20", asWritten: "Jan 20").date!) == 2026)   // two years off is a slip, not a year
    }

    @Test func aLeapDayStaysTheTwentyNinth() {
        let leap = DateResolver(calendar: Self.calendar, defaultYear: 2028)
        #expect(leap.day(in: "Feb 29") == Self.ymd(2028, 2, 29) && leap.day(in: "2/29") == Self.ymd(2028, 2, 29) && leap.day(in: "Tuesday, February 29") == Self.ymd(2028, 2, 29))
        let before = DateResolver(calendar: Self.calendar, defaultYear: 2027)   // the leap year beside it
        #expect(before.day(in: "Feb 29") == Self.ymd(2028, 2, 29) && before.day(in: "2/29") == Self.ymd(2028, 2, 29))
        let r = resolver.resolve(iso: nil, asWritten: "Feb 29")   // no leap year near a 2026 term: never 1 March, and out of the term
        #expect(Self.calendar.dateComponents([.month, .day], from: r.date!) == DateComponents(month: 2, day: 29) && r.flags.contains(.dateOutsideTerm))
    }

    @Test func numericDatesFollowTheDocumentNeverTheRegion() {
        // The detector reads "9/4" by the device's region; the resolver hands it every numeric date in that order itself.
        #expect(resolver.day(in: "HW 3 due 9/4") == Self.ymd(2026, 9, 4) && resolver.day(in: "9/4/2026") == Self.ymd(2026, 9, 4) && resolver.day(in: "9/4/26") == Self.ymd(2026, 9, 4))
        #expect(resolver.day(in: "9/4-9/11")?.day == 11 && resolver.dayRange(in: "9/4-9/11")?.first == Self.date(2026, 9, 4))
        // A document proves day first by a first number over 12, or a weekday only that reading fits.
        #expect(DateResolver.readsDayFirst("Quiz 1 13/9, Quiz 2 4/10", year: 2026, calendar: Self.calendar))
        #expect(DateResolver.readsDayFirst("Lab 2 Thu 9/4", year: 2026, calendar: Self.calendar))        // 9 April 2026 is a Thursday; 4 September a Friday
        #expect(!DateResolver.readsDayFirst("HW 3 due Fri 9/4, HW 4 due 9/23", year: 2026, calendar: Self.calendar))
        #expect(!DateResolver.readsDayFirst("HW 3 due 9/4", year: 2026, calendar: Self.calendar))         // nothing decides: month first
        var british = resolver
        british.dayFirst = true
        #expect(british.day(in: "Quiz 2 4/10") == Self.ymd(2026, 10, 4) && british.day(in: "13/9") == Self.ymd(2026, 9, 13))   // after a number, too
        #expect(british.mentions(Self.date(2026, 10, 4)).contains("4 10") && !british.mentions(Self.date(2026, 10, 4)).contains("10 4"))
    }

    @Test func aWeekWithoutItsDayLeavesTheDayToTheModelInsideIt() {
        let term = DateResolver(calendar: Self.calendar, defaultYear: 2026, termStart: Self.date(2026, 8, 31))
        let inWeek = term.resolve(iso: "2026-09-18", asWritten: "due end of Week 3")
        #expect(Self.calendar.component(.day, from: inWeek.date!) == 18 && inWeek.flags.isEmpty && inWeek.resolvedFromText)
        let none = term.resolve(iso: nil, asWritten: "Week 3")
        #expect(Self.calendar.component(.day, from: none.date!) == 14 && none.flags == [.dateAmbiguous])   // the Monday, for review
        let outside = term.resolve(iso: "2026-09-25", asWritten: "Week 3")
        #expect(Self.calendar.component(.day, from: outside.date!) == 14 && outside.flags.contains(.dateAmbiguous) && outside.flags.contains(.dateDisagreement))
        #expect(term.resolve(iso: nil, asWritten: "Week 3, Thursday").flags.isEmpty)   // a day named: as before
    }

    @Test func mentions() {
        let forms = resolver.mentions(Self.date(2026, 10, 7))
        #expect(forms.contains("10 7") && forms.contains("october 7") && forms.contains("oct 7") && forms.contains("7 october"))
        #expect(resolver.mentions(Self.date(2026, 9, 14)).contains("sept 14"))
    }
}
