import Foundation
import FoundationModels

// SPEC §6.3 "Now": one button, a disposable plan for today. The calendar's events are hard stops, except those the model
// reads as coursework time, which the student set aside for their courses (a study session, library time) and which it
// may fill with work of their kind without crossing their edges; the free time is filled with what matters most first,
// with a reason on every block. The model proposes; the planner keeps it inside the free time and the coursework time,
// and falls back to a deterministic plan when the model is unavailable or unusable.

public struct PlanBusy: Sendable, Equatable, Codable {
    public var title: String
    public var start: Date
    public var end: Date
    public init(title: String, start: Date, end: Date) { self.title = title; self.start = start; self.end = end }
}

public struct PlanObligation: Sendable, Equatable, Codable {
    public var title: String
    public var course: String?
    /// The grade breakdown row it counts toward ("Exams", "Homework"), when the document says: a hint to the model about
    /// what kind of item it is (one to hand in, or one that happens at a set time and is studied for).
    public var component: String?
    public var due: Date
    public var points: Double?
    public var notes: String?
    public init(title: String, course: String? = nil, component: String? = nil, due: Date, points: Double? = nil, notes: String? = nil) {
        self.title = title; self.course = course; self.component = component; self.due = due; self.points = points; self.notes = notes
    }
}

/// The part of a day the planner fills: from `start` to `end`, in hours after the midnight that begins the day. An end
/// past 24 is that night, after midnight (26 is 2 AM): a late night belongs to the day it began, and so does its plan.
public struct PlanHours: Sendable, Equatable, Codable {
    public var start: Int
    public var end: Int
    public init(start: Int = 8, end: Int = 22) {
        self.start = min(max(start, Self.starts.lowerBound), Self.starts.upperBound)
        self.end = min(max(end, Self.ends.lowerBound), Self.ends.upperBound)
    }
    /// What the student may choose, in whole hours: a start from 5 AM to noon, an end from 6 PM to 4 AM.
    public static let starts = 5...12
    public static let ends = 18...28

    /// `hour` of `day` as a moment: hours after the midnight that begins the day, past 24 for the night after.
    public static func moment(_ hour: Int, on day: Date, calendar: Calendar) -> Date? {
        let midnight = calendar.startOfDay(for: day)
        guard let base = hour >= 24 ? calendar.date(byAdding: .day, value: 1, to: midnight) : midnight else { return nil }
        return calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: base)
    }
    public func opens(on day: Date, calendar: Calendar) -> Date? { Self.moment(start, on: day, calendar: calendar) }
    public func closes(on day: Date, calendar: Calendar) -> Date? { Self.moment(end, on: day, calendar: calendar) }

    /// The hour before which a moment belongs to the night before: the latest end a night can have (4 AM).
    public static let nightEnds = ends.upperBound - 24

    /// The day a moment belongs to: its own date, except the small hours (before 4 AM), which are the night before's.
    public static func day(of moment: Date, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: moment)
        guard calendar.component(.hour, from: moment) < nightEnds, let before = calendar.date(byAdding: .day, value: -1, to: midnight) else { return midnight }
        return before
    }

    /// A block's hours on `day`'s plan, from times of day: the small hours are the night after (the next date), the rest
    /// the day's own; an end at or before its start is the next day's when that is within six hours (a block across
    /// midnight). Nil for one that still ends before it starts. The hour the clocks go back through comes twice (1 AM on
    /// the first Sunday of November): a time of it already gone by `now` the first time round is the second.
    public static func span(from start: (hour: Int, minute: Int), to end: (hour: Int, minute: Int), on day: Date, calendar: Calendar, now: Date? = nil) -> DateInterval? {
        let midnight = calendar.startOfDay(for: day)
        func place(_ t: (hour: Int, minute: Int)) -> Date? {
            guard let base = t.hour < nightEnds ? calendar.date(byAdding: .day, value: 1, to: midnight) : midnight,
                  let first = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: base) else { return nil }
            if let now, first < now,
               let second = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: base, matchingPolicy: .nextTime, repeatedTimePolicy: .last, direction: .forward),
               second > first { return second }
            return first
        }
        guard let from = place(start), var to = place(end) else { return nil }
        if to <= from, let next = calendar.date(byAdding: .day, value: 1, to: to), next.timeIntervalSince(from) <= 6 * 3600 { to = next }
        return to > from ? DateInterval(start: from, end: to) : nil
    }
}

public struct PlanInput: Sendable {
    /// The day the plan is for. After midnight, in a night that runs past it, still the day the night began.
    public var date: Date
    public var now: Date
    public var busy: [PlanBusy]
    public var obligations: [PlanObligation]
    public var calendar: Calendar
    /// The part of the day the plan may use: the student's usual hours, or tonight's end.
    public var hours: PlanHours
    /// The student's own instructions, in their words: standing rules or today's. They outrank the planner's habits
    /// but not the fixed events, and they need the model (the plan by the numbers cannot read them).
    public var instructions: String?
    public init(date: Date, now: Date, busy: [PlanBusy], obligations: [PlanObligation], calendar: Calendar = .current, hours: PlanHours = PlanHours(), instructions: String? = nil) {
        self.date = date; self.now = now; self.busy = busy; self.obligations = obligations; self.calendar = calendar; self.hours = hours
        self.instructions = instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct PlanBlock: Sendable, Equatable, Identifiable, Codable {
    /// `work` is something to hand in; `study` is preparing for something that happens at a set time (a test, an exam),
    /// which cannot be finished ahead; `fixed` is a calendar event.
    public enum Kind: String, Sendable, Codable, CaseIterable { case work, study, meal, rest, fixed }
    public var id = UUID()
    public var start: Date
    public var end: Date
    public var title: String
    public var reason: String
    public var kind: Kind
    /// The calendar event this block sits in: time the student set aside to study ("Math study session"), which the
    /// planner filled with work of its kind. Nil for a block in free time.
    public var within: String?
    /// When the user marked it done, in the app or from the Live Activity. Nil while it is still to do.
    public var completedAt: Date?
    /// When the user set it aside: skipped ahead of time or while it was on, or answered "not finished" once it was
    /// over. The plan organises the day and holds nobody to it, so a block can be left without being called done.
    public var skippedAt: Date?
    public var isDone: Bool { completedAt != nil }
    public var isSkipped: Bool { skippedAt != nil }
    /// Neither done nor set aside: the day still has it.
    public var isOpen: Bool { completedAt == nil && skippedAt == nil }
    /// Set aside only once it was over: the answer to "finished?" was no. Before that it was skipped.
    public var wasLeftUnfinished: Bool { skippedAt.map { $0 >= end } ?? false }
    /// Whether the end of the block is worth a question (did you finish?): work and study are; a meal, a rest and a
    /// calendar event simply end.
    public var asksWhenOver: Bool { kind == .work || kind == .study }
    public init(start: Date, end: Date, title: String, reason: String, kind: Kind, within: String? = nil, completedAt: Date? = nil, skippedAt: Date? = nil) {
        self.start = start; self.end = end; self.title = title; self.reason = reason; self.kind = kind; self.within = within
        self.completedAt = completedAt; self.skippedAt = skippedAt
    }
}

public struct DayPlan: Sendable, Equatable, Codable, Identifiable {
    public var id = UUID()
    public var blocks: [PlanBlock]
    /// Nil when the deterministic planner made it.
    public var route: ModelRoute?
    public var usage: UsageRecord?
    public var note: String?
    public init(blocks: [PlanBlock], route: ModelRoute? = nil, usage: UsageRecord? = nil, note: String? = nil) {
        self.blocks = blocks; self.route = route; self.usage = usage; self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, blocks, route, usage, note }
    public init(from decoder: any Decoder) throws {   // a plan saved before `id` existed still loads
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        blocks = try c.decode([PlanBlock].self, forKey: .blocks)
        route = try c.decodeIfPresent(ModelRoute.self, forKey: .route)
        usage = try c.decodeIfPresent(UsageRecord.self, forKey: .usage)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// What the day is at `now`: the block that is on and still open, and the first open block after it (the first one
    /// ahead when nothing is on). Blocks done, set aside or already over are neither.
    public func focus(at now: Date) -> (current: PlanBlock?, next: PlanBlock?) {
        let pending = blocks.filter { $0.isOpen && $0.end > now }.sorted { $0.start < $1.start }
        let current = pending.first { $0.start <= now }
        let next = pending.first { $0.start > now && $0.id != current?.id }
        return (current, next)
    }
    /// The day's work as "x of y done" counts it: work and study blocks, not meals, rests or the calendar's events
    /// (with those in the total, "All done" waited on a lunch nobody marks).
    public var workBlocks: [PlanBlock] { blocks.filter(\.asksWhenOver) }
    public var doneCount: Int { workBlocks.filter(\.isDone).count }

    /// Until when the plan for `day` is kept: through its night (to the latest end a night can have, 4 AM), and while a
    /// block of it is still on or asking. Then it goes, and the next plan starts from nothing.
    public func kept(for day: Date, calendar: Calendar) -> Date {
        let night = PlanHours.moment(PlanHours.ends.upperBound, on: day, calendar: calendar) ?? day.addingTimeInterval(28 * 3600)
        return ([night] + blocks.map { $0.end.addingTimeInterval(Self.answerWindow) }).max() ?? night
    }

    /// How long the question at the end of a work or study block ("finished?") stands. Unanswered by then, the block is taken as
    /// not finished: nothing is recorded (not done is where every block starts), and the question goes.
    public static let answerWindow: TimeInterval = 15 * 60

    /// When the question at the end of `block` stops standing; nil for a block that asks none.
    public static func answerBy(_ block: PlanBlock) -> Date? {
        block.asksWhenOver ? block.end.addingTimeInterval(answerWindow) : nil
    }

    /// The block whose end is asking "finished?" at `now`: a work or study block that is over, neither done nor set aside, its
    /// question not yet timed out. When two ended close together, the later one: the earlier is taken as not finished.
    public func awaitingAnswer(at now: Date) -> PlanBlock? {
        blocks.filter { block in
            guard block.isOpen, block.end <= now, let by = Self.answerBy(block) else { return false }
            return now < by
        }.max { $0.end < $1.end }
    }
}

@Generable
struct PlanDraft {
    @Guide(description: "Ordered blocks for the free gaps and the coursework time only, 25 to 90 minutes each", .maximumCount(14))
    var blocks: [PlanDraftBlock]
}

/// The calendar read before the plan: which events are time the student set aside for coursework. A step of its own, so
/// that a small model gets it right: one label per event, with the event's title said back to keep them aligned.
@Generable
struct CalendarReading {
    @Guide(description: "One entry per calendar event, in the order given")
    var events: [CalendarEventUse]
}

@Generable
struct CalendarEventUse {
    @Guide(description: "The event's title as given")
    var title: String
    @Guide(.anyOf(["coursework", "fixed"]))
    var use: String
    @Guide(description: "For coursework time, the course it is for, as named in the list, or any; for a fixed event, any")
    var course: String
}

/// What the calendar step read: the events that are coursework time (their numbers, from 1), and the course each is
/// for when it is for one (a math study session is for Calculus II; library time is for any course).
struct CourseworkTime: Sendable, Equatable {
    var open: Set<Int> = []
    var courses: [Int: String] = [:]
}

@Generable
struct PlanDraftBlock {
    @Guide(description: "Start time, 24-hour HH:mm")
    var start: String
    @Guide(description: "End time, 24-hour HH:mm")
    var end: String
    @Guide(description: "The obligation's title as given, or what the block is for; never an event's name")
    var title: String
    @Guide(description: "One sentence: why this, why now")
    var reason: String
    @Guide(.anyOf(["work", "study", "meal", "rest"]))
    var kind: String
}

public actor DayPlanner {
    public static let instructions = """
    You plan one student's day. Fixed events are hard stops: never place anything over them. Coursework time on the \
    calendar is time the student set aside for their courses: fill it with obligations of the kind it is for (a math \
    study session gets math), never starting before it or ending after it. Fill the free gaps and the coursework time, \
    in order, with the obligations that matter most first: the nearest dates, weighted by points at stake. Blocks are 25 \
    to 90 minutes; leave short rests between long stretches. If the day has no meal yet, the first block after 11:30 or \
    after 17:30 is a meal. Use the obligations' titles exactly as given; never title a block with an event's name. \
    A test, exam, midterm, in-class quiz or presentation happens at a set time and cannot be finished ahead: a block for \
    one has kind study, for preparing, and its reason says what to review or practise, never that it is due. Blocks for \
    anything handed in or done have kind work, wherever they sit. Every block has a one-sentence reason that names the \
    date or the need. \
    The student's own instructions, when given, outrank the habits above: follow them, except that fixed events stay \
    hard stops and coursework time keeps its hours.
    """

    /// The calendar step's instructions: coursework time is the student's own time for their courses; everything else stays put.
    public static let calendarInstructions = """
    You read one student's calendar for today. For each event, in order, give its use and its course. \
    Use coursework for time the student set aside to work on their courses, alone or with classmates: a study session, \
    a study group, homework time, time at the library, "lock in". Use fixed for everything else: a class, lecture, lab, \
    section, office hours, exam, meeting, appointment, shift, meal, workout, or plans with people. \
    Course: when the event names a subject (a math study session, chem review), the course of that subject, named as \
    in the list; otherwise any (time at the library or "lock in" is for any course, and so is every fixed event).
    """

    private let log: @Sendable (String) -> Void
    private let transport: ClaudeTransport
    public init(log: @escaping @Sendable (String) -> Void = { _ in }, transport: ClaudeTransport = .live) { self.log = log; self.transport = transport }

    /// Free time around every calendar event, inside the day, from now on, at least 25 minutes long: what the model is
    /// told is free, and all the plan by the numbers may use.
    public static func gaps(in input: PlanInput) -> [DateInterval] {
        guard let day = dayWindow(input) else { return [] }
        return subtract([day], input.busy.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }).filter { $0.duration >= 25 * 60 }
    }

    /// The part of the day the plan may use by habit: from the day's start (or now) to its end, past midnight when the
    /// student works late.
    static func dayWindow(_ input: PlanInput) -> DateInterval? {
        guard let open = input.hours.opens(on: input.date, calendar: input.calendar), let close = input.hours.closes(on: input.date, calendar: input.calendar) else { return nil }
        let start = max(open, input.now)
        return start < close ? DateInterval(start: start, end: close) : nil
    }

    /// The calendar's events still to come today, in time order: what the calendar step labels, and the numbering (from
    /// 1) that coursework time is known by.
    public static func events(in input: PlanInput) -> [PlanBusy] {
        input.busy.filter { $0.end > input.now && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// Where blocks may go once the model has said which events are coursework time (`open`, their numbers): the day's
    /// free time with only the other events as hard stops, and each coursework event whole (the student chose its hours,
    /// even outside the day's), cut at every coursework event's edges so that no block crosses one. A window inside a
    /// coursework event carries its number.
    struct Window: Equatable { var interval: DateInterval; var event: Int? }

    static func windows(in input: PlanInput, open: Set<Int>) -> [Window] {
        let events = Self.events(in: input)
        let study = events.indices.filter { open.contains($0 + 1) }
        let hard = events.indices.filter { !study.contains($0) }.map { DateInterval(start: events[$0].start, end: events[$0].end) }
        var base = dayWindow(input).map { [$0] } ?? []
        for i in study where events[i].end > input.now { base.append(DateInterval(start: max(events[i].start, input.now), end: events[i].end)) }
        let free = subtract(union(base), hard)
        let edges = Set(study.flatMap { [events[$0].start, events[$0].end] })
        var windows: [Window] = []
        for piece in free {
            var start = piece.start
            for edge in edges.filter({ $0 > piece.start && $0 < piece.end }).sorted() + [piece.end] {
                let middle = start.addingTimeInterval(edge.timeIntervalSince(start) / 2)
                let event = study.first { events[$0].start <= middle && middle < events[$0].end }
                windows.append(Window(interval: DateInterval(start: start, end: edge), event: event.map { $0 + 1 }))
                start = edge
            }
        }
        return windows.filter { $0.interval.duration >= 15 * 60 }
    }

    /// Overlapping or touching intervals joined, in order.
    static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var joined: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = joined.last, interval.start <= last.end {
                joined[joined.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                joined.append(interval)
            }
        }
        return joined
    }

    /// What is left of `intervals` once `holes` are taken out.
    static func subtract(_ intervals: [DateInterval], _ holes: [DateInterval]) -> [DateInterval] {
        var pieces = union(intervals)
        for hole in union(holes) {
            pieces = pieces.flatMap { piece -> [DateInterval] in
                guard hole.start < piece.end, hole.end > piece.start else { return [piece] }
                var rest: [DateInterval] = []
                if hole.start > piece.start { rest.append(DateInterval(start: piece.start, end: hole.start)) }
                if hole.end < piece.end { rest.append(DateInterval(start: hole.end, end: piece.end)) }
                return rest
            }
        }
        return pieces
    }

    /// Obligations worth planning for: due from today on, nearest first, heavier first on the same day.
    public static func ranked(_ input: PlanInput) -> [PlanObligation] {
        let day = input.calendar.startOfDay(for: input.date)
        return input.obligations.filter { $0.due >= day }.sorted { a, b in
            let da = input.calendar.startOfDay(for: a.due), db = input.calendar.startOfDay(for: b.due)
            return da != db ? da < db : (a.points ?? 0) > (b.points ?? 0)
        }
    }

    /// `progress` is told the plan so far as the model writes it: the blocks that are complete, validated and in time
    /// order, with the calendar's events up to the last of them, so a timetable can grow block by block.
    /// A small task, so the device model plans by default; Claude when asked for (`route: .claude` with `claude`), and
    /// when the device has no model and Claude is configured.
    public func plan(_ input: PlanInput, route: IngestOptions.RoutePolicy = .onDevice, claude: ClaudeConfiguration? = nil,
                     progress: @escaping @Sendable ([PlanBlock]) -> Void = { _ in }) async -> DayPlan {
        let gaps = Self.gaps(in: input)
        let ranked = Array(Self.ranked(input).prefix(12))
        let events = Self.events(in: input)
        let noTime = DayPlan(blocks: Self.fixedOnly(input), route: nil, usage: nil, note: "No free time left today.")
        guard !gaps.isEmpty || !events.isEmpty else { return noTime }   // an event left may be time to study: the model says
        guard !ranked.isEmpty || input.instructions != nil else {   // nothing due and nothing asked: the calendar is the plan
            return DayPlan(blocks: Self.fixedOnly(input), route: nil, usage: nil, note: "Nothing is due in the coming weeks, so there is nothing to plan.")
        }
        let coursework = events.isEmpty ? CourseworkTime() : await readCalendar(events, input: input, ranked: ranked, route: route, claude: claude)
        let open = coursework.open
        guard !gaps.isEmpty || !open.isEmpty else { return noTime }
        let prompt = Self.prompt(for: input, gaps: gaps, open: open, courses: coursework.courses, ranked: ranked)
        let started = ContinuousClock.now
        let report = Reporter { draft in progress(Self.provisional(draft, input: input, ranked: ranked, open: open, courses: coursework.courses)) }
        do {
            let (draft, usage, used) = try await respond(prompt, route: route, claude: claude, report: report)
            let blocks = Self.validate(draft, input: input, ranked: ranked, open: open, courses: coursework.courses)
            let record = UsageRecord(step: "plan", chunk: 0, route: used, inputTokens: usage.input, cachedTokens: usage.cached,
                                     outputTokens: usage.output, reasoningTokens: usage.reasoning,
                                     durationMs: Int((ContinuousClock.now - started) / .milliseconds(1)))
            log("plan: \(draft.blocks.count) proposed, \(blocks.count) kept, in \(record.inputTokens) out \(record.outputTokens) \(record.durationMs)ms")
            if blocks.isEmpty {
                let unread = input.instructions == nil ? "" : " Your instructions were not followed."
                return DayPlan(blocks: Self.fallback(input, gaps: gaps, ranked: ranked), route: nil, usage: record, note: "The model's plan did not fit the day; this one is by the numbers." + unread)
            }
            return DayPlan(blocks: Self.merge(blocks, fixed: Self.fixedBlocks(input, open: open, planned: blocks)), route: used, usage: record, note: nil)
        } catch {
            log("plan: model unavailable (\(error.localizedDescription)); planning by the numbers")
            let unread = input.instructions == nil ? "" : " Your instructions need the model."
            return DayPlan(blocks: Self.fallback(input, gaps: gaps, ranked: ranked), route: nil, usage: nil, note: "Planned by the numbers; the model was not available." + unread)
        }
    }

    /// The plan so far, for a timetable that grows: the complete blocks validated as the whole draft will be (validation
    /// walks the draft in order, so a prefix of the draft validates to a prefix of the result), and the calendar's
    /// events up to the last of them, so the rail only ever extends downward. A retried reply starts over.
    static func provisional(_ draft: PlanDraft, input: PlanInput, ranked: [PlanObligation], open: Set<Int> = [], courses: [Int: String] = [:]) -> [PlanBlock] {
        let blocks = validate(draft, input: input, ranked: ranked, open: open, courses: courses)
        guard let last = blocks.last else { return [] }
        return merge(blocks, fixed: fixedBlocks(input, open: open, planned: blocks).filter { $0.start < last.end })
    }

    /// Tells the caller about a draft only when a block has completed since the last time.
    private final class Reporter: @unchecked Sendable {
        private let sink: @Sendable (PlanDraft) -> Void
        private var reported = 0
        private let lock = NSLock()
        init(_ sink: @escaping @Sendable (PlanDraft) -> Void) { self.sink = sink }
        func report(_ draft: PlanDraft) {
            lock.lock(); defer { lock.unlock() }
            guard draft.blocks.count != reported else { return }
            reported = draft.blocks.count
            sink(draft)
        }
        /// A reply starting over (a retry): the timetable empties.
        func reset() { lock.lock(); reported = -1; lock.unlock() }
    }

    // MARK: Model

    struct Tokens: Sendable { var input = 0, cached = 0, output = 0, reasoning = 0 }

    /// The device model, or Claude when asked for (a failure there falls back to the device: the plan is a small task
    /// and today's); a device without a model plans with Claude only when it was given Claude, which the app does only
    /// when the user turned it on. Every route streams, and `report` sees the complete blocks so far.
    private func respond(_ prompt: String, route: IngestOptions.RoutePolicy, claude: ClaudeConfiguration?, report: Reporter) async throws -> (PlanDraft, Tokens, ModelRoute) {
        let device = SystemLanguageModel.default
        var useClaude = route == .claude
        if !useClaude, case .unavailable(let reason) = device.availability {
            guard claude != nil else { throw IngestError.modelUnavailable(String(describing: reason)) }
            log("plan: the device model is unavailable (\(String(describing: reason))); planning with Claude")
            useClaude = true
        }
        if useClaude, let claude, claude.isUsable {
            do {
                let client = ClaudeClient(configuration: claude, transport: transport, log: log)
                // Low effort, and room above it: at 1500 tokens a plan with study time was spent thinking before a word of it was written.
                let request = ClaudeClient.Request(system: Self.instructions, user: prompt, schema: ClaudeSchemas.plan, maxOutputTokens: 8000, effort: "low")
                let completion = try await client.stream(request) { text in report.report(PlanJSON.provisional(text)) }
                if completion.stopReason != "end_turn" { log("plan: Claude stopped with \(completion.stopReason ?? "nothing") after \(completion.outputTokens) tokens; the text ends \(String(completion.text.suffix(120)))") }
                let draft = try PlanJSON.decode(completion.text)
                return (draft, Tokens(input: completion.inputTokens, cached: completion.cachedTokens, output: completion.outputTokens), .claude)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard case .available = device.availability else { throw IngestError.claudeUnavailable(Extractor.explainClaude(error)) }
                log("plan: Claude could not be used (\(Extractor.explainClaude(error))); planning on the device")
                report.reset()
                report.report(PlanDraft(blocks: []))
            }
        } else if useClaude {
            throw IngestError.claudeUnavailable("no API key")
        }
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1300)   // 14 blocks: a day with coursework time in the evening is still reached
        let session = LanguageModelSession(model: device, instructions: Instructions(Self.instructions))
        let stream = session.streamResponse(to: Prompt(prompt), generating: PlanDraft.self, options: options)
        for try await snapshot in stream { report.report(Self.complete(snapshot.content)) }
        let response = try await stream.collect()
        return (response.content, Self.tokens(response.usage), .onDevice)
    }

    /// The blocks a snapshot has finished: the fields come in order, so a block whose last field has arrived is whole.
    static func complete(_ partial: PlanDraft.PartiallyGenerated) -> PlanDraft {
        let blocks = (partial.blocks ?? []).prefix { $0.kind != nil }.compactMap { b -> PlanDraftBlock? in
            guard let start = b.start, let end = b.end, let title = b.title, let kind = b.kind else { return nil }
            return PlanDraftBlock(start: start, end: end, title: title, reason: b.reason ?? "", kind: kind)
        }
        return PlanDraft(blocks: blocks)
    }

    /// The events that are coursework time, and the course each is for, as the model reads the calendar; none when it
    /// cannot be asked, and every event then stays a hard stop. Same route as the plan: Claude when asked for (the
    /// device if Claude fails), and when the device has no model ready and Claude was given (the app gives it only
    /// when the user turned planning with Claude on); else the device.
    func readCalendar(_ events: [PlanBusy], input: PlanInput, ranked: [PlanObligation], route: IngestOptions.RoutePolicy, claude: ClaudeConfiguration?) async -> CourseworkTime {
        let courses = Self.courses(of: ranked)
        let prompt = Self.calendarPrompt(events, courses: courses, calendar: input.calendar)
        let started = ContinuousClock.now
        var reading: CalendarReading?
        var used = ModelRoute.onDevice
        var tokens = Tokens()
        let device = SystemLanguageModel.default
        let deviceReady: Bool = { if case .available = device.availability { return true }; return false }()
        if (route == .claude || !deviceReady), let claude, claude.isUsable {
            do {
                let client = ClaudeClient(configuration: claude, transport: transport, log: log)
                let completion = try await client.stream(ClaudeClient.Request(system: Self.calendarInstructions, user: prompt, schema: ClaudeSchemas.calendar, maxOutputTokens: 4000, effort: "low")) { _ in }
                reading = try CalendarJSON.decode(completion.text)
                used = .claude
                tokens = Tokens(input: completion.inputTokens, cached: completion.cachedTokens, output: completion.outputTokens)
            } catch {
                log("plan: the calendar could not be read with Claude (\(Extractor.explainClaude(error)))")
            }
        }
        if reading == nil, deviceReady {
            do {
                let session = LanguageModelSession(model: device, instructions: Instructions(Self.calendarInstructions))
                let response = try await session.respond(to: Prompt(prompt), generating: CalendarReading.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400))
                reading = response.content
                used = .onDevice
                tokens = Self.tokens(response.usage)
            } catch {
                log("plan: the calendar could not be read on the device (\(error.localizedDescription)); every event is a hard stop")
            }
        }
        guard let reading else { return CourseworkTime() }
        let time = Self.coursework(in: reading, events: events, courses: courses)
        let record = UsageRecord(step: "calendar", chunk: 0, route: used, inputTokens: tokens.input, cachedTokens: tokens.cached, outputTokens: tokens.output,
                                 reasoningTokens: tokens.reasoning, durationMs: Int((ContinuousClock.now - started) / .milliseconds(1)))
        log("plan: calendar read, coursework time \(time.open.sorted().map { "\(events[$0 - 1].title) (\(time.courses[$0] ?? "any course"))" }), in \(record.inputTokens) out \(record.outputTokens) \(record.durationMs)ms")
        return time
    }

    /// The model's labels, matched to the events: by title said back (a small model can drop or repeat one), the entry's
    /// own place first when its event has that title (two "Study group"s: the second label is the second event's), else by
    /// place; a course named as in the list is kept, anything else (any, a course nobody has) means any course.
    static func coursework(in reading: CalendarReading, events: [PlanBusy], courses: [String]) -> CourseworkTime {
        var time = CourseworkTime()
        for (i, entry) in reading.events.enumerated() where entry.use == "coursework" {
            let key = Normalize.key(entry.title)
            let number: Int
            if i < events.count, Normalize.key(events[i].title) == key, !time.open.contains(i + 1) { number = i + 1 }
            else if let match = events.indices.first(where: { Normalize.key(events[$0].title) == key && !time.open.contains($0 + 1) }) { number = match + 1 }
            else if reading.events.count == events.count, !time.open.contains(i + 1) { number = i + 1 }
            else { continue }
            time.open.insert(number)
            if let course = courses.first(where: { Normalize.key($0) == Normalize.key(entry.course) }) { time.courses[number] = course }
        }
        return time
    }

    /// The student's courses with something coming up, in the order their obligations come.
    static func courses(of ranked: [PlanObligation]) -> [String] {
        var seen = Set<String>()
        return ranked.compactMap(\.course).filter { seen.insert(Normalize.key($0)).inserted }
    }

    static func calendarPrompt(_ events: [PlanBusy], courses: [String] = [], calendar: Calendar) -> String {
        func clock(_ d: Date) -> String { let c = calendar.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
        let list = courses.isEmpty ? [] : ["The student's courses: " + courses.joined(separator: "; ") + "."]
        return (list + ["Calendar events today:"] + events.map { "- \(clock($0.start))–\(clock($0.end)) \($0.title)" }).joined(separator: "\n")
    }

    private static func tokens(_ usage: LanguageModelSession.Usage) -> Tokens {
        Tokens(input: usage.input.totalTokenCount, cached: usage.input.cachedTokenCount, output: usage.output.totalTokenCount, reasoning: usage.output.reasoningTokenCount)
    }

    /// The day as the model reads it: the fixed events, the coursework time the calendar sets aside (read in the step before),
    /// the free gaps around all of them, and the obligations with their dates in plain words ("in 3 days", not "due in 3
    /// days": a test is not due, and the model decides which is which) and the grade row each counts toward.
    static func prompt(for input: PlanInput, gaps: [DateInterval], open: Set<Int> = [], courses: [Int: String] = [:], ranked: [PlanObligation]) -> String {
        let calendar = input.calendar
        func clock(_ d: Date) -> String { let c = calendar.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
        let afterMidnight = !calendar.isDate(input.now, inSameDayAs: input.date)
        var lines = ["Today is \(input.date.formatted(Self.english(.dateTime.weekday(.wide).month(.wide).day(), calendar: calendar))). It is \(clock(input.now)) now\(afterMidnight ? ", after midnight" : "")."]
        if input.hours.end > 24, let close = input.hours.closes(on: input.date, calendar: calendar) {   // so that 00:30 reads as later tonight, not this morning
            lines.append("The student is working late: the day runs past midnight, until \(clock(close)).")
        }
        let events = Self.events(in: input)
        let fixed = events.indices.filter { !open.contains($0 + 1) }, study = events.indices.filter { open.contains($0 + 1) }
        if fixed.isEmpty { lines.append("Fixed events: none.") } else {
            lines.append("Fixed events (hard stops):")
            for i in fixed { lines.append("- \(clock(events[i].start))–\(clock(events[i].end)) \(events[i].title)") }
        }
        if !study.isEmpty {   // each with the obligations that may go in it, so that no model has to work out what "math" covers
            lines.append("Coursework time on the calendar (fill it with the obligations named for it, within its hours):")
            for i in study {
                let hours = "\(clock(max(events[i].start, input.now)))–\(clock(events[i].end)) \(events[i].title)"
                if let course = courses[i + 1] {
                    let items = ranked.filter { $0.course == course }.map(\.title)
                    lines.append("- \(hours): for \(course)\(items.isEmpty ? "" : " (" + items.joined(separator: ", ") + ")")")
                } else {
                    lines.append("- \(hours): for any obligation")
                }
            }
        }
        lines.append(gaps.isEmpty ? "Free gaps to fill: none." : "Free gaps to fill:")
        for g in gaps { lines.append("- \(clock(g.start))–\(clock(g.end))") }
        if ranked.isEmpty { lines.append("Obligations: none coming up.") } else {
            lines.append("Obligations, with the day each falls on, nearest first:")
            for o in ranked {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.date), to: calendar.startOfDay(for: o.due)).day ?? 0
                let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days, \(Self.weekday(o.due, calendar: calendar))"
                let about = [o.course, o.component.map { "counts toward \($0)" }].compactMap { $0 }.joined(separator: ", ")
                let worth = o.points.map { " · \(Self.percent($0))% of the grade" } ?? ""
                lines.append("- \(o.title)\(about.isEmpty ? "" : " (\(about))") · \(when)\(worth)")
            }
        }
        if let instructions = input.instructions {   // capped: the on-device context is 4096 tokens and the schema and obligations need most of it
            lines.append("The student's own instructions:")
            lines.append(String(instructions.prefix(1500)))
        }
        lines.append(study.isEmpty ? "Plan the free gaps." : "Plan the free gaps and the coursework time.")
        return lines.joined(separator: "\n")
    }

    // MARK: Deterministic side

    /// Blocks that lie inside the free time or coursework time the model named, in order, without overlaps; times the
    /// model wrote past a window's edges are clipped to the window the block starts in, so no block crosses a hard stop or
    /// the edge of a coursework event. A block in coursework time says so (`within`). What a small model gets wrong is
    /// repaired here (CLAUDE.md, the day plan): an event's name for a title, a meal beside a meal on the calendar, a title
    /// that is only a kind of work, a block shorter or longer than one, a rest after a rest, a reason about another item.
    static func validate(_ draft: PlanDraft, input: PlanInput, ranked: [PlanObligation], open: Set<Int> = [], courses: [Int: String] = [:]) -> [PlanBlock] {
        let calendar = input.calendar
        /// "HH:mm" as hours and minutes; the day it falls on is `PlanHours.span`'s to say ("00:30" is tonight, after midnight).
        func time(_ text: String) -> (hour: Int, minute: Int)? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...59).contains(m) else { return nil }
            if h == 24, m == 0 { return (0, 0) }   // "24:00" is midnight, which `span` puts at the night's start
            return (0...23).contains(h) ? (h, m) : nil
        }
        let events = Self.events(in: input)
        let windows = Self.windows(in: input, open: open)
        var blocks: [PlanBlock] = []
        var cursor = Date.distantPast
        var perItem: [String: Int] = [:]
        for b in draft.blocks {
            guard let opening = time(b.start), let closing = time(b.end), let span = PlanHours.span(from: opening, to: closing, on: input.date, calendar: calendar, now: input.now) else { continue }
            var start = span.start, end = span.end
            let from = max(start, cursor)
            // The window the block starts in (or the first after that it reaches): a block that runs past a coursework event's
            // end stops there, one begun before it starts after its end is dropped with the rest of the overrun.
            guard let window = windows.first(where: { $0.interval.end > from && $0.interval.start < end }) else { continue }   // must touch free time or coursework time
            start = max(from, window.interval.start); end = min(end, window.interval.end)
            let kind: PlanBlock.Kind = switch b.kind { case "meal": .meal; case "rest": .rest; case "study": .study; default: .work }
            if kind == .work || kind == .study {
                // A block is 25 to 90 minutes: one written shorter is lengthened where its window allows, else dropped; one
                // written longer stops at 90. Cut short by a window's edge or the block before, a remnant of 15 stays.
                if span.duration < 25 * 60 { end = max(end, min(start.addingTimeInterval(25 * 60), window.interval.end)) }
                end = min(end, start.addingTimeInterval(90 * 60))
                guard end.timeIntervalSince(start) >= (span.duration < 25 * 60 ? 25 : 15) * 60 else { continue }
            } else {
                guard end.timeIntervalSince(start) >= 15 * 60 else { continue }
            }
            if kind == .rest { end = min(end, start.addingTimeInterval(20 * 60)) }   // a rest is a breather, not a block
            if kind == .rest, let last = blocks.last, last.kind == .rest, start.timeIntervalSince(last.end) < 5 * 60 { continue }   // one breather, not two in a row
            if kind == .meal, input.busy.contains(where: { Self.isMeal($0.title) && Self.isBeside(start, end, meal: $0) }) { continue }   // lunch with a friend was the meal
            // "HW 1 (Calculus II)" is the obligation "HW 1"; the longest obligation title the draft's title contains wins.
            var own = Normalize.collapseWhitespace(b.title)
            var matched: PlanObligation?
            // A block titled with an event's name ("Math study session", or the prompt's whole line for it, "Math study
            // session: for Calculus II (HW 4, Test 1)") is for the obligation its reason names ("Test 1 is Thursday:
            // practise…"); failing that, the nearest one that fits the coursework time it sits in (its course, the block's
            // kind, not yet planned twice); failing that, it is the event's time, named plainly.
            let ownKey = Normalize.key(own)
            let echoed = events.first { ownKey == Normalize.key($0.title) || ownKey.hasPrefix(Normalize.key($0.title) + " for ") }
            let course = window.event.flatMap { courses[$0] }
            if let echoed, kind == .work || kind == .study {
                let fits = ranked.filter { (course == nil || $0.course == course) && perItem[Normalize.key($0.title), default: 0] < 2 }
                if let named = Self.item(mentionedIn: b.reason, ranked: fits) ?? fits.first(where: { Self.looksHeld($0) == (kind == .study) }) ?? fits.first {
                    matched = named; own = named.title
                } else {
                    own = echoed.title
                }
            } else if kind == .work || kind == .study, input.instructions == nil, Self.bareKinds.contains(ownKey) {
                // "Work", "Study": a kind of time, not a thing to do. With nothing the student asked for to explain it, it is
                // the nearest obligation not yet planned that fits where it sits (its kind first), or nothing.
                let unplanned = ranked.filter { (course == nil || $0.course == course) && perItem[Normalize.key($0.title), default: 0] == 0 }
                guard let next = unplanned.first(where: { Self.looksHeld($0) == (kind == .study) }) ?? unplanned.first else { continue }
                matched = next; own = next.title
            } else {
                matched = Self.item(in: own, ranked: ranked)
            }
            var title = matched?.title ?? own
            // Coursework time for one course holds that course's obligations only: the calendar step said what it is for.
            if let number = window.event, let course = courses[number], let matched, matched.course != course { continue }
            var reason = Normalize.collapseWhitespace(b.reason)
            // A reason about another item ("Essay 2 is due tomorrow." on a block that became HW 4), or about none for a block
            // that was only a kind of time, is replaced by this one's facts.
            if let matched, kind == .work || kind == .study, Self.item(mentionedIn: reason, ranked: [matched]) == nil,
               Self.bareKinds.contains(ownKey) || Self.item(mentionedIn: reason, ranked: ranked) != nil {
                reason = kind == .study ? Self.studyReason(for: matched, input: input) : Self.workReason(for: matched, input: input)
            }
            if kind == .study, let matched {   // studied for, not done
                title = Self.studyTitle(own, for: matched)
                if Self.saysDue(reason) { reason = Self.studyReason(for: matched, input: input) }   // never "due": the facts, and what the time is for
            }
            guard !title.isEmpty else { continue }
            title = title.prefix(1).uppercased() + title.dropFirst()
            if kind == .work || kind == .study {   // a day is not one item over and over: at most two blocks on the same thing
                let key = Normalize.key(matched?.title ?? title)
                guard perItem[key, default: 0] < 2 else { continue }
                perItem[key, default: 0] += 1
            }
            let within = window.event.map { events[$0 - 1].title }
            blocks.append(PlanBlock(start: start, end: end, title: title, reason: reason, kind: kind, within: within))
            cursor = end
        }
        return blocks
    }

    /// A block's own words that only say what kind of time it is.
    static let bareKinds: Set<String> = ["work", "study", "studying", "homework", "coursework", "study time", "work time", "focus", "focus time", "deep work"]

    /// Whether a meal from `start` to `end` sits beside a meal on the calendar: right after it (within three hours of its
    /// end: lunch with a friend was the meal), or ending within the hour before it starts (dinner with family at six).
    static func isBeside(_ start: Date, _ end: Date, meal: PlanBusy) -> Bool {
        (meal.end <= start.addingTimeInterval(60) && start.timeIntervalSince(meal.end) < 3 * 3600)
            || (meal.start >= end.addingTimeInterval(-60) && meal.start.timeIntervalSince(end) < 3600)
    }

    /// Whether a calendar event is a meal ("Lunch with Sam"): the plan then needs no meal of its own beside it.
    static func isMeal(_ title: String) -> Bool {
        !Set(Normalize.key(title).split(separator: " ").map(String.init)).isDisjoint(with: ["breakfast", "brunch", "lunch", "dinner", "supper", "meal"])
    }

    /// The obligation a title is: the longest obligation title it contains, word for word.
    static func item(in title: String, ranked: [PlanObligation]) -> PlanObligation? {
        let key = " " + Normalize.key(title) + " "
        return ranked.filter { key.contains(" " + Normalize.key($0.title) + " ") }.max { $0.title.count < $1.title.count }
    }

    /// The obligation a sentence names first ("Finish HW4 problems…" names "HW 4": letters and digits run together are
    /// read apart), or nil when it names none.
    static func item(mentionedIn text: String, ranked: [PlanObligation]) -> PlanObligation? {
        func spaced(_ s: String) -> String {   // "hw4" → "hw 4", so a title printed either way matches
            var out = ""
            for ch in Normalize.key(s) {
                if let last = out.last, last != " ", ch != " ", last.isNumber != ch.isNumber { out.append(" ") }
                out.append(ch)
            }
            return " " + out + " "
        }
        let sentence = spaced(text)
        return ranked.compactMap { item -> (PlanObligation, String.Index)? in
            guard let range = sentence.range(of: spaced(item.title)) else { return nil }
            return (item, range.lowerBound)
        }.min { $0.1 < $1.1 }?.0
    }

    /// A block for studying: "Study for Test 1", or the model's own short framing when it is one ("Review for Test 1",
    /// "Practise Test 1"). Whatever else it wrote around the item (its course, its grade row, an event's name) goes.
    static func studyTitle(_ written: String, for item: PlanObligation) -> String {
        var own = written
        if let paren = own.range(of: " (", options: .backwards), own.hasSuffix(")") { own = String(own[..<paren.lowerBound]) }   // "(Calculus II, counts toward Exams)"
        let words = Normalize.key(own).split(separator: " ").map(String.init)
        let itemWords = Normalize.key(item.title).split(separator: " ").map(String.init)
        guard words.count > itemWords.count, Array(words.suffix(itemWords.count)) == itemWords else { return "Study for \(item.title)" }
        let framing = words.dropLast(itemWords.count)
        let verbs: Set<String> = ["study", "review", "prepare", "prep", "practice", "practise", "rehearse", "revise"]
        guard let first = framing.first, verbs.contains(first), framing.count <= 2, framing.dropFirst().allSatisfy({ $0 == "for" }) else { return "Study for \(item.title)" }
        return first.prefix(1).uppercased() + first.dropFirst() + (framing.count == 2 ? " for " : " ") + item.title
    }

    /// Whether a sentence speaks of a deadline or of finishing: wrong for something that is studied for. Phrases, not
    /// loose words: "have the formula sheet on hand" is no hand-in, and finishing a review is still studying.
    static func saysDue(_ reason: String) -> Bool {
        let key = (" " + Normalize.key(reason) + " ")
            .replacingOccurrences(of: #" finish(es|ed|ing)? (reviewing|studying|revising|practising|practicing|going over|working through) "#, with: " ", options: .regularExpression)
        return key.range(of: #" (due|deadlines?|submit\w*|submission|turn(s|ed|ing)? in|hand(s|ed|ing)? in|finish\w*|complet(e|es|ed|ing|ion)) "#, options: .regularExpression) != nil
    }

    /// The reason for a study block when the model's spoke of a deadline: when it happens and what it is worth.
    static func studyReason(for item: PlanObligation, input: PlanInput) -> String {
        let calendar = input.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.date), to: calendar.startOfDay(for: item.due)).day ?? 0
        let when = days <= 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days (\(Self.weekday(item.due, calendar: calendar)))"
        let worth = item.points.map { ", worth \(Self.percent($0))% of the grade" } ?? ""
        return "\(when)\(worth): time to review for it."
    }

    /// The reason for a work block when the model's was about something else: when it is due and what it is worth.
    static func workReason(for item: PlanObligation, input: PlanInput) -> String {
        let calendar = input.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.date), to: calendar.startOfDay(for: item.due)).day ?? 0
        let when = days <= 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due in \(days) days (\(Self.weekday(item.due, calendar: calendar)))"
        let worth = item.points.map { ", worth \(Self.percent($0))% of the grade" } ?? ""
        return "\(when)\(worth)."
    }

    /// Dates in the prompt and the reasons: in English, on the plan's own calendar and time zone, whatever the device's
    /// language and the process's zone ("Thursday", never "jeudi", nor Friday because the Mac is set to Tokyo).
    static func english(_ style: Date.FormatStyle, calendar: Calendar) -> Date.FormatStyle {
        var style = style
        var english = calendar; english.locale = Locale(identifier: "en_US_POSIX")
        style.locale = english.locale!; style.calendar = english; style.timeZone = calendar.timeZone
        return style
    }
    static func weekday(_ date: Date, calendar: Calendar) -> String { date.formatted(english(.dateTime.weekday(.wide), calendar: calendar)) }
    /// "1.5", "20": points of the grade, with a point for the decimal whatever the region.
    static func percent(_ points: Double) -> String { points.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX"))) }

    /// The calendar's events as blocks, so the plan reads as one sequence: every hard stop, and each coursework event the
    /// plan left empty. One the plan filled is shown by the blocks in it, each naming it; its hours are the same.
    static func fixedBlocks(_ input: PlanInput, open: Set<Int>, planned: [PlanBlock]) -> [PlanBlock] {
        events(in: input).enumerated().compactMap { i, e in
            if open.contains(i + 1), planned.contains(where: { $0.start < e.end && $0.end > e.start }) { return nil }
            return PlanBlock(start: e.start, end: e.end, title: e.title, reason: "On your calendar.", kind: .fixed)
        }
    }

    /// Every event of the day still to come, as blocks: the plan when there is nothing to fill.
    static func fixedOnly(_ input: PlanInput) -> [PlanBlock] { fixedBlocks(input, open: [], planned: []) }

    static func merge(_ blocks: [PlanBlock], fixed: [PlanBlock]) -> [PlanBlock] { (blocks + fixed).sorted { $0.start < $1.start } }

    /// Plan by the numbers: 50-minute blocks on the ranked obligations, a meal in the first gap that spans lunch or dinner.
    static func fallback(_ input: PlanInput, gaps: [DateInterval], ranked: [PlanObligation]) -> [PlanBlock] {
        let calendar = input.calendar
        var blocks: [PlanBlock] = []
        var queue = ranked
        var ate = false
        for gap in gaps {
            var cursor = gap.start
            while gap.end.timeIntervalSince(cursor) >= 25 * 60 {
                let hour = calendar.component(.hour, from: cursor)
                if !ate, (12...13).contains(hour) || (18...19).contains(hour) {
                    let end = min(cursor.addingTimeInterval(40 * 60), gap.end)
                    ate = true
                    // A meal on the calendar just before or after is the meal (lunch with a friend): none of the plan's own.
                    if !input.busy.contains(where: { Self.isMeal($0.title) && Self.isBeside(cursor, end, meal: $0) }) {
                        blocks.append(PlanBlock(start: cursor, end: end, title: "Eat", reason: "Nothing good gets done hungry.", kind: .meal))
                        cursor = end; continue
                    }
                }
                guard let next = queue.first else { break }
                let end = min(cursor.addingTimeInterval(50 * 60), gap.end)
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.date), to: calendar.startOfDay(for: next.due)).day ?? 0
                let worth = next.points.map { ", worth \(Self.percent($0))% of the grade" } ?? ""
                if Self.looksHeld(next) {   // studied for, never "due"
                    let when = days == 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days"
                    blocks.append(PlanBlock(start: cursor, end: end, title: "Study for \(next.title)", reason: "\(when)\(worth).", kind: .study))
                } else {
                    let when = days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due in \(days) days"
                    blocks.append(PlanBlock(start: cursor, end: end, title: next.title, reason: "\(when)\(worth).", kind: .work))
                }
                queue.removeFirst()
                cursor = end.addingTimeInterval(10 * 60)
            }
        }
        return merge(blocks, fixed: fixedOnly(input))
    }

    /// The plan by the numbers' guess at an item that happens at a set time and is studied for rather than done: its title
    /// or grade row names a test (not a quiz: many are online, and due), and its title names nothing made or read for one
    /// ("Exam review worksheet", "Test-taking strategies reading", "Final paper" are handed in). With a model, the model
    /// decides; this is only for the plan made without one, and for which item a bare "Study" block stands for.
    static func looksHeld(_ item: PlanObligation) -> Bool {
        func words(_ s: String) -> Set<String> { Set(Normalize.key(s).split(separator: " ").map(String.init)) }
        let held: Set<String> = ["exam", "exams", "test", "tests", "midterm", "midterms", "final", "finals"]
        let made: Set<String> = ["worksheet", "worksheets", "reading", "readings", "report", "reports", "paper", "papers", "essay", "essays", "project", "projects",
                                 "sheet", "assignment", "assignments", "homework", "hw", "draft", "proposal", "portfolio", "reflection", "lab", "labs", "writeup"]
        return !words(item.title + " " + (item.component ?? "")).isDisjoint(with: held) && words(item.title).isDisjoint(with: made)
    }
}
