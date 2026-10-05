import Foundation
import Testing
@testable import HorizonCore

struct StripTests {
    func item(_ title: String, _ due: Date, points: Double?, course: String = "MA-UY 1124", completed: Bool = false) -> StripItem {
        StripItem(id: UUID(), title: title, courseID: nil, courseCode: course, due: due, dueHasTime: true, points: points, state: .projected, completed: completed)
    }

    @Test func massFollowsPointsWithASquareRoot() {
        #expect(Strip.mass(points: 4) < Strip.mass(points: 12) && Strip.mass(points: 12) < Strip.mass(points: 30))
        #expect(Strip.mass(points: 30) <= 1 && Strip.mass(points: 60) == 1)
        #expect(Strip.mass(points: nil) < Strip.mass(points: 4))   // unknown weight reads light, never invisible
        #expect(Strip.mass(points: nil) > 0)
    }

    @Test func twoHeavyItemsWithinADayCollide() {
        let exam1 = item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25)
        let exam2 = item("Midterm", Fixture.day(10, 7, hour: 10, minute: 30), points: 20, course: "PH-UY 1013")
        let set = item("PS2", Fixture.day(10, 7), points: 4)
        let later = item("Exam 2", Fixture.day(10, 9, hour: 9, minute: 0), points: 30)
        let c = Strip.collisions([set, later, exam2, exam1], calendar: Fixture.calendar)
        #expect(c.count == 1 && c[0].items.map(\.title) == ["Exam 1", "Midterm"])   // the 4% set is not part of the pileup; Exam 2 is two days off
        #expect(Fixture.calendar.component(.day, from: c[0].day) == 7)
        // A completed item no longer weighs on the day.
        let done = item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25, completed: true)
        #expect(Strip.collisions([done, exam2], calendar: Fixture.calendar).isEmpty)
    }

    @Test func spanPadsTheTermByAWeekAndHoldsEveryItem() {
        let items = [item("Late paper", Fixture.day(12, 20), points: 10)]
        let span = Strip.span(termStarts: [Fixture.day(9, 2)], termEnds: [Fixture.day(12, 14)], items: items, now: Fixture.day(9, 21), calendar: Fixture.calendar)
        #expect(Fixture.calendar.dateComponents([.month, .day], from: span.lowerBound) == DateComponents(month: 8, day: 26))
        #expect(Fixture.calendar.dateComponents([.month, .day], from: span.upperBound) == DateComponents(month: 12, day: 28))
        // No term dates: today and the items bound the strip.
        let bare = Strip.span(termStarts: [], termEnds: [], items: items, now: Fixture.day(9, 21), calendar: Fixture.calendar)
        #expect(Fixture.calendar.dateComponents([.month, .day], from: bare.lowerBound) == DateComponents(month: 9, day: 14))
    }

    @Test func theOverviewFitsAndADayIsNeverNarrowerThanAFingerNeeds() {
        // The overview is read, not hit: the term's weeks share the width, however narrow.
        #expect(Strip.barWidth(.weeks, width: 400, weeks: 19, minimumBar: Strip.minimumBar(touch: true)) == 400.0 / 19)
        #expect(Strip.barWidth(.weeks, width: 1500, weeks: 19, minimumBar: Strip.minimumBar(touch: false)) == 1500.0 / 19)
        // A day is a control: on a phone two weeks across would be 28 points a day, so days hold 44 and the strip scrolls.
        #expect(Strip.barWidth(.days, width: 400, weeks: 19, minimumBar: Strip.minimumBar(touch: true)) == 44)
        #expect(Strip.barWidth(.days, width: 1500, weeks: 19, minimumBar: Strip.minimumBar(touch: false)) == 107)
        #expect(Strip.barWidth(.weeks, width: 300, weeks: 0, minimumBar: 28) == 300)
    }

    @Test func aTouchOnTheOverviewMeansTheWeekWithSomethingInIt() {
        let busy: Set<Int> = [2, 3, 9]
        let at: (Double) -> Int? = { Strip.week(at: $0, barWidth: 20, weeks: 12, hasItems: busy.contains, reach: 22) }
        #expect(at(50) == 2 && at(70) == 3)        // under the finger, and busy
        #expect(at(85) == 3 && at(30) == 2)        // an empty week beside a busy one: the busy one was meant
        #expect(at(130) == 6)                      // nothing within reach: the week under the finger, empty as it is
        #expect(at(-5) == 0 && at(999) == 11)      // off either end: the first week, the last
        #expect(Strip.week(at: 10, barWidth: 20, weeks: 0, hasItems: { _ in true }, reach: 22) == nil)
    }

    @Test func thePeriodsCoverTheSpanWholeAndInOrder() {
        let span = Fixture.day(8, 26, hour: 0, minute: 0)...Fixture.day(12, 28, hour: 0, minute: 0)
        let weeks = Strip.periods(in: span, level: .weeks, calendar: Fixture.calendar)
        #expect(weeks.count == 19 && weeks.first!.contains(span.lowerBound) && weeks.last!.contains(span.upperBound))
        #expect(zip(weeks, weeks.dropFirst()).allSatisfy { $0.end == $1.start })                                   // no gaps, no overlaps, through the clocks going back in November
        let days = Strip.periods(in: span, level: .days, calendar: Fixture.calendar)
        #expect(days.count == 125 && days.first!.start == span.lowerBound && Set(days.map(\.start)).count == 125)
    }

    @Test func cellsGroupItemsByWeekOrDayHeaviestFirst() {
        let a = item("PS2", Fixture.day(10, 7), points: 4), b = item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25)
        let c = item("HW", Fixture.day(10, 8), points: 2, completed: true), d = item("Paper", Fixture.day(10, 20), points: nil)
        let days = Strip.cells([a, c, b, d], level: .days, calendar: Fixture.calendar)
        #expect(days.map(\.count) == [2, 1, 1] && days[0].items.map(\.title) == ["Exam 1", "PS2"])
        #expect(days[0].points == 29 && days[1].points == 0)                                    // done items carry no load
        let weeks = Strip.cells([a, c, b, d], level: .weeks, calendar: Fixture.calendar)
        #expect(weeks.count == 2 && weeks[0].count == 3 && weeks[0].points == 29)
        #expect(weeks[0].period == Strip.period(containing: Fixture.day(10, 8), level: .weeks, calendar: Fixture.calendar))
        #expect(Strip.heat(points: 25) > Strip.heat(points: 4) && Strip.heat(points: nil) >= 0.2 && Strip.heat(points: 40) == 1)
    }

    @Test func itemsOnADayComeHeaviestFirst() {
        let a = item("PS2", Fixture.day(10, 7), points: 4), b = item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25), c = item("HW", Fixture.day(10, 8), points: 2)
        #expect(Strip.items(on: Fixture.day(10, 7, hour: 12, minute: 0), in: [a, c, b], calendar: Fixture.calendar).map(\.title) == ["Exam 1", "PS2"])
    }

    @Test func bandsShareTheRoomAndNeverShrinkPastACount() {
        #expect(Strip.rowHeight(rows: 1, available: 300) == 96)          // one course: roomy, not a wall
        #expect(Strip.rowHeight(rows: 5, available: 246) == 49)          // four courses and the total: compact
        #expect(Strip.rowHeight(rows: 9, available: 246) == 44)          // a full load: the floor holds, the strip grows and the page scrolls
        #expect(Strip.rowHeight(rows: 0, available: 246) == 96)
        #expect(!Strip.showsTotal(bands: 1) && Strip.showsTotal(bands: 2))   // one course is its own total
    }
}

extension StripTests {
    @Test func aPileupIsADayApartAcrossTheChangeOfClocks() {
        let cal = Fixture.calendar
        func heavy(_ m: Int, _ d: Int) -> StripItem { StripItem(id: UUID(), title: "Exam \(m)/\(d)", courseID: nil, courseCode: "X", due: Fixture.day(m, d), dueHasTime: false, points: 20, state: .projected) }
        #expect(Strip.collisions([heavy(10, 31), heavy(11, 1)], calendar: cal).count == 1)   // Sat and Sun: 25 hours apart across the fall-back night
        #expect(Strip.collisions([heavy(11, 2), heavy(11, 3)], calendar: cal).count == 1)
        #expect(Strip.collisions([heavy(11, 2), heavy(11, 4)], calendar: cal).isEmpty)
        // A period holds its start and not its end.
        let day = DateInterval(start: cal.startOfDay(for: Fixture.day(11, 2)), duration: 86_400)
        #expect(day.holds(day.start) && !day.holds(day.end) && day.contains(day.end))
    }
}
