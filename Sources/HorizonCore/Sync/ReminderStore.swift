import Foundation
import EventKit
import IngestKit

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

/// The Horizon list as fetched: which list it is, and every item in it.
public struct HorizonList: Sendable, Equatable {
    /// The list's `calendarIdentifier` on this device. A list deleted and made again (by Recreate, on another device,
    /// or by hand) is a different list under the same name, and this is how the sync tells the two apart.
    public var id: String
    public var items: [ReminderItem]
    public init(id: String, items: [ReminderItem]) { self.id = id; self.items = items }
}

/// What the projector writes.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var due: Date?
    public var hasTime: Bool
    /// Horizon's lines (`ReminderProjector.draft(for:)`: what the item is worth, its grade row, its site, its page), then
    /// the user's text as the app holds it.
    public var notes: String
    public var url: URL
    /// 1 = high … 9 = low, 0 = none. Points at stake drive it.
    public var priority: Int
    public init(title: String, due: Date?, hasTime: Bool, notes: String, url: URL, priority: Int) {
        self.title = title; self.due = due; self.hasTime = hasTime; self.notes = notes; self.url = url; self.priority = priority
    }

    /// What a reminder's notes become when this draft is written over the ones it holds (`existing`): the draft's, whole,
    /// and nothing of the old. The draft carries the user's text as the app holds it, which the reconcile at the start of
    /// the same sync brought up to date with whatever was typed in Reminders; keeping the old text as well wrote the
    /// user's words twice, the next reconcile took the doubled text in as theirs, and it doubled again on every write.
    /// Both stores write through this, so the tests' fake writes what EventKit does.
    public func notes(over existing: String?) -> String? { notes.isEmpty ? nil : notes }
}

/// Horizon's lines in a reminder's notes, told from the user's text. Horizon writes its lines first, each at most once and
/// in one order (`ReminderProjector.draft(for:)`), and the user's text under them; the user may type anywhere.
extension ReminderDraft {
    /// Horizon's lines, in the order it writes them.
    enum HorizonLine: Int, Comparable {
        case worth, countsToward, site, page
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Which of Horizon's lines `line` reads as, matched whole against what the projector writes: "Worth 1.5% of the
    /// grade" (the figure in the device's own number format), "Counts toward" and a grade row, "On" and a site Horizon
    /// names, "From the document, page 3". A line of the user's that only begins the same way ("On Canvas, as a PDF",
    /// "Worth asking about in office hours") is none of them. A grade row can be any words, so whose a "Counts toward"
    /// line is depends on where it stands (`userText`).
    static func horizonLine(_ line: String) -> HorizonLine? {
        if line.wholeMatch(of: /Worth \d+(?:[^\d\s%]\d+)?% of the grade/) != nil { return .worth }
        if line.hasPrefix("Counts toward "), !line.dropFirst(14).allSatisfy(\.isWhitespace) { return .countsToward }
        if Platform.allCases.contains(where: { $0 != .syllabusOnly && line == "On \(ReminderProjector.platformName($0))" }) { return .site }
        if line.wholeMatch(of: /From the document, page \d+/) != nil { return .page }
        return nil
    }

    /// The user's text in notes Horizon wrote: what is left once its lines are taken out. Horizon writes each of them
    /// once, so only the first line reading as each is its own (a second "On WebAssign" is the user's). A "Counts toward"
    /// line is Horizon's when it names the item's grade row (`component`), else when it stands where Horizon writes one,
    /// opening the notes or under its "Worth" line (the row the item was in when its reminder was last written); any
    /// other is the user's. Blank lines inside the user's text stay, those around it go.
    public static func userText(in notes: String?, component: String?) -> String {
        let lines = (notes ?? "").components(separatedBy: "\n")
        let ownRow = component.map { "Counts toward \($0)" }
        let counts = lines.firstIndex { $0 == ownRow }
            ?? lines.indices.first { horizonLine(lines[$0]) == .countsToward && ($0 == 0 || horizonLine(lines[$0 - 1]) == .worth) }
        var taken: Set<HorizonLine> = []
        var user: [String] = []
        for (i, line) in lines.enumerated() {
            if let kind = horizonLine(line), kind != .countsToward || i == counts, taken.insert(kind).inserted { continue }
            user.append(line)
        }
        return trimmingBlankLines(user).joined(separator: "\n")
    }

    /// Whether a reminder's notes still say what Horizon last wrote there: its own lines, in its order, then exactly the
    /// user's text it wrote (`written`, the item's `projectedNotes`). Its own lines may read differently by now (the
    /// points worked out again, another page); the user's text may not. Notes that hold as written were not edited in
    /// Reminders, so a line the user typed in the app that reads like one of Horizon's is never taken for it.
    static func holdsAsWritten(_ notes: String?, userText written: String?) -> Bool {
        var lines = trimmingBlankLines(notes)
        let user = trimmingBlankLines(written)
        guard lines.count >= user.count, lines.suffix(user.count).elementsEqual(user) else { return false }
        lines.removeLast(user.count)
        var last: HorizonLine?
        for line in lines where !isBlank(line) {
            guard let kind = horizonLine(line), last.map({ $0 < kind }) ?? true else { return false }
            last = kind
        }
        return true
    }

    /// The lines of `text` without the blank ones at either end.
    static func trimmingBlankLines(_ text: String?) -> [String] { trimmingBlankLines((text ?? "").components(separatedBy: "\n")) }

    static func trimmingBlankLines(_ lines: [String]) -> [String] { Array(lines.drop(while: isBlank).reversed().drop(while: isBlank).reversed()) }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }
}

/// The only surface through which Horizon touches Reminders. `EventKitReminderStore` is the real one; tests use a fake.
public protocol ReminderStore: Sendable {
    func requestAccess() async throws -> Bool
    /// The Horizon list and every item in it, re-fetched on every call: never derive "does a reminder exist" from local
    /// state. Nil when the list itself does not exist (never created, deleted by the user, or its account signed out),
    /// which is not the same as empty.
    func fetchHorizonList() async throws -> HorizonList?
    /// Makes the Horizon list if there is none: only ever on the user's word (Recreate List), or with the first item.
    func ensureHorizonList() async throws
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
    /// `reminderTitle`: the reminder's title as it reads, course and all, which is what Reminders now says.
    case userEdited(UUID, title: String?, due: Date?, hasTime: Bool, notes: String?, reminderTitle: String)
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

    public func fetchHorizonList() async throws -> HorizonList? {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        guard let list = existingList() else { return nil }
        let items: [ReminderItem] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.item))   // convert before crossing the boundary
            }
        }
        return HorizonList(id: list.calendarIdentifier, items: items)
    }

    public func ensureHorizonList() async throws {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        _ = try listForWriting()
    }

    public func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try listForWriting()
        Self.write(draft, to: reminder)
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem? {
        guard hasAccess else { throw ReminderStoreError.accessDenied }
        guard let reminder = store.calendarItems(withExternalIdentifier: externalID).compactMap({ $0 as? EKReminder }).first else { return nil }
        Self.write(draft, to: reminder)
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

    private static func write(_ draft: ReminderDraft, to reminder: EKReminder) {
        reminder.title = draft.title
        reminder.notes = draft.notes(over: reminder.notes)
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
