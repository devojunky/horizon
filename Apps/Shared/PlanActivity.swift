#if os(iOS)   // ActivityKit ships on macOS too, with these types unavailable
import ActivityKit
import AppIntents
import Foundation

// Shared by the app and its widget extension: what the Live Activity shows, and the intent its button runs.

/// Today's plan as a Live Activity: the block on now, or the one up next, and how far the day has come.
struct PlanActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The block that is on and not done, if any.
        var current: Block?
        /// The first block still to do after it, or the first ahead when nothing is on.
        var next: Block?
        var done: Int
        var total: Int
        /// Nothing left: the day's plan is finished.
        var finished: Bool { current == nil && next == nil }
    }
    struct Block: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        var reason: String
        var kind: String
        var start: Date
        var end: Date
    }
    /// The day the plan is for.
    var day: Date
}

/// The Live Activity's Done button. A Live Activity intent runs in the app's process, which owns the plan: the app
/// registers what to do in `PlanCommands` when it starts, and the activity is updated before the intent returns.
struct MarkBlockDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Done"
    static let description = IntentDescription("Marks a block of today's plan done.")

    @Parameter(title: "Block") var blockID: String

    init() {}
    init(blockID: UUID) { self.blockID = blockID.uuidString }

    @MainActor func perform() async throws -> some IntentResult {
        PlanCommands.log?("intent: mark done \(blockID) (handler \(PlanCommands.markDone == nil ? "missing" : "present"))")
        if let id = UUID(uuidString: blockID) { await PlanCommands.markDone?(id) }
        return .result()
    }
}

/// What the app does for the intents: set when the app starts, nil in the extension (where intents never run).
@MainActor enum PlanCommands {
    static var markDone: ((UUID) async -> Void)?
    static var log: ((String) -> Void)?
}
#endif
