#if os(iOS)   // ActivityKit ships on macOS too, with these types unavailable
import ActivityKit
import AppIntents
import Foundation

// Shared by the app and its widget extension: what the Live Activity shows, and the intents its buttons run.

/// Today's plan as a Live Activity: the block on now, or the one up next, or the question a work block asks when it
/// ends ("finished?"), and how far the day has come.
struct PlanActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The block that is on and still open, if any.
        var current: Block?
        /// The first open block after it, or the first ahead when nothing is on.
        var next: Block?
        /// A work block that is over and has not been answered: done, or not finished. Nil when none is asking.
        var asking: Block?
        var done: Int
        var total: Int
        /// Nothing left: no block on, none ahead, no question standing.
        var finished: Bool { current == nil && next == nil && asking == nil }

        /// What the activity shows at `now`. The app says what the day is when it updates the activity, but time goes
        /// on between its updates: the system draws the activity again at the stale date (the first moment what it
        /// shows changes), and by then the block that was on may be over and asking, its question may have timed out,
        /// or the one up next may have begun. So the views work it out from the blocks' own times, not from the moment
        /// the app wrote them.
        func phase(at now: Date) -> Phase {
            if let asking, let by = asking.answerBy, now < by { return .asking(asking) }
            if let current {
                if now < current.end { return .on(current) }
                if let by = current.answerBy, now < by { return .asking(current) }
            }
            if let next {
                if now < next.end { return now < next.start ? .upNext(next) : .on(next) }
                if let by = next.answerBy, now < by { return .asking(next) }
            }
            return .done
        }

        /// The first moment after `now` at which `phase` changes: the activity's stale date.
        func nextChange(after now: Date) -> Date? {
            [asking?.answerBy, current?.end, current?.answerBy, next?.start, next?.end, next?.answerBy].compactMap { $0 }.filter { $0 > now }.min()
        }
    }

    enum Phase: Equatable {
        case on(Block)
        case upNext(Block)
        /// The block is over: finished, or not?
        case asking(Block)
        case done
    }

    struct Block: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        var reason: String
        var kind: String
        var start: Date
        var end: Date
        /// When the question its end asks ("finished?") stops standing; nil for a block that asks none (a meal, a rest,
        /// a calendar event).
        var answerBy: Date?
    }
    /// The day the plan is for.
    var day: Date
}

/// The Live Activity's Done button (while a block is on, and as the answer to "finished?"). A Live Activity intent runs
/// in the app's process, which owns the plan: the app registers what to do in `PlanCommands` when it starts, and the
/// activity is updated before the intent returns.
struct MarkBlockDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Done"
    static let description = IntentDescription("Marks a block of today's plan done.")
    static let isDiscoverable = false   // the activity's own button; Shortcuts gets real intents in M6

    @Parameter(title: "Block") var blockID: String

    init() {}
    init(blockID: UUID) { self.blockID = blockID.uuidString }

    @MainActor func perform() async throws -> some IntentResult {
        PlanCommands.log?("intent: mark done \(blockID) (handler \(PlanCommands.markDone == nil ? "missing" : "present"))")
        if let id = UUID(uuidString: blockID) { await PlanCommands.markDone?(id) }
        return .result()
    }
}

/// The Live Activity's Skip button (a block on or up next), and its Not Yet (the answer to "finished?"): the block is
/// set aside, not done. The plan organises the day; it holds nobody to it.
struct SkipBlockIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip"
    static let description = IntentDescription("Sets a block of today's plan aside without marking it done.")
    static let isDiscoverable = false

    @Parameter(title: "Block") var blockID: String

    init() {}
    init(blockID: UUID) { self.blockID = blockID.uuidString }

    @MainActor func perform() async throws -> some IntentResult {
        PlanCommands.log?("intent: skip \(blockID) (handler \(PlanCommands.skip == nil ? "missing" : "present"))")
        if let id = UUID(uuidString: blockID) { await PlanCommands.skip?(id) }
        return .result()
    }
}

/// What the app does for the intents: set when the app starts, nil in the extension (where intents never run).
@MainActor enum PlanCommands {
    static var markDone: ((UUID) async -> Void)?
    static var skip: ((UUID) async -> Void)?
    /// Plans the rest of today, reporting the blocks as they arrive (`PlanDayControlIntent`).
    static var planDay: ((Progress) async -> Void)?
    static var log: ((String) -> Void)?
}
#endif
