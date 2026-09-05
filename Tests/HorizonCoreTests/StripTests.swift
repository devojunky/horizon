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

    @Test func itemsOnADayComeHeaviestFirst() {
        let a = item("PS2", Fixture.day(10, 7), points: 4), b = item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25), c = item("HW", Fixture.day(10, 8), points: 2)
        #expect(Strip.items(on: Fixture.day(10, 7, hour: 12, minute: 0), in: [a, c, b], calendar: Fixture.calendar).map(\.title) == ["Exam 1", "PS2"])
    }
}
