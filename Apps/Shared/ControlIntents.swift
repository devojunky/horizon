#if os(iOS)
import AppIntents
import Foundation

/// Control Center's Plan My Day (and the Lock Screen's, and the Action button's): plans the rest of today in the app,
/// which owns the plan, and the plan's Live Activity starts with it, so one press needs no trip into the app (HIG:
/// controls for actions that avoid launching it, a Live Activity's start the example). Compiled into the app and the
/// widget extension, which holds the control; it runs only in the app (`allowedExecutionTargets`), through
/// `PlanCommands.planDay`. A plan can outlast an intent's thirty seconds on the device's model, so it runs long, its
/// progress the blocks as they arrive.
struct PlanDayControlIntent: LongRunningIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Plan My Day"
    static let description = IntentDescription("Plans the rest of today and shows it in a Live Activity.")
    static let isDiscoverable = false   // Siri and Shortcuts have the app's own Plan My Day
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        guard PlanCommands.planDay != nil else { return .result() }   // never in the extension: the app plans
        let progress = self.progress
        try await performBackgroundTask { @MainActor @Sendable in await PlanCommands.planDay?(progress) }
        return .result()
    }
}
#endif
