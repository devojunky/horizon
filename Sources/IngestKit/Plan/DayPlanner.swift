import Foundation
import FoundationModels

// SPEC §6.3 "Now": one button, a disposable plan for today. Fixed events from the calendar are hard stops; the free gaps
// are filled with the work that matters most first, with a reason on every block. The model proposes; the planner
// keeps it inside the gaps and falls back to a deterministic plan when the model is unavailable or unusable.

public struct PlanBusy: Sendable, Equatable, Codable {
    public var title: String
    public var start: Date
    public var end: Date
    public init(title: String, start: Date, end: Date) { self.title = title; self.start = start; self.end = end }
}

public struct PlanObligation: Sendable, Equatable, Codable {
    public var title: String
    public var course: String?
    public var due: Date
    public var points: Double?
    public var notes: String?
    public init(title: String, course: String? = nil, due: Date, points: Double? = nil, notes: String? = nil) {
        self.title = title; self.course = course; self.due = due; self.points = points; self.notes = notes
    }
}

public struct PlanInput: Sendable {
    public var date: Date
    public var now: Date
    public var busy: [PlanBusy]
    public var obligations: [PlanObligation]
    public var calendar: Calendar
    /// The day the plan may use, as hours.
    public var dayStart = 8
    public var dayEnd = 22
    /// The student's own instructions, in their words: standing rules or today's. They outrank the planner's habits
    /// but not the fixed events, and they need the model (the plan by the numbers cannot read them).
    public var instructions: String?
    public init(date: Date, now: Date, busy: [PlanBusy], obligations: [PlanObligation], calendar: Calendar = .current, instructions: String? = nil) {
        self.date = date; self.now = now; self.busy = busy; self.obligations = obligations; self.calendar = calendar
        self.instructions = instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct PlanBlock: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case work, meal, rest, fixed }
    public var id = UUID()
    public var start: Date
    public var end: Date
    public var title: String
    public var reason: String
    public var kind: Kind
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
    /// Whether the end of the block is worth a question (did you finish?): work is; a meal, a rest and a calendar
    /// event simply end.
    public var asksWhenOver: Bool { kind == .work }
    public init(start: Date, end: Date, title: String, reason: String, kind: Kind, completedAt: Date? = nil, skippedAt: Date? = nil) {
        self.start = start; self.end = end; self.title = title; self.reason = reason; self.kind = kind; self.completedAt = completedAt; self.skippedAt = skippedAt
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
    public var doneCount: Int { blocks.filter(\.isDone).count }

    /// How long the question at the end of a work block ("finished?") stands. Unanswered by then, the block is taken as
    /// not finished: nothing is recorded (not done is where every block starts), and the question goes.
    public static let answerWindow: TimeInterval = 15 * 60

    /// When the question at the end of `block` stops standing; nil for a block that asks none.
    public static func answerBy(_ block: PlanBlock) -> Date? {
        block.asksWhenOver ? block.end.addingTimeInterval(answerWindow) : nil
    }

    /// The block whose end is asking "finished?" at `now`: a work block that is over, neither done nor set aside, its
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
    @Guide(description: "Ordered blocks for the free gaps only, 25 to 90 minutes each", .maximumCount(10))
    var blocks: [PlanDraftBlock]
}

@Generable
struct PlanDraftBlock {
    @Guide(description: "Start time, 24-hour HH:mm")
    var start: String
    @Guide(description: "End time, 24-hour HH:mm")
    var end: String
    @Guide(description: "The obligation's title as given, or what the block is for")
    var title: String
    @Guide(description: "One sentence: why this, why now")
    var reason: String
    @Guide(.anyOf(["work", "meal", "rest"]))
    var kind: String
}

public actor DayPlanner {
    public static let instructions = """
    You plan one student's day. Fixed events are hard stops: never place anything over them. Fill the free gaps, in order, \
    with the work that matters most first: the nearest deadlines, weighted by points at stake. Blocks are 25 to 90 minutes; \
    leave short rests between long stretches. If the day has no meal yet, the first block after 11:30 or after 17:30 is a meal. \
    Every block has a one-sentence reason that names the deadline or the need. Use titles exactly as given. \
    The student's own instructions, when given, outrank the habits above: follow them, except that fixed events stay hard stops.
    """

    private let log: @Sendable (String) -> Void
    private let transport: ClaudeTransport
    public init(log: @escaping @Sendable (String) -> Void = { _ in }, transport: ClaudeTransport = .live) { self.log = log; self.transport = transport }

    /// Free time between the fixed events, inside the day, from now on, at least 25 minutes long.
    public static func gaps(in input: PlanInput) -> [DateInterval] {
        let calendar = input.calendar
        let day = calendar.startOfDay(for: input.date)
        guard let open = calendar.date(bySettingHour: input.dayStart, minute: 0, second: 0, of: day),
              let close = calendar.date(bySettingHour: input.dayEnd, minute: 0, second: 0, of: day) else { return [] }
        var cursor = max(open, input.now)
        var gaps: [DateInterval] = []
        for event in input.busy.sorted(by: { $0.start < $1.start }) where event.end > cursor {
            if event.start > cursor { gaps.append(DateInterval(start: cursor, end: min(event.start, close))) }
            cursor = max(cursor, event.end)
            if cursor >= close { break }
        }
        if cursor < close { gaps.append(DateInterval(start: cursor, end: close)) }
        return gaps.filter { $0.duration >= 25 * 60 }
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
        guard !gaps.isEmpty else { return DayPlan(blocks: Self.fixedOnly(input), route: nil, usage: nil, note: "No free time left today.") }
        guard !ranked.isEmpty || input.instructions != nil else {   // nothing due and nothing asked: the calendar is the plan
            return DayPlan(blocks: Self.fixedOnly(input), route: nil, usage: nil, note: "Nothing is due in the coming weeks, so there is nothing to plan.")
        }
        let prompt = Self.prompt(for: input, gaps: gaps, ranked: ranked)
        let started = ContinuousClock.now
        let report = Reporter { draft in progress(Self.provisional(draft, gaps: gaps, input: input, ranked: ranked)) }
        do {
            let (draft, usage, used) = try await respond(prompt, route: route, claude: claude, report: report)
            let blocks = Self.validate(draft, gaps: gaps, input: input, ranked: ranked)
            let record = UsageRecord(step: "plan", chunk: 0, route: used, inputTokens: usage.input, cachedTokens: usage.cached,
                                     outputTokens: usage.output, reasoningTokens: usage.reasoning,
                                     durationMs: Int((ContinuousClock.now - started) / .milliseconds(1)))
            log("plan: \(draft.blocks.count) proposed, \(blocks.count) kept, in \(record.inputTokens) out \(record.outputTokens) \(record.durationMs)ms")
            if blocks.isEmpty {
                let unread = input.instructions == nil ? "" : " Your instructions were not followed."
                return DayPlan(blocks: Self.fallback(input, gaps: gaps, ranked: ranked), route: nil, usage: record, note: "The model's plan did not fit the day; this one is by the numbers." + unread)
            }
            return DayPlan(blocks: Self.merge(blocks, fixed: Self.fixedOnly(input)), route: used, usage: record, note: nil)
        } catch {
            log("plan: model unavailable (\(error.localizedDescription)); planning by the numbers")
            let unread = input.instructions == nil ? "" : " Your instructions need the model."
            return DayPlan(blocks: Self.fallback(input, gaps: gaps, ranked: ranked), route: nil, usage: nil, note: "Planned by the numbers; the model was not available." + unread)
        }
    }

    /// The plan so far, for a timetable that grows: the complete blocks validated as the whole draft will be (validation
    /// walks the draft in order, so a prefix of the draft validates to a prefix of the result), and the calendar's
    /// events up to the last of them, so the rail only ever extends downward. A retried reply starts over.
    static func provisional(_ draft: PlanDraft, gaps: [DateInterval], input: PlanInput, ranked: [PlanObligation]) -> [PlanBlock] {
        let blocks = validate(draft, gaps: gaps, input: input, ranked: ranked)
        guard let last = blocks.last else { return [] }
        return merge(blocks, fixed: fixedOnly(input).filter { $0.start < last.end })
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
    /// and today's); a device without a model plans with Claude when it is configured. Every route streams, and
    /// `report` sees the complete blocks so far.
    private func respond(_ prompt: String, route: IngestOptions.RoutePolicy, claude: ClaudeConfiguration?, report: Reporter) async throws -> (PlanDraft, Tokens, ModelRoute) {
        let device = SystemLanguageModel.default
        var useClaude = route == .claude
        if !useClaude, case .unavailable(let reason) = device.availability {
            guard claude != nil else { throw IngestError.modelUnavailable(String(describing: reason)) }
            log("plan: the device model is unavailable (\(String(describing: reason))); planning with Claude")
            useClaude = true
        }
        if useClaude, let claude, !claude.apiKey.isEmpty {
            do {
                let client = ClaudeClient(configuration: claude, transport: transport, log: log)
                let request = ClaudeClient.Request(system: Self.instructions, user: prompt, schema: ClaudeSchemas.plan, maxOutputTokens: 1500)
                let completion = try await client.stream(request) { text in report.report(PlanJSON.provisional(text)) }
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
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 900)
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

    private static func tokens(_ usage: LanguageModelSession.Usage) -> Tokens {
        Tokens(input: usage.input.totalTokenCount, cached: usage.input.cachedTokenCount, output: usage.output.totalTokenCount, reasoning: usage.output.reasoningTokenCount)
    }

    static func prompt(for input: PlanInput, gaps: [DateInterval], ranked: [PlanObligation]) -> String {
        let calendar = input.calendar
        func clock(_ d: Date) -> String { let c = calendar.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
        var lines = ["Today is \(input.date.formatted(.dateTime.weekday(.wide).month(.wide).day())). It is \(clock(input.now)) now."]
        if input.busy.isEmpty { lines.append("Fixed events: none.") } else {
            lines.append("Fixed events (hard stops):")
            for e in input.busy.sorted(by: { $0.start < $1.start }) { lines.append("- \(clock(e.start))–\(clock(e.end)) \(e.title)") }
        }
        lines.append("Free gaps to fill:")
        for g in gaps { lines.append("- \(clock(g.start))–\(clock(g.end))") }
        if ranked.isEmpty { lines.append("Obligations: none due soon.") } else {
            lines.append("Obligations, nearest deadline first:")
            for o in ranked {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.date), to: calendar.startOfDay(for: o.due)).day ?? 0
                let when = days == 0 ? "due today" : days == 1 ? "due tomorrow" : "due in \(days) days"
                let worth = o.points.map { " · worth \($0.formatted(.number.precision(.fractionLength(0...1))))% of the grade" } ?? ""
                lines.append("- \(o.title)\(o.course.map { " (\($0))" } ?? "") · \(when)\(worth)")
            }
        }
        if let instructions = input.instructions {   // capped: the on-device context is 4096 tokens and the schema and obligations need most of it
            lines.append("The student's own instructions:")
            lines.append(String(instructions.prefix(1500)))
        }
        lines.append("Plan the free gaps.")
        return lines.joined(separator: "\n")
    }

    // MARK: Deterministic side

    /// Blocks that lie inside the free gaps, in order, without overlaps; times the model wrote outside the gaps are clipped.
    static func validate(_ draft: PlanDraft, gaps: [DateInterval], input: PlanInput, ranked: [PlanObligation]) -> [PlanBlock] {
        let calendar = input.calendar
        let day = calendar.startOfDay(for: input.date)
        func time(_ text: String) -> Date? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
            return calendar.date(bySettingHour: h, minute: m, second: 0, of: day)
        }
        var blocks: [PlanBlock] = []
        var cursor = Date.distantPast
        var perTitle: [String: Int] = [:]
        for b in draft.blocks {
            guard var start = time(b.start), var end = time(b.end), end > start else { continue }
            guard let gap = gaps.first(where: { $0.end > start && $0.start < end }) else { continue }   // must touch a gap
            start = max(start, gap.start, cursor); end = min(end, gap.end)
            guard end.timeIntervalSince(start) >= 15 * 60 else { continue }
            let kind: PlanBlock.Kind = switch b.kind { case "meal": .meal; case "rest": .rest; default: .work }
            if kind == .rest { end = min(end, start.addingTimeInterval(20 * 60)) }   // a rest is a breather, not a block
            // "HW 1 (Calculus II)" is the obligation "HW 1"; the longest obligation title the draft's title contains wins.
            let draftKey = " " + Normalize.key(b.title) + " "
            let matched = ranked.filter { draftKey.contains(" " + Normalize.key($0.title) + " ") }.max { $0.title.count < $1.title.count }
            var title = matched?.title ?? Normalize.collapseWhitespace(b.title)
            guard !title.isEmpty else { continue }
            title = title.prefix(1).uppercased() + title.dropFirst()
            if kind == .work {   // a day is not one item over and over: at most two blocks on the same thing
                let key = Normalize.key(title)
                guard perTitle[key, default: 0] < 2 else { continue }
                perTitle[key, default: 0] += 1
            }
            blocks.append(PlanBlock(start: start, end: end, title: title, reason: Normalize.collapseWhitespace(b.reason), kind: kind))
            cursor = end
        }
        return blocks
    }

    /// The fixed events of the day, as blocks, so the plan reads as one sequence.
    static func fixedOnly(_ input: PlanInput) -> [PlanBlock] {
        input.busy.filter { $0.end > input.now }.sorted { $0.start < $1.start }
            .map { PlanBlock(start: $0.start, end: $0.end, title: $0.title, reason: "On your calendar.", kind: .fixed) }
    }

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
                    blocks.append(PlanBlock(start: cursor, end: end, title: "Eat", reason: "Nothing good gets done hungry.", kind: .meal))
                    cursor = end; ate = true; continue
                }
                guard let next = queue.first else { break }
                let end = min(cursor.addingTimeInterval(50 * 60), gap.end)
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: input.date), to: calendar.startOfDay(for: next.due)).day ?? 0
                let when = days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due in \(days) days"
                let worth = next.points.map { ", worth \($0.formatted(.number.precision(.fractionLength(0...1))))% of the grade" } ?? ""
                blocks.append(PlanBlock(start: cursor, end: end, title: next.title, reason: "\(when)\(worth).", kind: .work))
                queue.removeFirst()
                cursor = end.addingTimeInterval(10 * 60)
            }
        }
        return merge(blocks, fixed: fixedOnly(input))
    }
}
