import Foundation
import EventKit

/// One reminder in the Horizon list, as seen from EventKit.
public struct ReminderItem: Sendable, Equatable, Identifiable {
    /// `calendarItemExternalIdentifier`: stable for the same item across devices.
    public var externalID: String
    public var title: String
    public var due: Date?
    public var hasTime: Bool
    public var isCompleted: Bool
    public var completionDate: Date?
    public var notes: String?
    public var url: URL?
    public var id: String { externalID }
    public var obligationID: UUID? { Identifiers.obligationID(from: url) }

    public init(externalID: String, title: String, due: Date?, hasTime: Bool, isCompleted: Bool = false, completionDate: Date? = nil, notes: String? = nil, url: URL? = nil) {
        self.externalID = externalID; self.title = title; self.due = due; self.hasTime = hasTime; self.isCompleted = isCompleted
        self.completionDate = completionDate; self.notes = notes; self.url = url
    }
}

/// What the projector writes.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var due: Date?
    public var hasTime: Bool
    /// Horizon's own lines. Text the user typed into the reminder is preserved around them on update.
    public var notes: String
    public var url: URL
    /// 1 = high … 9 = low, 0 = none. Points at stake drive it.
    public var priority: Int
    public init(title: String, due: Date?, hasTime: Bool, notes: String, url: URL, priority: Int) {
        self.title = title; self.due = due; self.hasTime = hasTime; self.notes = notes; self.url = url; self.priority = priority
    }

    /// Lines Horizon generates; anything else in a reminder's notes belongs to the user.
    public static let generatedPrefixes = ["Worth ", "Counts toward ", "On ", "From the document"]

    public static func userText(in notes: String?) -> String {
        (notes ?? "").components(separatedBy: "\n").filter { line in !generatedPrefixes.contains { line.hasPrefix($0) } && !line.isEmpty }.joined(separator: "\n")
    }
}

/// The only surface through which Horizon touches Reminders. `EventKitReminderStore` is the real one; tests use a fake.
public protocol ReminderStore: Sendable {
    func requestAccess() async throws -> Bool
    /// Every item in the Horizon list, re-fetched on every call: never derive "does a reminder exist" from local state.
    /// Nil when the list itself does not exist (never created, or deleted by the user), which is not the same as empty.
    func fetchHorizonItems() async throws -> [ReminderItem]?
    func create(_ draft: ReminderDraft) async throws -> ReminderItem
    func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem?
    /// Checks the reminder off, or back on: the one thing about completion Horizon ever writes, and only on the
    /// user's own check in the app. False when the reminder is not there.
    func setCompleted(externalID: String, _ completed: Bool, at date: Date?) async throws -> Bool
    func remove(externalID: String) async throws
}

/// Result of comparing the store with Reminders (SPEC §4.4 reconciliation). Pure data; `HorizonStore.applyReconciliation` acts on it.
public enum ReconcileChange: Sendable, Equatable {
    /// A reminder in the Horizon list with no obligation: the user made it by hand. Import; never delete.
    case importUnattributed(ReminderItem)
    /// An obligation whose reminder this device has seen before and is now gone: the user deleted it. Soft-delete, never recreate.
    case deletedInReminders(UUID)
    /// Completion state differs: EventKit wins, unless the user's own check in the app is still on its way there.
    case completion(UUID, Date?)
    /// The user changed the title, due date, or notes in Reminders: adopt it and mark the field as overridden.
    case userEdited(UUID, title: String?, due: Date?, hasTime: Bool, notes: String?)
    /// A reminder matched by its deep link before its external identifier had synced.
    case repairExternalID(UUID, String)
}

public final class EventKitReminderStore: ReminderStore, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    private var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    private func existingList() -> EKCalendar? {
        store.calendars(for: .reminder).first { $0.title == Identifiers.remindersListTitle }
    }

    /// The "Horizon" list, created on first write in the default reminders source (iCloud when the user has it).
    private func listForWriting() throws -> EKCalendar {
        if let existing = existingList() { return existing }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Identifiers.remindersListTitle
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local }) else { throw ReminderStoreError.noSource }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }

    public func fetchHorizonItems() async throws -> [ReminderItem]? {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        guard let list = existingList() else { return nil }
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.item))   // convert before crossing the boundary
            }
        }
    }

    public func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try listForWriting()
        Self.write(draft, to: reminder, keeping: nil)
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem? {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        guard let reminder = store.calendarItems(withExternalIdentifier: externalID).compactMap({ $0 as? EKReminder }).first else { return nil }
        Self.write(draft, to: reminder, keeping: reminder.notes)
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func setCompleted(externalID: String, _ completed: Bool, at date: Date?) async throws -> Bool {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        guard let reminder = store.calendarItems(withExternalIdentifier: externalID).compactMap({ $0 as? EKReminder }).first else { return false }
        if reminder.isCompleted != completed {
            reminder.isCompleted = completed                          // sets or clears the completion date
            if completed, let date { reminder.completionDate = date }  // when it was checked here, not when the sync ran
            try store.save(reminder, commit: true)
        }
        return true
    }

    public func remove(externalID: String) async throws {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        guard let reminder = store.calendarItems(withExternalIdentifier: externalID).compactMap({ $0 as? EKReminder }).first else { return }
        try store.remove(reminder, commit: true)
    }

    private static func write(_ draft: ReminderDraft, to reminder: EKReminder, keeping existingNotes: String?) {
        reminder.title = draft.title
        let userText = ReminderDraft.userText(in: existingNotes)
        reminder.notes = userText.isEmpty ? draft.notes : draft.notes + "\n" + userText
        reminder.url = draft.url
        reminder.priority = draft.priority
        if let due = draft.due {
            let units: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
        } else {
            reminder.dueDateComponents = nil
        }
    }

    private static func item(_ r: EKReminder) -> ReminderItem {
        let components = r.dueDateComponents
        let hasTime = components?.hour != nil
        var due: Date?
        if var c = components {
            if !hasTime { c.hour = 23; c.minute = 59 }
            due = Calendar.current.date(from: c)
        }
        return ReminderItem(externalID: r.calendarItemExternalIdentifier, title: r.title ?? "", due: due, hasTime: hasTime,
                            isCompleted: r.isCompleted, completionDate: r.completionDate, notes: r.notes, url: r.url)
    }
}

public enum ReminderStoreError: Error, LocalizedError {
    case noSource, accessDenied
    public var errorDescription: String? {
        switch self {
        case .noSource: "No Reminders account to create the Horizon list in"
        case .accessDenied: "Reminders access was not granted; enable it in Settings"
        }
    }
}
