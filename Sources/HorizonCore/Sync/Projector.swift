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
        /// `waiting`: rows whose reminder is another device's to write, or that wait for the list to be back.
        public var created = 0, updated = 0, repaired = 0, removed = 0, waiting = 0
        /// Checks made in the app and written to their reminders.
        public var checked = 0
        /// The Horizon list this device wrote to is not in Reminders (deleted, or its account signed out). Nothing is
        /// written until the user asks for it back (`SyncCoordinator.restoreList`); the app says so.
        public var listGone = false
    }

    public init(store: HorizonStore, reminders: any ReminderStore, calendar: Calendar = .current) {
        self.store = store; self.reminders = reminders; self.calendar = calendar
    }

    /// Returns the report plus the external IDs of reminders this device now knows about. `listGone`: the list this
    /// device wrote to has gone, and nothing may be created (the first create would make a new list with only that
    /// item in it, and the old items' absence from it would then read as the user deleting every one of them).
    func project(existing: [ReminderItem], currentDevice: String, listGone: Bool = false) async throws -> (Report, Set<String>) {
        var report = Report()
        report.listGone = listGone
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
            } else if !listGone, obligation.ekExternalID == nil, obligation.createdOn.isEmpty || obligation.createdOn == currentDevice {
                let item = try await reminders.create(draft)
                known.insert(item.externalID)
                try await store.markProjected(id: obligation.id, externalID: item.externalID, title: draft.title, due: draft.due, notes: obligation.notes)
                report.created += 1
            } else {
                report.waiting += 1   // another device's row (its reminder will arrive through iCloud) or one it has since removed
            }
        }

        // The user's checks made in the app. Reminders owns completion, so each is written to its reminder and only
        // then settled; an item with no reminder (in review, undated, another device's) keeps its mark in the store.
        for obligation in try await store.pendingCompletions() {
            guard let externalID = obligation.ekExternalID, known.contains(externalID) else { continue }
            guard try await reminders.setCompleted(externalID: externalID, obligation.completedAt != nil, at: obligation.completedAt) else { continue }
            try await store.completionProjected(id: obligation.id)
            report.checked += 1
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
            // Reminders owns completion, except while the user's own check in the app is on its way there (the projector writes it next).
            if item.isCompleted != (obligation.completedAt != nil), !obligation.completionPending { changes.append(.completion(obligation.id, item.isCompleted ? item.completionDate ?? Date() : nil)) }
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

    /// Whether the Horizon list found now is a new list under the old name (deleted and made again: by Recreate List, on
    /// another device, or by hand) rather than the one this device wrote to. Its identity says so when this device
    /// recorded it; before it did (a device that has not synced since this was added), a list holding none of the
    /// reminders this device wrote to it is a new one. A list with the same identity missing some of them is the same
    /// list with those reminders deleted, and deletion is intent.
    public static func listWasReplaced(recorded: String?, current: HorizonList, obligations: [ObligationSnapshot], seen: Set<String>) -> Bool {
        if let recorded { return recorded != current.id }
        let written = obligations.filter { $0.deletedAt == nil }.compactMap(\.ekExternalID).filter(seen.contains)
        let present = Set(current.items.map(\.externalID))
        return !written.isEmpty && !written.contains(where: present.contains)
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
    /// The identity of the Horizon list those reminders were seen in (`HorizonList.id`), nil until one was recorded.
    func loadListID() -> String?
    func saveListID(_ id: String?)
}

public struct InMemorySeenIDs: SeenReminderIDs {
    private let box = LockedBox()
    public init() {}
    public func load() -> Set<String> { box.get() }
    public func save(_ ids: Set<String>) { box.set(ids) }
    public func loadListID() -> String? { box.getList() }
    public func saveListID(_ id: String?) { box.setList(id) }
    final class LockedBox: @unchecked Sendable {
        private var ids = Set<String>(); private var list: String?; private let lock = NSLock()
        func get() -> Set<String> { lock.withLock { ids } }
        func set(_ new: Set<String>) { lock.withLock { ids = new } }
        func getList() -> String? { lock.withLock { list } }
        func setList(_ new: String?) { lock.withLock { list = new } }
    }
}

public struct DefaultsSeenIDs: SeenReminderIDs {
    private let suite: String
    private let key = "seenReminderIDs"
    private let listKey = "horizonListID"
    public init(suite: String = Identifiers.appGroup) { self.suite = suite }
    private var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }   // UserDefaults is thread-safe but not Sendable
    public func load() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    public func save(_ ids: Set<String>) { defaults.set(Array(ids), forKey: key) }
    public func loadListID() -> String? { defaults.string(forKey: listKey) }
    public func saveListID(_ id: String?) { defaults.set(id, forKey: listKey) }
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
        return try await exclusively { try await self.run() }
    }

    /// The user's Recreate List: the Horizon list is made again and every live item whose reminder went with the old
    /// one is written to it afresh (a checked one checked). It is a sync of its own, one at a time with the others: a
    /// sync under way finishes against the list as it was, and one asked for meanwhile (the new list's own change
    /// notification) waits, so nothing else can make a second list or meet the new, empty one while the rows still name
    /// reminders that are gone. Returns the list as it is afterwards.
    @discardableResult
    public func restoreList() async throws -> HorizonList? {
        while let running = inFlight { _ = try? await running.value }
        _ = try await exclusively { try await self.restore() }
        return try await reminders.fetchHorizonList()
    }

    /// Runs `work` as the one sync in flight; a sync asked for meanwhile waits on it, and runs once more after it.
    private func exclusively(_ work: @escaping @Sendable () async throws -> ReminderProjector.Report) async throws -> ReminderProjector.Report {
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        var report = try await task.value
        if rerunRequested {
            rerunRequested = false
            report = try await run()
        }
        return report
    }

    /// Rows first, then the list: the rows whose reminders went with the old list forget them before any list exists.
    private func restore() async throws -> ReminderProjector.Report {
        let current = try await reminders.fetchHorizonList()
        _ = try await store.forgetReminders(except: Set(current?.items.map(\.externalID) ?? []))
        try await reminders.ensureHorizonList()
        return try await run()
    }

    private func run() async throws -> ReminderProjector.Report {
        var seen = seenIDs.load()
        if let list = try await reminders.fetchHorizonList() {
            if seenIDs.loadListID() != list.id {
                // A new list under the old name, or the first one this device records. For a new one, what this device
                // wrote to the old list is written to it afresh rather than read as the user deleting every item.
                if Reconciler.listWasReplaced(recorded: seenIDs.loadListID(), current: list, obligations: try await store.obligations(), seen: seen) {
                    _ = try await store.forgetReminders(except: Set(list.items.map(\.externalID)))
                }
                seenIDs.saveListID(list.id)
            }
            let obligations = try await store.obligations(includeDeleted: true)
            try await store.applyReconciliation(Reconciler.changes(obligations: obligations, reminders: list.items, seen: seen))
            seen.formUnion(list.items.map(\.externalID))
        }
        // A missing list deletes nothing. One this device wrote to (deleted wholesale, or its account signed out) is not
        // made again behind the user's back either: nothing is written until the user asks for it back, and the report
        // says so. A list that never existed is made with the first item, as always.
        let list = try await reminders.fetchHorizonList()
        var gone = false
        if list == nil { gone = try await store.obligations().contains { $0.ekExternalID.map(seen.contains) ?? false } }
        let (report, known) = try await projector.project(existing: list?.items ?? [], currentDevice: deviceName, listGone: gone)
        if list == nil, report.created > 0, let made = try await reminders.fetchHorizonList() { seenIDs.saveListID(made.id) }   // the list the first item made
        seen.formUnion(known)
        seenIDs.save(seen)
        return report
    }
}
