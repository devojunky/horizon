import AppIntents

/// The App Shortcuts: the things most worth saying to Siri by name ("… in Horizon"), ready from install with no setup,
/// in Spotlight and the Shortcuts app, most important first (HIG: at most ten, every phrase names the app, at most one
/// parameter, an entity or an enum; Apple: two to five usually cover an app's key features). Siri's own model reaches
/// only the schemas' actions (add, change, delete an item; add a course; open an item; search), with no phrase at all;
/// everything else Siri reaches through these phrases. A phrase whose parameter is an enum becomes one shortcut per
/// value ("What's most important in Horizon", "What's piling up in Horizon").
struct HorizonShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetItemsIntent(), phrases: [
            "What's due in \(.applicationName)",
            "What do I have due in \(.applicationName)",
            "What's \(\.$show) in \(.applicationName)",
            "What \(\.$show) in \(.applicationName)",
            "What's due \(\.$when) in \(.applicationName)",
            "What's due for \(\.$course) in \(.applicationName)",
        ], shortTitle: "What's Due", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: PlanDayIntent(), phrases: [
            "Plan my day in \(.applicationName)",
            "Plan today with \(.applicationName)",
            "Make my plan in \(.applicationName)",
            "Plan tonight until \(\.$until) in \(.applicationName)",
        ], shortTitle: "Plan My Day", systemImageName: "sun.horizon")
        AppShortcut(intent: GetPlanIntent(), phrases: [
            "What's on my plan in \(.applicationName)",
            "What's next on my plan in \(.applicationName)",
        ], shortTitle: "Today's Plan", systemImageName: "list.bullet.clipboard")
        AppShortcut(intent: GetCourseInfoIntent(), phrases: [
            "What's the \(\.$topic) policy in \(.applicationName)",
            "Check a course policy in \(.applicationName)",
            "What's the policy for \(\.$course) in \(.applicationName)",
            "Tell me about \(\.$course) in \(.applicationName)",
        ], shortTitle: "Course Info", systemImageName: "text.quote")
        AppShortcut(intent: CheckCoverageIntent(), phrases: [
            "Where is \(.applicationName) blind",
            "Check my coverage in \(.applicationName)",
            "Check \(\.$course) in \(.applicationName)",
        ], shortTitle: "Check Coverage", systemImageName: "eye")
        AppShortcut(intent: ReadDocumentIntent(), phrases: [
            "Read \(\.$source) with \(.applicationName)",
            "Read a document from \(\.$source) with \(.applicationName)",
            "Add a document to \(.applicationName)",
        ], shortTitle: "Read a Document", systemImageName: "doc.viewfinder")
        AppShortcut(intent: OpenCourseIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Show \(\.$target) in \(.applicationName)",
        ], shortTitle: "Open Course", systemImageName: "book.closed")
    }
}
