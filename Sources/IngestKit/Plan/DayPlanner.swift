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
    public init(start: Date, end: Date, title: String, reason: String, kind: Kind) {
        self.start = start; self.end = end; self.title = title; self.reason = reason; self.kind = kind
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
    public init(log: @escaping @Sendable (String) -> Void = { _ in }) { self.log = log }

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

    public func plan(_ input: PlanInput, route: IngestOptions.RoutePolicy = .onDeviceFirst, openAI: OpenAIConfiguration? = nil) async -> DayPlan {
        let gaps = Self.gaps(in: input)
        let ranked = Array(Self.ranked(input).prefix(12))
        guard !gaps.isEmpty else { return DayPlan(blocks: Self.fixedOnly(input), route: nil, usage: nil, note: "No free time left today.") }
        guard !ranked.isEmpty || input.instructions != nil else {   // nothing due and nothing asked: the calendar is the plan
            return DayPlan(blocks: Self.fixedOnly(input), route: nil, usage: nil, note: "Nothing is due in the coming weeks, so there is nothing to plan.")
        }
        let prompt = Self.prompt(for: input, gaps: gaps, ranked: ranked)
        let started = ContinuousClock.now
        do {
            let (draft, usage, used) = try await respond(prompt, route: route, openAI: openAI)
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

    // MARK: Model

    struct Tokens: Sendable { var input = 0, cached = 0, output = 0, reasoning = 0 }

    /// OpenAI when asked for and reachable (its client retries; a failure falls through to Apple's models), else Private
    /// Cloud Compute when entitled, else the device.
    private func respond(_ prompt: String, route: IngestOptions.RoutePolicy, openAI: OpenAIConfiguration?) async throws -> (PlanDraft, Tokens, ModelRoute) {
        if route == .openAI, let openAI {
            do {
                let client = OpenAIClient(configuration: openAI, log: log)
                let request = OpenAIClient.Request(system: Self.instructions, user: prompt, schemaName: "plan_draft", schema: OpenAISchemas.plan, maxOutputTokens: 1500)
                let completion = try await client.stream(request)
                let draft = try PlanJSON.decode(completion.text)
                return (draft, Tokens(input: completion.inputTokens, cached: completion.cachedTokens, output: completion.outputTokens), .openAI)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("plan: OpenAI could not be used (\(error.localizedDescription)); planning with Apple's models")
            }
        }
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 900)
        if route != .onDeviceOnly, Extractor.hasCloudEntitlement, case .available = PrivateCloudComputeLanguageModel().availability {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Instructions(Self.instructions))
            let response = try await session.respond(to: Prompt(prompt), generating: PlanDraft.self, options: options, contextOptions: ContextOptions(reasoningLevel: .deep))
            return (response.content, Self.tokens(response.usage), .privateCloudCompute)
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw IngestError.modelUnavailable(String(describing: model.availability)) }
        let session = LanguageModelSession(model: model, instructions: Instructions(Self.instructions))
        let response = try await session.respond(to: Prompt(prompt), generating: PlanDraft.self, options: options)
        return (response.content, Self.tokens(response.usage), .onDevice)
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
