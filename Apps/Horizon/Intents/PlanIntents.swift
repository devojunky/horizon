import AppIntents
import EventKit
import Foundation
import HorizonCore
import IngestKit

// The day plan (SPEC §6.3) from outside the app: plan the day (up to tonight's end, with what the planner should know),
// say what's on and next, mark a block. Each goes through the app's own `AppModel` calls, so the plan's rules hold here
// too: Claude plans only with "Plan the day with Claude" on, an edited plan is replaced only on the user's word, a
// block's done is never an item's.

/// SPEC §7's `GenerateDayPlanIntent`: plan the rest of today, with Now's two inputs as parameters: how late tonight runs
/// (Tonight Until, for tonight only) and something the planner should know (Tell the Planner, kept). A plan can take a
/// minute on the device's model, more than an intent's thirty seconds, so it runs as a long-running intent with its
/// progress shown; on iPhone it also starts the plan's Live Activity, which only an intent of that kind may do from the
/// background.
struct PlanDayIntent: LongRunningIntent {
    static let title: LocalizedStringResource = "Plan My Day"
    static let description = IntentDescription("Plans the rest of today around your calendar, from the work that matters most, with a reason for each block. Until sets how late tonight's plan runs, for tonight only; Keep in Mind tells the planner something it keeps for every plan from now on. With planning by Claude turned on in Settings, today's events and items are sent to Anthropic.",
                                               categoryName: "Day Plan", searchKeywords: ["plan", "schedule", "today", "tonight", "late", "until", "bedtime", "remember", "instructions"],
                                               resultValueName: "Blocks")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    @Parameter(title: "Until", description: "How late tonight's plan runs, for tonight only.") var until: TonightEnd?
    @Parameter(title: "Keep in Mind", description: "Something the planner should know (\"practice from 4 to 6 on Tuesdays\"), kept for every plan from now on.")
    var keepInMind: String?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Plan my day until \(\.$until)") { \.$keepInMind } }

    /// How much the planner keeps (Tell the Planner's own limit).
    static let instructionsLimit = 1500

    @MainActor func perform() async throws -> some ReturnsValue<[PlanBlockEntity]> & ProvidesDialog & ShowsSnippetView {
        try model.requireLibrary()
        model.expirePlanIfStale()
        if let until, !PlanHours.endsAhead(including: model.tonightEnd).contains(until.hour) {
            throw IntentFailure.message("\(PlanHours.label(until.hour)) has already gone by tonight.")
        }
        // What the planner should know is kept whatever becomes of this plan: it's for every plan after it too.
        if let note = keepInMind?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            let combined = model.planInstructions.isEmpty ? note : model.planInstructions + "\n" + note
            guard combined.count <= Self.instructionsLimit else {
                throw IntentFailure.message("The planner keeps up to \(Self.instructionsLimit) characters, and that would pass it. Open Tell the Planner in Now to make room.")
            }
            model.planInstructions = combined
        }
        // The calendar is asked for once, in front of the user; a plan from the background never asks.
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            try await continueInForeground("Horizon asks once to read your calendar, so the plan works around it.", alwaysConfirm: false)
        }
        if model.plan != nil, model.planEdited {
            let end = until.map { " until \(PlanHours.label($0.hour))" } ?? ""
            try await requestConfirmation(actionName: .continue, dialog: "Today's plan has changes you made. Plan the day again\(end) anyway?")
        }
        if let until { model.tonightEnd = until.hour }   // tonight only, as Now's pop-up sets it; only once the plan goes ahead
        let progress = self.progress
        let model = self.model
        try await performBackgroundTask { @MainActor @Sendable in await model.planToday(reporting: progress) }
        return PlanAnswer(model: model).result(lead: until.map { "Here's your day, until \(PlanHours.label($0.hour))" } ?? "Here's your day")
    }
}

#if os(iOS)
extension PlanDayIntent: LiveActivityIntent {}
#endif

/// What's on the plan now, what's next, and whether a block that ended asks "finished?".
struct GetPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Plan"
    static let description = IntentDescription("Says the block of today's plan that's on now and what comes next, and returns the blocks left.", categoryName: "Day Plan",
                                               searchKeywords: ["next", "now", "plan", "schedule", "what's on"], resultValueName: "Blocks")
    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some ReturnsValue<[PlanBlockEntity]> & ProvidesDialog & ShowsSnippetView {
        try model.requireLibrary()
        model.expirePlanIfStale()
        return PlanAnswer(model: model).result(lead: nil)
    }
}

/// A block's done, or set aside: from Siri ("I finished"), a shortcut, or the Action button. Without a block, the one
/// that's on now, or the one asking "finished?".
struct MarkBlockIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark a Plan Block"
    static let description = IntentDescription("Marks a block of today's plan done, or sets it aside, or takes either back. It's the plan's mark only: the item's own check in Reminders is separate.",
                                               categoryName: "Day Plan", searchKeywords: ["done", "finished", "skip"])
    @Parameter(title: "Block") var block: PlanBlockEntity?
    @Parameter(title: "As", default: .done) var mark: BlockMark
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Mark \(\.$block) \(\.$mark)") }

    @MainActor func perform() async throws -> some ReturnsValue<PlanBlockEntity> & ProvidesDialog {
        try model.requireLibrary()
        model.expirePlanIfStale()
        guard let plan = model.plan else { throw IntentFailure.message("There's no plan for today.") }
        let id = block?.id ?? model.blockAwaitingAnswer()?.id ?? plan.focus(at: .now).current?.id
        guard let id, let found = plan.blocks.first(where: { $0.id == id }) else {
            throw block == nil ? IntentFailure.message("No block is on right now. Say which one.") : IntentFailure.message("That block isn't in today's plan any more.")
        }
        switch mark {
        case .done: model.markBlock(id, done: true, syncing: false)
        case .setAside: model.skipBlock(id, skipped: true, syncing: false)
        case .open:
            model.markBlock(id, done: false, syncing: false)
            model.skipBlock(id, skipped: false, syncing: false)
        }
        await model.syncActivity()
        let after = model.plan?.blocks.first { $0.id == id } ?? found
        let said = switch mark { case .done: "Marked \(found.title) done."; case .setAside: "Set \(found.title) aside."; case .open: "\(found.title) is open again." }
        return .result(value: PlanBlockEntity(after), dialog: "\(said)")
    }
}

enum BlockMark: String, AppEnum {
    case done, setAside, open
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mark"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .done: DisplayRepresentation(title: "Done", synonyms: ["finished", "complete"]),
        .setAside: DisplayRepresentation(title: "Set Aside", synonyms: ["skipped", "not finished", "not yet"]),
        .open: DisplayRepresentation(title: "Not Done Yet", synonyms: ["open", "undone"]),
    ]
}

/// The night's possible ends, 6 PM to 4 AM (`PlanHours.ends`).
enum TonightEnd: String, AppEnum {
    case sixPM, sevenPM, eightPM, ninePM, tenPM, elevenPM, midnight, oneAM, twoAM, threeAM, fourAM
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Time"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .sixPM: "6 PM", .sevenPM: "7 PM", .eightPM: "8 PM", .ninePM: "9 PM", .tenPM: "10 PM", .elevenPM: "11 PM",
        .midnight: DisplayRepresentation(title: "Midnight", synonyms: ["12 AM"]), .oneAM: "1 AM", .twoAM: "2 AM", .threeAM: "3 AM", .fourAM: "4 AM",
    ]
    var hour: Int {
        switch self {
        case .sixPM: 18
        case .sevenPM: 19
        case .eightPM: 20
        case .ninePM: 21
        case .tenPM: 22
        case .elevenPM: 23
        case .midnight: 24
        case .oneAM: 25
        case .twoAM: 26
        case .threeAM: 27
        case .fourAM: 28
        }
    }
}

/// The plan as an answer: what's on, what's next, the question standing, and the blocks left, for a reply that stands
/// alone aloud (a few blocks, then how many more).
@MainActor
struct PlanAnswer {
    let model: AppModel

    func result(lead: String?) -> some ReturnsValue<[PlanBlockEntity]> & ProvidesDialog & ShowsSnippetView {
        guard let plan = model.plan, !plan.blocks.isEmpty else {
            let note = model.plan?.note.map { " \($0)" } ?? ""
            return .result(value: [], dialog: "There's no plan for today yet.\(note) Ask Horizon to plan your day.", view: PlanSnippet(blocks: [], note: nil))
        }
        let now = Date()
        let left = plan.blocks.filter { $0.isOpen && $0.end > now }
        let focus = plan.focus(at: now)
        var parts: [String] = []
        if let asking = plan.awaitingAnswer(at: now) { parts.append("\(asking.title) ended at \(asking.end.formatted(date: .omitted, time: .shortened)): finished?") }
        if let current = focus.current { parts.append("Now: \(current.title), until \(current.end.formatted(date: .omitted, time: .shortened))") }
        if let next = focus.next { parts.append("Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))") }
        if parts.isEmpty { parts.append(left.isEmpty ? "Today's plan is done" : "Nothing more is planned") }
        let more = left.count > 2 ? " \(Spoken.count(left.count - (focus.current == nil ? 1 : 2), "more block")) after that." : ""
        let note = plan.note.map { " \($0)" } ?? ""
        let spoken = (lead.map { "\($0). " } ?? "") + parts.joined(separator: ". ") + "." + more + note
        return .result(value: left.map(PlanBlockEntity.init), dialog: "\(spoken)", view: PlanSnippet(blocks: Array(left.prefix(6)), note: plan.note))
    }
}
