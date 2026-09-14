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

    @Test func theProvisionalPlanIsAPrefixOfTheFinalOne() {
        let busy = [PlanBusy(title: "Lecture", start: Self.at(10), end: Self.at(12)), PlanBusy(title: "Lab", start: Self.at(15), end: Self.at(16))]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6), PlanObligation(title: "HW 4", due: Self.at(23).addingTimeInterval(86400), points: 2)])
        let gaps = DayPlanner.gaps(in: input), ranked = DayPlanner.ranked(input)
        let whole = PlanDraft(blocks: [
            PlanDraftBlock(start: "09:00", end: "09:50", title: "Quiz 3", reason: "Due tonight.", kind: "work"),
            PlanDraftBlock(start: "12:00", end: "12:40", title: "Eat", reason: "Lunch.", kind: "meal"),
            PlanDraftBlock(start: "13:00", end: "13:50", title: "HW 4", reason: "Due tomorrow.", kind: "work"),
            PlanDraftBlock(start: "16:00", end: "16:50", title: "Quiz 3", reason: "Once more.", kind: "work"),
        ])
        let final = DayPlanner.merge(DayPlanner.validate(whole, gaps: gaps, input: input, ranked: ranked), fixed: DayPlanner.fixedOnly(input))
        #expect(final.map(\.title) == ["Quiz 3", "Lecture", "Eat", "HW 4", "Lab", "Quiz 3"])
        for n in 0...whole.blocks.count {   // every prefix of the draft is a prefix of the final timetable, calendar events included
            let sofar = DayPlanner.provisional(PlanDraft(blocks: Array(whole.blocks.prefix(n))), gaps: gaps, input: input, ranked: ranked)
            #expect(sofar.map(\.title) == Array(final.map(\.title).prefix(sofar.count)), "prefix \(n)")
            #expect(sofar.map(\.start) == Array(final.map(\.start).prefix(sofar.count)), "prefix \(n)")
        }
        #expect(DayPlanner.provisional(PlanDraft(blocks: [whole.blocks[0]]), gaps: gaps, input: input, ranked: ranked).map(\.title) == ["Quiz 3"])       // the lecture waits until a block passes it
        #expect(DayPlanner.provisional(PlanDraft(blocks: Array(whole.blocks.prefix(2))), gaps: gaps, input: input, ranked: ranked).map(\.title) == ["Quiz 3", "Lecture", "Eat"])
    }

    @Test func thePlanKnowsWhatIsOnAndWhatIsNext() throws {
        var plan = DayPlan(blocks: [
            PlanBlock(start: Self.at(9), end: Self.at(10), title: "Quiz 3", reason: "", kind: .work),
            PlanBlock(start: Self.at(10), end: Self.at(11), title: "Lecture", reason: "", kind: .fixed),
            PlanBlock(start: Self.at(12), end: Self.at(12, 40), title: "Eat", reason: "", kind: .meal),
        ])
        var f = plan.focus(at: Self.at(9, 30))
        #expect(f.current?.title == "Quiz 3" && f.next?.title == "Lecture")
        f = plan.focus(at: Self.at(11, 30))                                   // between blocks: nothing on, the meal ahead
        #expect(f.current == nil && f.next?.title == "Eat")
        plan.blocks[0].completedAt = Self.at(9, 20)                            // done early: the lecture is next, nothing is on
        f = plan.focus(at: Self.at(9, 30))
        #expect(f.current == nil && f.next?.title == "Lecture" && plan.doneCount == 1)
        f = plan.focus(at: Self.at(13))                                       // the day is over
        #expect(f.current == nil && f.next == nil)
        // A plan saved before blocks could be done still loads, undone.
        let old = #"{"blocks":[{"id":"6D2B0C3E-3B0E-4B2A-9A4C-3E9E1E6B3B01","start":0,"end":3600,"title":"Quiz 3","reason":"","kind":"work"}]}"#
        let loaded = try JSONDecoder().decode(DayPlan.self, from: Data(old.utf8))
        #expect(loaded.blocks[0].isDone == false)
        let round = try JSONDecoder().decode(DayPlan.self, from: JSONEncoder().encode(plan))
        #expect(round.blocks[0].completedAt == Self.at(9, 20))
    }

    @Test func nothingDueAndNothingAskedNeedsNoModel() async {
        let busy = [PlanBusy(title: "Lecture", start: Self.at(10), end: Self.at(12))]
        let plan = await DayPlanner().plan(Self.input(now: Self.at(9), busy: busy))
        #expect(plan.blocks.map(\.title) == ["Lecture"] && plan.route == nil && plan.note?.contains("nothing to plan") == true)
        // After the day's end there is nothing to fill either.
        let late = await DayPlanner().plan(Self.input(now: Self.at(22, 30), obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6)]))
        #expect(late.blocks.isEmpty && late.note == "No free time left today.")
    }

    @Test func theStudentsInstructionsGoIntoThePromptAndAreTrimmed() {
        var input = Self.input(obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6)])
        #expect(input.instructions == nil)
        input = PlanInput(date: input.date, now: input.now, busy: [], obligations: input.obligations, calendar: input.calendar, instructions: "  \n ")
        #expect(input.instructions == nil)                                            // blank is nothing
        input = PlanInput(date: input.date, now: input.now, busy: [], obligations: input.obligations, calendar: input.calendar, instructions: " No work after 9 pm. ")
        let prompt = DayPlanner.prompt(for: input, gaps: DayPlanner.gaps(in: input), ranked: DayPlanner.ranked(input))
        #expect(prompt.contains("The student's own instructions:\nNo work after 9 pm.\nPlan the free gaps."))
        let long = PlanInput(date: input.date, now: input.now, busy: [], obligations: input.obligations, calendar: input.calendar, instructions: String(repeating: "x", count: 2000))
        #expect(DayPlanner.prompt(for: long, gaps: [], ranked: []).count < 1800)      // capped for the on-device context
    }

    @Test func aPlanSavedWithoutAnIdStillLoads() throws {
        let plan = DayPlan(blocks: [PlanBlock(start: Self.at(9), end: Self.at(10), title: "Quiz 3", reason: "Due tonight.", kind: .work)], route: .onDevice, note: nil)
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(DayPlan.self, from: data) == plan)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["id"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(DayPlan.self, from: old)
        #expect(loaded.blocks == plan.blocks && loaded.route == .onDevice)
    }

    @Test func fallbackPlansByTheNumbersWithAMeal() {
        let input = Self.input(now: Self.at(11), obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6), PlanObligation(title: "HW 4", due: Self.at(23).addingTimeInterval(86400), points: 1.5)])
        let gaps = DayPlanner.gaps(in: input)
        let blocks = DayPlanner.fallback(input, gaps: gaps, ranked: DayPlanner.ranked(input))
        #expect(blocks.prefix(3).map(\.title) == ["Quiz 3", "Eat", "HW 4"])
        #expect(blocks[0].reason == "Due today, worth 6% of the grade." && blocks[1].kind == .meal)
    }

    @Test func aCheckpointKeepsFinishedPartsForTheSameRead() throws {
        var checkpoint = IngestCheckpoint(route: .onDevice, textChunks: 3, images: 1)
        #expect(!checkpoint.applies(route: .onDevice, textChunks: 3, images: 1))   // nothing finished yet: nothing to resume
        let facts = ChunkExtraction(course: nil, gradeComponents: [], obligations: [ObligationFacts(title: "HW 1", platform: "not_stated", component: nil, dateAsWritten: "Wed 9/9", dueDate: "2026-09-09", confidence: "high")], policies: [], noClassDates: [])
        let usage = UsageRecord(step: "text", chunk: 0, route: .onDevice, inputTokens: 10, cachedTokens: 0, outputTokens: 5, reasoningTokens: 0, durationMs: 100)
        checkpoint.record(index: 0, outcomes: [ExtractionOutcome(kind: .text, page: 0, extraction: facts, usage: usage)])
        checkpoint.record(index: 1, outcomes: [])                                   // a part the model had nothing for is finished too
        #expect(checkpoint.finishedParts == 2 && checkpoint.totalParts == 4)
        #expect(checkpoint.applies(route: .onDevice, textChunks: 3, images: 1))
        #expect(!checkpoint.applies(route: .claude, textChunks: 3, images: 1))     // another route chunks differently
        #expect(!checkpoint.applies(route: .onDevice, textChunks: 4, images: 1))   // so does another build
        let round = try IngestCheckpoint(data: checkpoint.encoded())
        #expect(round == checkpoint && round.entry(at: 0)?.outcomes.first?.extraction.obligations.first?.title == "HW 1" && round.entry(at: 1)?.outcomes.isEmpty == true && round.entry(at: 2) == nil)
    }
}
