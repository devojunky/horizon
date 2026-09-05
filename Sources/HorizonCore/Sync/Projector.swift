import Foundation
import IngestKit

/// Writes obligations to Reminders. The only code path that creates, updates, or removes Horizon's reminders.
/// It works from a fresh fetch of the Horizon list handed in by `SyncCoordinator`, never from local state
/// (SPEC §4.4 idempotency), and only the device that created a row creates its reminder.
public actor ReminderProjector {
    private let store: HorizonStore
    private let reminders: any ReminderStore
    private let calendar: Calendar

    public struct Report: Sendable, Equatable {
        public var created = 0, updated = 0, repaired = 0, removed = 0, waiting = 0
    }

    public init(store: HorizonStore, reminders: any ReminderStore, calendar: Calendar = .current) {
        self.store = store; self.reminders = reminders; self.calendar = calendar
    }

    /// Returns the report plus the external IDs of reminders this device now knows about.
    func project(existing: [ReminderItem], currentDevice: String) async throws -> (Report, Set<String>) {
        var report = Report()
        var known = Set(existing.map(\.externalID))

        // Reminders Horizon created for items the user has since discarded in the app.
        for gone in try await store.deletedAwaitingRemoval() {
            if let id = gone.ekExternalID, existing.contains(where: { $0.externalID == id }) {
                try await reminders.remove(externalID: id)
                report.removed += 1
            }
            try await store.clearExternalID(id: gone.id)
        }

        let pending = try await store.pendingProjection()
        for obligation in pending {
            let draft = Self.draft(for: obligation)
            let match = existing.first { $0.externalID == obligation.ekExternalID } ?? existing.first { $0.obligationID == obligation.id }
            if let match {
                if match.externalID != obligation.ekExternalID { report.repaired += 1 }
                if Self.differs(match, draft, calendar: calendar) {
                    _ = try await reminders.update(externalID: match.externalID, with: draft)
                    report.updated += 1
                }
                try await store.markProjected(id: obligation.id, externalID: match.externalID, title: draft.title, due: draft.due, notes: obligation.notes)
            } else if obligation.ekExternalID == nil, obligation.createdOn.isEmpty || obligation.createdOn == currentDevice {
                let item = try await reminders.create(draft)
                known.insert(item.externalID)
                try await store.markProjected(id: obligation.id, externalID: item.externalID, title: draft.title, due: draft.due, notes: obligation.notes)
                report.created += 1
            } else {
                report.waiting += 1   // another device's row (its reminder will arrive through iCloud) or one it has since removed
            }
        }
        return (report, known)
    }

    public static func draft(for o: ObligationSnapshot) -> ReminderDraft {
        var lines: [String] = []
        if let points = o.pointsAtStake { lines.append("Worth \(points.formatted(.number.precision(.fractionLength(0...1))))% of the grade") }
        if let component = o.componentName { lines.append("Counts toward \(component)") }
        if o.platform != .syllabusOnly { lines.append("On \(platformName(o.platform))") }
        if let page = o.sourcePage { lines.append("From the document, page \(page + 1)") }
        if let notes = o.notes, !notes.isEmpty { lines.append(notes) }
        let priority = switch o.pointsAtStake ?? 0 { case 20...: 1; case 8..<20: 5; default: 0 }
        return ReminderDraft(title: o.reminderTitle, due: o.due, hasTime: o.dueHasTime, notes: lines.joined(separator: "\n"), url: o.link, priority: priority)
    }

    static func differs(_ item: ReminderItem, _ draft: ReminderDraft, calendar: Calendar) -> Bool {
        if item.title != draft.title || item.hasTime != draft.hasTime { return true }
        if ReminderDraft.userText(in: draft.notes) != ReminderDraft.userText(in: item.notes) { return true }
        let generated = (item.notes ?? "").components(separatedBy: "\n").filter { line in ReminderDraft.generatedPrefixes.contains { line.hasPrefix($0) } }
        if generated != draft.notes.components(separatedBy: "\n").filter({ line in ReminderDraft.generatedPrefixes.contains { line.hasPrefix($0) } }) { return true }
        switch (item.due, draft.due) {
        case (nil, nil): return false
        case (let a?, let b?): return draft.hasTime ? abs(a.timeIntervalSince(b)) > 60 : !calendar.isDate(a, inSameDayAs: b)
        default: return true
        }
    }

    static func platformName(_ p: Platform) -> String {
        switch p { case .lms: "the LMS"; case .webAssign: "WebAssign"; case .gradescope: "Gradescope"; case .myLab: "MyLab"; case .syllabusOnly: "" }
    }
}

/// Compares the store with the Horizon list and says what to change. Pure and idempotent: safe to run twice.
/// `seen` is the set of external IDs this device has observed in EventKit before; absence counts as deletion only for those.
public enum Reconciler {
    public static func changes(obligations: [ObligationSnapshot], reminders: [ReminderItem], seen: Set<String>, calendar: Calendar = .current) -> [ReconcileChange] {
        var changes: [ReconcileChange] = []
        let byExternal = Dictionary(obligations.filter { $0.ekExternalID != nil }.map { ($0.ekExternalID!, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(obligations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var present = Set<UUID>()

        for item in reminders {
            guard let obligation = byExternal[item.externalID] ?? item.obligationID.flatMap({ byID[$0] }) else {
                // No Horizon link: the user made it by hand, so import it. A Horizon link with no record here belongs to
                // another device whose records have not synced yet (or to a reinstall): leave it alone.
                if item.obligationID == nil { changes.append(.importUnattributed(item)) }
                continue
            }
            present.insert(obligation.id)
            if obligation.deletedAt != nil { continue }
            if obligation.ekExternalID != item.externalID { changes.append(.repairExternalID(obligation.id, item.externalID)) }
            if item.isCompleted != (obligation.completedAt != nil) { changes.append(.completion(obligation.id, item.isCompleted ? item.completionDate ?? Date() : nil)) }
            // A reminder that no longer says what we last wrote was edited by hand in Reminders.
            guard let projectedTitle = obligation.projectedTitle else { continue }
            let titleEdited = item.title != projectedTitle
            let dueEdited: Bool = switch (item.due, obligation.projectedDue) {
                case (nil, nil): false
                case (let a?, let b?): item.hasTime ? abs(a.timeIntervalSince(b)) > 60 : !calendar.isDate(a, inSameDayAs: b)
                default: true
            }
            let userNotes = ReminderDraft.userText(in: item.notes)
            let notesEdited = userNotes != (obligation.projectedNotes ?? "")   // against what we last wrote, not what the app holds now
            if titleEdited || dueEdited || notesEdited {
                changes.append(.userEdited(obligation.id, title: titleEdited ? Self.stripCourse(item.title, obligation) : nil,
                                           due: dueEdited ? item.due : nil, hasTime: item.hasTime, notes: notesEdited ? userNotes : nil))
            }
        }
        for obligation in obligations where obligation.deletedAt == nil && !present.contains(obligation.id) {
            if let id = obligation.ekExternalID, seen.contains(id) { changes.append(.deletedInReminders(obligation.id)) }
        }
        return changes
    }

    /// "Homework 3 · MA-UY 1124" → "Homework 3" when the course suffix is intact.
    static func stripCourse(_ title: String, _ o: ObligationSnapshot) -> String {
        guard let code = o.courseCode, title.hasSuffix(" · \(code)") else { return title }
        return String(title.dropLast(code.count + 3))
    }
}

/// Device-local memory of which reminders this device has seen in EventKit. Never synced: it is what lets "gone"
/// mean "deleted here" rather than "not arrived yet".
public protocol SeenReminderIDs: Sendable {
    func load() -> Set<String>
    func save(_ ids: Set<String>)
}

public struct InMemorySeenIDs: SeenReminderIDs {
    private let box = LockedBox()
    public init() {}
    public func load() -> Set<String> { box.get() }
    public func save(_ ids: Set<String>) { box.set(ids) }
    final class LockedBox: @unchecked Sendable {
        private var ids = Set<String>(); private let lock = NSLock()
        func get() -> Set<String> { lock.withLock { ids } }
        func set(_ new: Set<String>) { lock.withLock { ids = new } }
    }
}

public struct DefaultsSeenIDs: SeenReminderIDs {
    private let suite: String
    private let key = "seenReminderIDs"
    public init(suite: String = Identifiers.appGroup) { self.suite = suite }
    private var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }   // UserDefaults is thread-safe but not Sendable
    public func load() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    public func save(_ ids: Set<String>) { defaults.set(Array(ids), forKey: key) }
}

/// Foreground / EventKit-change entry point: reconcile, remove discarded, project. One run at a time; a request that
/// arrives mid-run makes it run once more, so nothing confirmed during a parse waits for the next foreground.
public actor SyncCoordinator {
    private let store: HorizonStore
    private let reminders: any ReminderStore
    private let projector: ReminderProjector
    private let seenIDs: any SeenReminderIDs
    private let deviceName: String
    private var inFlight: Task<ReminderProjector.Report, Error>?
    private var rerunRequested = false

    public init(store: HorizonStore, reminders: any ReminderStore, seen: any SeenReminderIDs = InMemorySeenIDs(), deviceName: String) {
        self.store = store; self.reminders = reminders; self.seenIDs = seen; self.deviceName = deviceName
        projector = ReminderProjector(store: store, reminders: reminders)
    }

    @discardableResult
    public func sync() async throws -> ReminderProjector.Report {
        if let running = inFlight {
            rerunRequested = true
            return try await running.value
        }
        let task = Task { try await self.run() }
        inFlight = task
        defer { inFlight = nil }
        var report = try await task.value
        if rerunRequested {
            rerunRequested = false
            report = try await run()
        }
        return report
    }

    private func run() async throws -> ReminderProjector.Report {
        var seen = seenIDs.load()
        if let items = try await reminders.fetchHorizonItems() {
            let obligations = try await store.obligations(includeDeleted: true)
            try await store.applyReconciliation(Reconciler.changes(obligations: obligations, reminders: items, seen: seen))
            seen.formUnion(items.map(\.externalID))
        }
        // A missing list is "nothing here yet" (never created, signed out, or deleted wholesale): no deletions, and
        // nothing is recreated behind the user's back.
        let existing = try await reminders.fetchHorizonItems() ?? []
        let (report, known) = try await projector.project(existing: existing, currentDevice: deviceName)
        seen.formUnion(known)
        seenIDs.save(seen)
        return report
    }
}
