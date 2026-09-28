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

    static func tomorrow(_ h: Int, _ m: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m))! }
    static let essay = PlanObligation(title: "Essay", due: tomorrow(23, 59), points: 10)

    @Test func aLateNightRunsPastMidnight() {
        // Tonight until 2 AM: the free time runs past midnight, and the model's "00:30" is tonight, not this morning.
        var input = Self.input(now: Self.at(21, 30), obligations: [Self.essay])
        input.hours = PlanHours(end: 26)
        #expect(DayPlanner.gaps(in: input) == [DateInterval(start: Self.at(21, 30), end: Self.tomorrow(2))])
        let draft = PlanDraft(blocks: [
            PlanDraftBlock(start: "21:30", end: "22:20", title: "Essay", reason: "Tomorrow.", kind: "work"),
            PlanDraftBlock(start: "23:30", end: "00:20", title: "Essay", reason: "Across midnight.", kind: "work"),
            PlanDraftBlock(start: "00:30", end: "00:50", title: "Break", reason: "A breather.", kind: "rest"),
            PlanDraftBlock(start: "01:00", end: "02:30", title: "Reading", reason: "Past the end: clipped.", kind: "work"),
            PlanDraftBlock(start: "03:00", end: "02:00", title: "Nonsense", reason: "", kind: "work"),   // ends before it starts, even across midnight
        ])
        let blocks = DayPlanner.validate(draft, input: input, ranked: DayPlanner.ranked(input))
        #expect(blocks.map(\.start) == [Self.at(21, 30), Self.at(23, 30), Self.tomorrow(0, 30), Self.tomorrow(1)])
        #expect(blocks.map(\.end) == [Self.at(22, 20), Self.tomorrow(0, 20), Self.tomorrow(0, 50), Self.tomorrow(2)])
        #expect(DayPlanner.prompt(for: input, gaps: DayPlanner.gaps(in: input), ranked: DayPlanner.ranked(input)).contains("the day runs past midnight, until 02:00"))
        // The usual hours stop at 10.
        #expect(DayPlanner.gaps(in: Self.input(now: Self.at(21, 30))) == [DateInterval(start: Self.at(21, 30), end: Self.at(22))])
        // Hours outside what can be chosen are brought inside.
        #expect(PlanHours(start: 3, end: 30) == PlanHours(start: 5, end: 28))
    }

    @Test func theSmallHoursBelongToTheNightBefore() {
        let cal = Self.calendar
        // Up to 4 AM, a moment is the night before's; from 4, its own day's.
        #expect(PlanHours.day(of: Self.tomorrow(1, 30), calendar: cal) == Self.at(0) && PlanHours.day(of: Self.tomorrow(4), calendar: cal) == Self.tomorrow(0))
        // A block's hours: the small hours are tonight's, an end before its start crosses midnight only within six hours.
        #expect(PlanHours.span(from: (23, 30), to: (0, 20), on: Self.at(0), calendar: cal) == DateInterval(start: Self.at(23, 30), end: Self.tomorrow(0, 20)))
        #expect(PlanHours.span(from: (3, 0), to: (4, 0), on: Self.at(0), calendar: cal) == DateInterval(start: Self.tomorrow(3), end: Self.tomorrow(4)))
        #expect(PlanHours.span(from: (14, 0), to: (13, 0), on: Self.at(0), calendar: cal) == nil)
        // A plan is kept through its night, and while a block of it still runs or asks.
        let plan = DayPlan(blocks: [PlanBlock(start: Self.at(21), end: Self.at(22), title: "Essay", reason: "", kind: .work)])
        #expect(plan.kept(for: Self.at(0), calendar: cal) == Self.tomorrow(4))
        let late = DayPlan(blocks: [PlanBlock(start: Self.tomorrow(3, 30), end: Self.tomorrow(4, 30), title: "Essay", reason: "", kind: .work)])
        #expect(late.kept(for: Self.at(0), calendar: cal) == Self.tomorrow(4, 45))
    }

    @Test func afterMidnightTheNightIsStillTheDayItBegan() {
        // 00:30 on the 22nd, in the night of the 21st, which runs until 2 AM: the essay due on the 22nd is tomorrow's.
        var input = Self.input(now: Self.tomorrow(0, 30), obligations: [Self.essay])
        input.hours = PlanHours(end: 26)
        #expect(DayPlanner.gaps(in: input) == [DateInterval(start: Self.tomorrow(0, 30), end: Self.tomorrow(2))])
        let prompt = DayPlanner.prompt(for: input, gaps: DayPlanner.gaps(in: input), ranked: DayPlanner.ranked(input))
        #expect(prompt.contains("It is 00:30 now, after midnight.") && prompt.contains("- 00:30–02:00") && prompt.contains("Essay · tomorrow"))
        let blocks = DayPlanner.validate(PlanDraft(blocks: [PlanDraftBlock(start: "00:30", end: "01:20", title: "Essay", reason: "Tomorrow.", kind: "work")]),
                                         input: input, ranked: DayPlanner.ranked(input))
        #expect(blocks.map(\.start) == [Self.tomorrow(0, 30)] && blocks.map(\.end) == [Self.tomorrow(1, 20)])
    }

    @Test func aStudyEventThatRunsPastMidnightIsFilledPastIt() {
        // The usual hours end at 10, but the student booked the library until 1 AM: its hours are theirs, midnight included.
        let library = PlanBusy(title: "Lock in at library", start: Self.at(21), end: Self.tomorrow(1))
        let input = Self.input(now: Self.at(20), busy: [library], obligations: [Self.essay])
        let draft = PlanDraft(blocks: [PlanDraftBlock(start: "21:00", end: "22:30", title: "Essay", reason: "Tomorrow.", kind: "work"),
                                       PlanDraftBlock(start: "23:45", end: "00:40", title: "Essay", reason: "Finish the draft.", kind: "work")])
        let blocks = DayPlanner.validate(draft, input: input, ranked: DayPlanner.ranked(input), open: [1])
        #expect(blocks.map(\.end) == [Self.at(22, 30), Self.tomorrow(0, 40)] && blocks.allSatisfy { $0.within == "Lock in at library" })
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
        let blocks = DayPlanner.validate(draft, input: input, ranked: DayPlanner.ranked(input))
        #expect(gaps.count == 2)
        #expect(blocks.map(\.title) == ["Quiz 3", "Eat", "Problem set", "Quiz 3"])   // the obligation's own spelling comes back
        #expect(blocks.map { Self.calendar.component(.hour, from: $0.start) } == [9, 12, 13, 14])
        #expect(blocks[1].kind == .meal && blocks[2].start == blocks[1].end)
    }

    @Test func theProvisionalPlanIsAPrefixOfTheFinalOne() {
        let busy = [PlanBusy(title: "Lecture", start: Self.at(10), end: Self.at(12)), PlanBusy(title: "Lab", start: Self.at(15), end: Self.at(16))]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6), PlanObligation(title: "HW 4", due: Self.at(23).addingTimeInterval(86400), points: 2)])
        let ranked = DayPlanner.ranked(input)
        let whole = PlanDraft(blocks: [
            PlanDraftBlock(start: "09:00", end: "09:50", title: "Quiz 3", reason: "Due tonight.", kind: "work"),
            PlanDraftBlock(start: "12:00", end: "12:40", title: "Eat", reason: "Lunch.", kind: "meal"),
            PlanDraftBlock(start: "13:00", end: "13:50", title: "HW 4", reason: "Due tomorrow.", kind: "work"),
            PlanDraftBlock(start: "16:00", end: "16:50", title: "Quiz 3", reason: "Once more.", kind: "work"),
        ])
        let final = DayPlanner.merge(DayPlanner.validate(whole, input: input, ranked: ranked), fixed: DayPlanner.fixedOnly(input))
        #expect(final.map(\.title) == ["Quiz 3", "Lecture", "Eat", "HW 4", "Lab", "Quiz 3"])
        for n in 0...whole.blocks.count {   // every prefix of the draft is a prefix of the final timetable, calendar events included
            let sofar = DayPlanner.provisional(PlanDraft(blocks: Array(whole.blocks.prefix(n))), input: input, ranked: ranked)
            #expect(sofar.map(\.title) == Array(final.map(\.title).prefix(sofar.count)), "prefix \(n)")
            #expect(sofar.map(\.start) == Array(final.map(\.start).prefix(sofar.count)), "prefix \(n)")
        }
        #expect(DayPlanner.provisional(PlanDraft(blocks: [whole.blocks[0]]), input: input, ranked: ranked).map(\.title) == ["Quiz 3"])       // the lecture waits until a block passes it
        #expect(DayPlanner.provisional(PlanDraft(blocks: Array(whole.blocks.prefix(2))), input: input, ranked: ranked).map(\.title) == ["Quiz 3", "Lecture", "Eat"])
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
        plan.blocks[1].skippedAt = Self.at(9, 25)                              // the lecture set aside: the meal is next, and nothing counts it done
        f = plan.focus(at: Self.at(9, 30))
        #expect(f.current == nil && f.next?.title == "Eat" && plan.doneCount == 1)
        #expect(plan.blocks[1].isSkipped && !plan.blocks[1].isOpen && !plan.blocks[1].wasLeftUnfinished)
        #expect(plan.blocks.map(\.asksWhenOver) == [true, false, false])       // only work is worth the question
        // A plan saved before blocks could be done still loads, undone.
        let old = #"{"blocks":[{"id":"6D2B0C3E-3B0E-4B2A-9A4C-3E9E1E6B3B01","start":0,"end":3600,"title":"Quiz 3","reason":"","kind":"work"}]}"#
        let loaded = try JSONDecoder().decode(DayPlan.self, from: Data(old.utf8))
        #expect(loaded.blocks[0].isDone == false && loaded.blocks[0].isOpen)
        let round = try JSONDecoder().decode(DayPlan.self, from: JSONEncoder().encode(plan))
        #expect(round.blocks[0].completedAt == Self.at(9, 20) && round.blocks[1].skippedAt == Self.at(9, 25))
    }

    @Test func aWorkBlockThatEndsAsksFinishedUntilTheQuestionTimesOut() {
        var plan = DayPlan(blocks: [
            PlanBlock(start: Self.at(9), end: Self.at(10), title: "Quiz 3", reason: "", kind: .work),
            PlanBlock(start: Self.at(10), end: Self.at(10, 30), title: "Eat", reason: "", kind: .meal),
            PlanBlock(start: Self.at(10, 30), end: Self.at(11), title: "HW 4", reason: "", kind: .work),
        ])
        #expect(plan.awaitingAnswer(at: Self.at(9, 59)) == nil)                          // still on: nothing to ask yet
        #expect(plan.awaitingAnswer(at: Self.at(10))?.title == "Quiz 3")                // over: finished?
        #expect(plan.awaitingAnswer(at: Self.at(10, 14))?.title == "Quiz 3")
        #expect(plan.awaitingAnswer(at: Self.at(10, 15)) == nil)                         // fifteen minutes unanswered: taken as not finished
        #expect(plan.blocks[0].isOpen && !plan.blocks[0].isDone)                          // and nothing is recorded for it
        #expect(plan.awaitingAnswer(at: Self.at(10, 31)) == nil)                         // a meal asks nothing when it ends
        #expect(DayPlan.answerBy(plan.blocks[0]) == Self.at(10, 15) && DayPlan.answerBy(plan.blocks[1]) == nil)
        plan.blocks[0].completedAt = Self.at(10, 2)                                     // answered: done
        #expect(plan.awaitingAnswer(at: Self.at(10, 5)) == nil)
        plan.blocks[2].skippedAt = Self.at(11, 3)                                        // answered: not finished
        #expect(plan.awaitingAnswer(at: Self.at(11, 5)) == nil && plan.blocks[2].wasLeftUnfinished)
        // Two work blocks ending close together: the later one asks, the earlier is taken as not finished.
        plan.blocks[0].completedAt = nil; plan.blocks[2].skippedAt = nil
        plan.blocks[1].kind = .work
        #expect(plan.awaitingAnswer(at: Self.at(10, 31))?.title == "Eat")
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

    @Test func theModelSeesStudyTimeApartAndPlainDates() {
        let busy = [PlanBusy(title: "Math study session", start: Self.at(14), end: Self.at(16)), PlanBusy(title: "Calc lecture", start: Self.at(10), end: Self.at(11, 50)),
                    PlanBusy(title: "Breakfast", start: Self.at(7), end: Self.at(8))]   // over before now: not shown, not numbered
        let items = [PlanObligation(title: "Test 1", course: "Calculus II", component: "Exams", due: Self.at(23).addingTimeInterval(3 * 86400), points: 20),
                     PlanObligation(title: "HW 4", course: "Calculus II", due: Self.at(23), points: 1.5)]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: items)
        #expect(DayPlanner.events(in: input).map(\.title) == ["Calc lecture", "Math study session"])
        // The calendar step sees every event; the plan step sees them sorted by what the calendar step said.
        #expect(DayPlanner.calendarPrompt(DayPlanner.events(in: input), courses: DayPlanner.courses(of: DayPlanner.ranked(input)), calendar: Self.calendar)
                == "The student's courses: Calculus II.\nCalendar events today:\n- 10:00–11:50 Calc lecture\n- 14:00–16:00 Math study session")
        let prompt = DayPlanner.prompt(for: input, gaps: DayPlanner.gaps(in: input), open: [2], courses: [2: "Calculus II"], ranked: DayPlanner.ranked(input))
        #expect(prompt.contains("Fixed events (hard stops):\n- 10:00–11:50 Calc lecture\nCoursework time on the calendar (fill it with the obligations named for it, within its hours):\n- 14:00–16:00 Math study session: for Calculus II (HW 4, Test 1)\nFree gaps to fill:"))
        #expect(DayPlanner.prompt(for: input, gaps: DayPlanner.gaps(in: input), open: [2], ranked: DayPlanner.ranked(input)).contains("- 14:00–16:00 Math study session: for any obligation"))
        #expect(prompt.contains("- HW 4 (Calculus II) · today · 1.5% of the grade"))
        #expect(prompt.contains("- Test 1 (Calculus II, counts toward Exams) · in 3 days, Thursday · 20% of the grade"))
        #expect(!prompt.contains("due in") && !prompt.contains("Breakfast") && prompt.hasSuffix("Plan the free gaps and the coursework time."))   // a test is not "due"; the model decides what each is
        let plain = DayPlanner.prompt(for: input, gaps: DayPlanner.gaps(in: input), ranked: DayPlanner.ranked(input))
        #expect(plain.contains("Fixed events (hard stops):\n- 10:00–11:50 Calc lecture\n- 14:00–16:00 Math study session\nFree gaps") && plain.hasSuffix("Plan the free gaps."))
    }

    @Test func theCalendarsLabelsAreMatchedByTitleSaidBack() {
        let events = [PlanBusy(title: "Calc lecture", start: Self.at(10), end: Self.at(11)), PlanBusy(title: "Math study session", start: Self.at(14), end: Self.at(16)),
                      PlanBusy(title: "Lock in at library", start: Self.at(19), end: Self.at(21))]
        let aligned = CalendarReading(events: [CalendarEventUse(title: "Calc lecture", use: "fixed", course: "any"), CalendarEventUse(title: "Math study session", use: "coursework", course: "any"), CalendarEventUse(title: "Lock in at library", use: "coursework", course: "any")])
        #expect(DayPlanner.coursework(in: aligned, events: events, courses: []).open == [2, 3])
        // A small model that drops an entry: the titles said back still find the right events.
        let dropped = CalendarReading(events: [CalendarEventUse(title: "lock in at library", use: "coursework", course: "any")])
        #expect(DayPlanner.coursework(in: dropped, events: events, courses: []).open == [3])
        // A title garbled with the count intact falls back on its place; with the count off, it is left a hard stop.
        #expect(DayPlanner.coursework(in: CalendarReading(events: [CalendarEventUse(title: "Calc", use: "fixed", course: "any"), CalendarEventUse(title: "Math study", use: "coursework", course: "any"), CalendarEventUse(title: "Library", use: "fixed", course: "any")]), events: events, courses: []).open == [2])
        #expect(DayPlanner.coursework(in: CalendarReading(events: [CalendarEventUse(title: "Math study", use: "coursework", course: "any")]), events: events, courses: []).open.isEmpty)
        // The course it is for is kept when it is one of the student's; anything else is any course.
        let withCourses = CalendarReading(events: [CalendarEventUse(title: "Calc lecture", use: "fixed", course: "any"), CalendarEventUse(title: "Math study session", use: "coursework", course: "calculus ii"),
                                                   CalendarEventUse(title: "Lock in at library", use: "coursework", course: "Astrophysics")])
        #expect(DayPlanner.coursework(in: withCourses, events: events, courses: ["Calculus II", "Writing"]).courses == [2: "Calculus II"])
    }

    @Test func aStudyEventIsFilledWithinItsHoursAndTheRestStayHardStops() {
        let busy = [PlanBusy(title: "Calc lecture", start: Self.at(10), end: Self.at(11, 50)), PlanBusy(title: "Math study session", start: Self.at(14), end: Self.at(16)),
                    PlanBusy(title: "Lock in at library", start: Self.at(20), end: Self.at(23))]
        let items = [PlanObligation(title: "HW 4", course: "Calculus II", due: Self.at(23), points: 1.5), PlanObligation(title: "Quiz 3", course: "Calculus II", due: Self.at(23).addingTimeInterval(86400), points: 6),
                     PlanObligation(title: "Essay draft", course: "Writing", due: Self.at(23).addingTimeInterval(2 * 86400), points: 10)]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: items)
        let ranked = DayPlanner.ranked(input)
        let draft = PlanDraft(blocks: [
            PlanDraftBlock(start: "10:30", end: "11:00", title: "Reading", reason: "Over the lecture.", kind: "work"),        // the lecture is a hard stop: dropped
            PlanDraftBlock(start: "14:00", end: "14:50", title: "HW 4", reason: "Due tonight.", kind: "work"),               // in the study session
            PlanDraftBlock(start: "15:40", end: "16:30", title: "Quiz 3", reason: "Tomorrow.", kind: "study"),                // past the session's end: stops at 16:00
            PlanDraftBlock(start: "21:00", end: "22:30", title: "Essay draft", reason: "Two days out.", kind: "work"),         // the library, after the usual day: the student chose it
        ])
        let blocks = DayPlanner.validate(draft, input: input, ranked: ranked, open: [2, 3])
        #expect(blocks.map(\.title) == ["HW 4", "Study for Quiz 3", "Essay draft"])
        // The math session is for Calculus II: the essay would not go in it; the library, for any course, takes it.
        let essayInSession = PlanDraft(blocks: [PlanDraftBlock(start: "14:00", end: "14:50", title: "Essay draft", reason: "Two days out.", kind: "work")])
        #expect(DayPlanner.validate(essayInSession, input: input, ranked: ranked, open: [2, 3], courses: [2: "Calculus II"]).isEmpty)
        #expect(DayPlanner.validate(draft, input: input, ranked: ranked, open: [2, 3], courses: [2: "Calculus II"]).map(\.title) == ["HW 4", "Study for Quiz 3", "Essay draft"])
        #expect(blocks.map(\.within) == ["Math study session", "Math study session", "Lock in at library"])
        #expect(blocks[1].end == Self.at(16) && blocks[2].end == Self.at(22, 30) && blocks[1].kind == .study)
        // The timetable: the lecture stays; the two study events are shown by the blocks in them.
        let fixed = DayPlanner.fixedBlocks(input, open: [2, 3], planned: blocks)
        #expect(fixed.map(\.title) == ["Calc lecture"])
        // Not named as study time, the session is a hard stop like any other event, and nothing goes in it.
        let unnamed = DayPlanner.validate(draft, input: input, ranked: ranked)
        #expect(unnamed.isEmpty || unnamed.allSatisfy { $0.within == nil && ($0.end <= Self.at(14) || $0.start >= Self.at(16)) })
        #expect(!unnamed.contains { $0.title == "HW 4" })
        // Named but left empty, it stays on the timetable as it is.
        #expect(DayPlanner.fixedBlocks(input, open: [2], planned: []).map(\.title) == ["Calc lecture", "Math study session", "Lock in at library"])
    }

    @Test func aStudyEventIsCutAtTheHardStopsInsideIt() {
        let busy = [PlanBusy(title: "Library", start: Self.at(13), end: Self.at(17)), PlanBusy(title: "Advisor meeting", start: Self.at(15), end: Self.at(15, 30))]
        let windows = DayPlanner.windows(in: Self.input(now: Self.at(9), busy: busy), open: [1])
        let inLibrary = windows.filter { $0.event == 1 }.map { "\(Self.calendar.component(.hour, from: $0.interval.start)):\(Self.calendar.component(.minute, from: $0.interval.start))" }
        #expect(inLibrary == ["13:0", "15:30"])                                   // the meeting is still a hard stop inside the library time
        #expect(windows.first?.event == nil && windows.first?.interval.start == Self.at(9))   // the free morning is not the library's
    }

    @Test func aTestIsStudiedForNotFinished() {
        let items = [PlanObligation(title: "Test 1", course: "Calculus II", component: "Exams", due: Self.at(23).addingTimeInterval(3 * 86400), points: 20)]
        let input = Self.input(now: Self.at(9), obligations: items)
        let ranked = DayPlanner.ranked(input)
        let draft = PlanDraft(blocks: [
            PlanDraftBlock(start: "09:00", end: "09:50", title: "Test 1", reason: "Go over the practice problems.", kind: "study"),                 // bare: framed
            PlanDraftBlock(start: "10:00", end: "10:50", title: "Review for Test 1 (Calculus II)", reason: "Chapters 3 and 4.", kind: "study"),       // the model's framing stands
            PlanDraftBlock(start: "11:00", end: "11:50", title: "Test 1", reason: "Once more.", kind: "study"),                                        // a third on the same test: dropped
        ])
        let blocks = DayPlanner.validate(draft, input: input, ranked: ranked)
        #expect(blocks.map(\.title) == ["Study for Test 1", "Review for Test 1"] && blocks.allSatisfy { $0.kind == .study && $0.asksWhenOver })
        // What a model writes around the item goes; a short framing of its own stays.
        let item = items[0]
        #expect(DayPlanner.studyTitle("Test 1 (Calculus II, counts toward Exams)", for: item) == "Study for Test 1")
        #expect(DayPlanner.studyTitle("Math study session: Test 1", for: item) == "Study for Test 1")
        #expect(DayPlanner.studyTitle("Math study session: for Calculus II (HW 4, Test 1)", for: item) == "Study for Test 1")
        #expect(DayPlanner.studyTitle("review for test 1", for: item) == "Review for Test 1" && DayPlanner.studyTitle("Practise Test 1", for: item) == "Practise Test 1")
        // A reason that speaks of a deadline is replaced by the facts: a test is not due.
        let due = DayPlanner.validate(PlanDraft(blocks: [PlanDraftBlock(start: "09:00", end: "09:50", title: "Test 1", reason: "Nearest obligation due in 3 days.", kind: "study")]), input: input, ranked: ranked)
        #expect(due.first?.reason == "In 3 days (Thursday), worth 20% of the grade: time to review for it.")
        #expect(DayPlanner.validate(PlanDraft(blocks: [PlanDraftBlock(start: "09:00", end: "09:50", title: "Test 1", reason: "Go over chapter 3.", kind: "study")]), input: input, ranked: ranked).first?.reason == "Go over chapter 3.")
        // Without a model, the plan by the numbers guesses from the title or the grade row, and never says "due".
        let fallback = DayPlanner.fallback(input, gaps: DayPlanner.gaps(in: input), ranked: ranked)
        #expect(fallback.first?.title == "Study for Test 1" && fallback.first?.kind == .study && fallback.first?.reason == "In 3 days, worth 20% of the grade.")
        #expect(DayPlanner.looksHeld(PlanObligation(title: "Midterm 2", due: Self.at(23))) && !DayPlanner.looksHeld(PlanObligation(title: "Lab report", component: "Labs", due: Self.at(23))))
        #expect(!DayPlanner.looksHeld(PlanObligation(title: "Quiz 3", due: Self.at(23))))   // a quiz may be online and due: without a model, it stays work
    }

    @Test func aBlockTitledWithTheEventsNameTakesTheItemItsReasonNames() {
        let busy = [PlanBusy(title: "Math study session", start: Self.at(14), end: Self.at(17))]
        let items = [PlanObligation(title: "HW 4", course: "Calculus II", due: Self.at(23), points: 1.5), PlanObligation(title: "Test 1", course: "Calculus II", component: "Exams", due: Self.at(23).addingTimeInterval(3 * 86400), points: 20)]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: items)
        let draft = PlanDraft(blocks: [
            PlanDraftBlock(start: "14:00", end: "15:00", title: "Math study session", reason: "Test 1 is Thursday, worth 20%: practise the integration problems.", kind: "study"),
            PlanDraftBlock(start: "15:00", end: "15:50", title: "Math study session", reason: "Finish HW4 problems before tomorrow's deadline.", kind: "work"),
            PlanDraftBlock(start: "16:00", end: "16:50", title: "Math study session", reason: "More time for math.", kind: "work"),   // names nothing
        ])
        let blocks = DayPlanner.validate(draft, input: input, ranked: DayPlanner.ranked(input), open: [1])
        #expect(blocks.map(\.title) == ["Study for Test 1", "HW 4", "HW 4"])   // the third names nothing: the nearest work that fits the session
        // The prompt's whole line said back is an echo too; with nothing left that fits, it is the event's time, named plainly.
        let line = PlanDraft(blocks: [PlanDraftBlock(start: "14:00", end: "14:50", title: "Math study session: for Calculus II (HW 4, Test 1)", reason: "Flexible time.", kind: "work")])
        #expect(DayPlanner.validate(line, input: input, ranked: DayPlanner.ranked(input), open: [1], courses: [1: "Calculus II"]).first?.title == "HW 4")
        #expect(DayPlanner.validate(line, input: input, ranked: [], open: [1]).first?.title == "Math study session")
        #expect(DayPlanner.item(mentionedIn: "Start HW 10 tonight.", ranked: [PlanObligation(title: "HW 1", due: Self.at(23)), PlanObligation(title: "HW 10", due: Self.at(23))])?.title == "HW 10")   // not HW 1
    }

    @Test func aMealOnTheCalendarIsTheMeal() {
        let busy = [PlanBusy(title: "Lunch with Sam", start: Self.at(12), end: Self.at(13))]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: [PlanObligation(title: "HW 4", due: Self.at(23))])
        let draft = PlanDraft(blocks: [
            PlanDraftBlock(start: "13:00", end: "13:40", title: "Lunch", reason: "No meal yet.", kind: "meal"),       // right after lunch with Sam: dropped
            PlanDraftBlock(start: "18:00", end: "18:40", title: "Dinner", reason: "Evening meal.", kind: "meal"),     // hours later: kept
        ])
        #expect(DayPlanner.validate(draft, input: input, ranked: DayPlanner.ranked(input)).map(\.title) == ["Dinner"])
        #expect(DayPlanner.isMeal("Lunch with Sam") && !DayPlanner.isMeal("Lunchtime seminar"))
    }

    @Test func aDayFullOfEventsStillAsksTheModelAboutThem() async {
        // No free time at all, but one event may be study time: only the model can say, so the plan is not cut short.
        let busy = [PlanBusy(title: "Lock in at library", start: Self.at(8), end: Self.at(22))]
        let input = Self.input(now: Self.at(9), busy: busy, obligations: [PlanObligation(title: "Quiz 3", due: Self.at(23), points: 6)])
        #expect(DayPlanner.gaps(in: input).isEmpty && DayPlanner.events(in: input).count == 1)
        let windows = DayPlanner.windows(in: input, open: [1])
        #expect(windows.count == 1 && windows[0].event == 1 && windows[0].interval == DateInterval(start: Self.at(9), end: Self.at(22)))   // from now to the library's end
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
