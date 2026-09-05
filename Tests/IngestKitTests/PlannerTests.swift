import Foundation
import Testing
@testable import IngestKit

struct PlannerTests {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    static func at(_ h: Int, _ m: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: h, minute: m))! }
    static func input(now: Date = at(9), busy: [PlanBusy] = [], obligations: [PlanObligation] = []) -> PlanInput {
        PlanInput(date: at(0), now: now, busy: busy, obligations: obligations, calendar: calendar)
    }

    @Test func gapsFallBetweenFixedEventsFromNowOn() {
        let busy = [PlanBusy(title: "Calc lecture", start: Self.at(10), end: Self.at(11, 50)), PlanBusy(title: "Lab", start: Self.at(14), end: Self.at(16, 50)), PlanBusy(title: "Dinner", start: Self.at(21, 45), end: Self.at(22, 30))]
        let gaps = DayPlanner.gaps(in: Self.input(now: Self.at(9, 30), busy: busy))
        #expect(gaps.map { "\(Self.calendar.component(.hour, from: $0.start)):\(Self.calendar.component(.hour, from: $0.end))" } == ["9:10", "11:14", "16:21"])
        #expect(gaps.allSatisfy { $0.duration >= 25 * 60 })
        // Nothing left after a late start.
        #expect(DayPlanner.gaps(in: Self.input(now: Self.at(22, 30))).isEmpty)
    }

    @Test func rankingIsNearestDeadlineThenWeight() {
        let items = [PlanObligation(title: "HW 4", due: Self.at(23), points: 1.5), PlanObligation(title: "Exam 1", due: Self.at(23).addingTimeInterval(86400), points: 25),
                     PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6), PlanObligation(title: "Old", due: Self.at(0).addingTimeInterval(-86400), points: 30)]
        #expect(DayPlanner.ranked(Self.input(obligations: items)).map(\.title) == ["Quiz 3", "HW 4", "Exam 1"])   // yesterday's is gone
    }

    @Test func validationKeepsBlocksInsideTheGapsAndInOrder() {
        let busy = [PlanBusy(title: "Lecture", start: Self.at(10), end: Self.at(12))]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6)])
        let gaps = DayPlanner.gaps(in: input)
        let draft = PlanDraft(blocks: [
            PlanDraftBlock(start: "09:00", end: "09:50", title: "quiz 3", reason: "Due tonight.", kind: "work"),
            PlanDraftBlock(start: "10:30", end: "11:00", title: "Read", reason: "Over the lecture.", kind: "work"),       // inside a fixed event: dropped
            PlanDraftBlock(start: "11:45", end: "13:00", title: "Eat", reason: "Lunch.", kind: "meal"),                 // clipped to the gap's start at 12:00
            PlanDraftBlock(start: "12:30", end: "13:20", title: "Problem set", reason: "Overlaps the meal.", kind: "work"),   // starts before the previous block ended: moved after it
            PlanDraftBlock(start: "25:00", end: "26:00", title: "Nonsense", reason: "", kind: "work"),
            PlanDraftBlock(start: "14:00", end: "14:50", title: "Quiz 3 (Calculus II)", reason: "More of the same.", kind: "work"),   // second block on Quiz 3: kept, snapped
            PlanDraftBlock(start: "15:00", end: "15:50", title: "quiz 3", reason: "A third.", kind: "work"),                          // third: dropped
        ])
        let blocks = DayPlanner.validate(draft, gaps: gaps, input: input, ranked: DayPlanner.ranked(input))
        #expect(blocks.map(\.title) == ["Quiz 3", "Eat", "Problem set", "Quiz 3"])   // the obligation's own spelling comes back
        #expect(blocks.map { Self.calendar.component(.hour, from: $0.start) } == [9, 12, 13, 14])
        #expect(blocks[1].kind == .meal && blocks[2].start == blocks[1].end)
    }

    @Test func fallbackPlansByTheNumbersWithAMeal() {
        let input = Self.input(now: Self.at(11), obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6), PlanObligation(title: "HW 4", due: Self.at(23).addingTimeInterval(86400), points: 1.5)])
        let gaps = DayPlanner.gaps(in: input)
        let blocks = DayPlanner.fallback(input, gaps: gaps, ranked: DayPlanner.ranked(input))
        #expect(blocks.prefix(3).map(\.title) == ["Quiz 3", "Eat", "HW 4"])
        #expect(blocks[0].reason == "Due today, worth 6% of the grade." && blocks[1].kind == .meal)
    }
}
