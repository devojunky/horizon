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

    @Test func levelFollowsTheDaysAcrossTheScreen() {
        #expect(Strip.level(daysAcross: 137) == .weeks && Strip.level(daysAcross: 76) == .weeks)   // a semester, three months
        #expect(Strip.level(daysAcross: 30) == .days && Strip.level(daysAcross: 60) == .days)      // a month, two
        #expect(Strip.level(daysAcross: 14) == .items && Strip.level(daysAcross: 21) == .items)    // two weeks, three
    }

    @Test func cellsGroupItemsByWeekOrDayHeaviestFirst() {
        let a = item("PS2", Fixture.day(10, 7), points: 4), b = item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25)
        let c = item("HW", Fixture.day(10, 8), points: 2, completed: true), d = item("Paper", Fixture.day(10, 20), points: nil)
        let days = Strip.cells([a, c, b, d], level: .days, calendar: Fixture.calendar)
        #expect(days.map(\.count) == [2, 1, 1] && days[0].items.map(\.title) == ["Exam 1", "PS2"])
        #expect(days[0].points == 29 && days[1].points == 0)                                    // done items carry no load
        #expect(Strip.cells([a, c, b, d], level: .items, calendar: Fixture.calendar) == days)     // the items level reads days too
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
