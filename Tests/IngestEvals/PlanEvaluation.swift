import Foundation
import Testing
@testable import IngestKit

// The day plan against a real model: a day with a lecture, lunch with a friend, a math study session, a lab and an
// evening at the library, and a week of coursework with a test in it. What the planner must do with it:
//   - the study session and the library are time to fill, and the lecture, the lunch and the lab are not;
//   - what goes in the math study session is math;
//   - the test is studied for: its blocks are kind study and never say it is due or to be finished.
// Slow (model calls), so it only runs when HORIZON_EVALS is set, like the ingest evals:
//   HORIZON_EVALS=1 swift test --filter PlanEvals                        # Claude (the key as for the ingest evals)
//   HORIZON_EVALS=1 HORIZON_ON_DEVICE=1 swift test --filter PlanEvals    # the device model
// The plan is printed; the checks are recorded as issues.

@Suite(.enabled(if: ProcessInfo.processInfo.environment["HORIZON_EVALS"] != nil, "set HORIZON_EVALS=1 to run model evals"))
struct PlanEvals {
    static let calendar = Calendar.current
    static func at(_ h: Int, _ m: Int = 0, plusDays d: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 21 + d, hour: h, minute: m))!
    }

    static let events = [
        PlanBusy(title: "MA-UY 1124 Lecture", start: at(10), end: at(11, 15)),
        PlanBusy(title: "Lunch with Sam", start: at(12), end: at(13)),
        PlanBusy(title: "Math study session", start: at(14), end: at(16)),
        PlanBusy(title: "Chem lab", start: at(16, 30), end: at(17, 30)),
        PlanBusy(title: "Lock in at library", start: at(19), end: at(21, 30)),
    ]
    static let items = [
        PlanObligation(title: "HW 4", course: "Calculus II", component: "Homework", due: at(23, 59, plusDays: 1), points: 1.5),
        PlanObligation(title: "Test 1", course: "Calculus II", component: "Exams", due: at(9, plusDays: 3), points: 20),
        PlanObligation(title: "Essay draft", course: "Writing Seminar", component: "Essays", due: at(23, 59, plusDays: 2), points: 10),
        PlanObligation(title: "Quiz 2", course: "General Chemistry", component: "Quizzes", due: at(23, 59, plusDays: 1), points: 5),
        PlanObligation(title: "Lab report 3", course: "General Chemistry", component: "Labs", due: at(23, 59, plusDays: 4), points: 4),
    ]

    /// The calendar step alone (seconds, not a whole plan): the math session is coursework for Calculus II, the library
    /// is coursework for any course, and the lecture, the lunch and the lab are fixed.
    @Test func calendarReading() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = PlanInput(date: Self.at(0), now: Self.at(9), busy: Self.events, obligations: Self.items, calendar: Self.calendar)
        let planner = DayPlanner(log: { print("  \($0)") })
        let claude = env["HORIZON_ON_DEVICE"] != nil ? nil : ClaudeKey.find().map { ClaudeConfiguration(apiKey: $0) }
        let time = await planner.readCalendar(DayPlanner.events(in: input), input: input, ranked: DayPlanner.ranked(input), route: claude == nil ? .onDevice : .claude, claude: claude)
        #expect(time.open == [3, 5], "the math session and the library are coursework time")
        #expect(time.courses[3] == "Calculus II" && time.courses[5] == nil, "the math session is for Calculus II, the library for any course")
    }

    /// The plan on the route the environment asks for (Claude unless HORIZON_ON_DEVICE), printed; nil without a key.
    static func plan(_ input: PlanInput, title: String) async -> DayPlan? {
        let env = ProcessInfo.processInfo.environment
        let planner = DayPlanner(log: { print("  \($0)") })
        let plan: DayPlan
        if env["HORIZON_ON_DEVICE"] != nil {
            plan = await planner.plan(input, route: .onDevice)
        } else {
            guard let key = ClaudeKey.find() else { Issue.record("no Claude key: set ANTHROPIC_API_KEY or write claude_api_key.secret, or set HORIZON_ON_DEVICE=1"); return nil }
            let model = env["HORIZON_CLAUDE_MODEL"].flatMap { name in ClaudeModelChoice.allCases.first { "\($0)" == name } } ?? .default
            plan = await planner.plan(input, route: .claude, claude: ClaudeConfiguration(apiKey: key, model: model))
        }
        let clock = Date.FormatStyle().month(.abbreviated).day().hour(.twoDigits(amPM: .abbreviated)).minute()
        print("\n# \(title) — route \(plan.route.map { "\($0)" } ?? "by the numbers")\(plan.note.map { ", note: \($0)" } ?? "")")
        for b in plan.blocks {
            print("  \(b.start.formatted(clock))–\(b.end.formatted(clock))  \(b.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  \(b.title)\(b.within.map { "  [in \($0)]" } ?? "")  — \(b.reason)")
        }
        return plan
    }

    @Test func studyEventsAndTests() async throws {
        let input = PlanInput(date: Self.at(0), now: Self.at(9), busy: Self.events, obligations: Self.items, calendar: Self.calendar)
        guard let plan = await Self.plan(input, title: "Plan eval") else { return }
        #expect(plan.route != nil, "the model planned (not the fallback)")

        // The hard stops are on the timetable as they are, and nothing overlaps them.
        let hard = Self.events.filter { ["MA-UY 1124 Lecture", "Lunch with Sam", "Chem lab"].contains($0.title) }
        for event in hard {
            #expect(plan.blocks.contains { $0.kind == .fixed && $0.title == event.title }, "\(event.title) is still on the timetable")
            #expect(!plan.blocks.contains { $0.kind != .fixed && $0.start < event.end && $0.end > event.start }, "nothing is planned over \(event.title)")
        }
        // The study events are filled, and the math session with math.
        let inSession = plan.blocks.filter { $0.within == "Math study session" }
        #expect(!inSession.isEmpty, "the math study session is used")
        #expect(inSession.filter { $0.kind == .work || $0.kind == .study }.allSatisfy { $0.title.contains("HW 4") || $0.title.contains("Test 1") }, "only Calculus II in the math session")
        #expect(plan.blocks.contains { $0.within == "Lock in at library" }, "the library time is used")
        // The test is studied for.
        let test = plan.blocks.filter { $0.title.contains("Test 1") }
        #expect(!test.isEmpty, "the test gets time")
        for b in test {
            #expect(b.kind == .study && b.title != "Test 1", "\(b.title) is study, framed as such")
            let reason = b.reason.lowercased()
            #expect(!["due", "finish", "submit", "hand in", "complete "].contains { reason.contains($0) }, "the reason for \(b.title) does not say it is due or to be finished: \(b.reason)")
        }
        // Homework is still work.
        #expect(plan.blocks.filter { $0.title == "HW 4" }.allSatisfy { $0.kind == .work }, "HW 4 is work")
    }

    /// A late night: dinner at 20:30, then work until 2 AM. The model plans past midnight, its "00:30" lands tonight,
    /// nothing runs past 2, and dinner stays put.
    @Test func aLateNight() async throws {
        let dinner = PlanBusy(title: "Dinner with Sam", start: Self.at(20, 30), end: Self.at(21, 30))
        let input = PlanInput(date: Self.at(0), now: Self.at(20), busy: [dinner], obligations: Self.items, calendar: Self.calendar, hours: PlanHours(end: 26))
        guard let plan = await Self.plan(input, title: "Late night") else { return }
        #expect(plan.route != nil, "the model planned (not the fallback)")
        let midnight = Self.at(0, plusDays: 1), close = Self.at(2, plusDays: 1)
        #expect(plan.blocks.contains { $0.kind != .fixed && $0.start >= midnight }, "the night past midnight is used")
        #expect(plan.blocks.allSatisfy { $0.end <= close }, "nothing after 2 AM")
        #expect(zip(plan.blocks, plan.blocks.dropFirst()).allSatisfy { $0.end <= $1.start || $1.kind == .fixed || $0.kind == .fixed }, "in order, without overlaps")
        #expect(!plan.blocks.contains { $0.kind != .fixed && $0.start < dinner.end && $0.end > dinner.start }, "nothing over dinner")
    }
}
