import Foundation
import SwiftData
import IngestKit

/// All reads and writes to the model store. One actor, so field ownership and soft deletes are enforced in one place.
@ModelActor
public actor HorizonStore {
    public static let tombstoneAge: TimeInterval = 180 * 86400

    // MARK: Ingest

    /// Folds an `IngestResult` into the store (SPEC §4.4 field ownership). Existing obligations are matched by title
    /// and due day; document-owned fields update unless the user overrode them, and any change to an item the user may
    /// be relying on goes back to review with a `changeNote` rather than moving silently.
    public func ingest(_ result: IngestResult, documentID: UUID, calendar: Calendar = .current) throws -> IngestSummary {
        var summary = IngestSummary(warnings: result.warnings)
        guard let document = try fetchDocument(id: documentID) else { throw StoreError.missingDocument }
        let course = try upsertCourse(from: result)
        summary.courseCode = course?.code
        document.course = course
        document.status = .parsed
        document.failure = nil
        document.ingestedAt = Date()
        document.pageCount = result.document.pageCount
        document.route = result.route.rawValue
        document.inputTokens = result.usage.inputTokens
        document.outputTokens = result.usage.outputTokens
        document.durationMs = result.usage.durationMs
        document.warnings = result.warnings
        course?.lastIngested = Date()

        if let course {
            for parsed in result.policies where !(course.policies ?? []).contains(where: { Normalize.key($0.text) == Normalize.key(parsed.text) }) {
                let policy = Policy(kind: parsed.kind, text: parsed.text, verbatim: parsed.verbatim)
                policy.course = course
                modelContext.insert(policy)
            }
        }

        // Candidates: this course's rows, or the course-less rows when the document names no course. Each is matched once.
        var pool = try course.map { $0.obligations ?? [] } ?? fetchObligations().filter { $0.course == nil }
        for parsed in result.obligations {
            if let index = Self.match(parsed, in: pool, calendar: calendar) {
                let existing = pool.remove(at: index)
                if existing.deletedAt != nil { summary.unchanged += 1; continue }   // deleted in Reminders stays deleted
                let changes = apply(parsed, to: existing, document: document, calendar: calendar)
                if changes.isEmpty { summary.unchanged += 1 } else { summary.updated += 1 }
                if existing.state == .pendingReview { summary.pendingReview += 1 }
            } else {
                let item = Obligation(title: parsed.title)
                item.course = course
                item.sourceDocument = document
                item.createdOn = document.deviceName
                _ = apply(parsed, to: item, document: document, calendar: calendar, isNew: true)
                modelContext.insert(item)
                summary.created += 1
                if item.state == .pendingReview { summary.pendingReview += 1 }
            }
        }
        try modelContext.save()
        return summary
    }

    /// Same course when the code matches; a title that reads the same only when neither side has a code; else new.
    private func upsertCourse(from result: IngestResult) throws -> Course? {
        let parsed = result.course
        let code = parsed?.code.map(Normalize.collapseWhitespace) ?? ""
        let title = parsed?.title.map(Normalize.collapseWhitespace) ?? ""
        guard !code.isEmpty || !title.isEmpty else { return nil }
        let all = try modelContext.fetch(FetchDescriptor<Course>())
        let course = all.first { !code.isEmpty && Normalize.key($0.code) == Normalize.key(code) }
            ?? all.first { (code.isEmpty || $0.code.isEmpty) && !title.isEmpty && Normalize.similarity($0.title, title) >= 0.6 }
            ?? { let c = Course(code: code, title: title); modelContext.insert(c); return c }()
        if course.code.isEmpty { course.code = code }
        if course.title.isEmpty || (!title.isEmpty && Normalize.key(course.title) != Normalize.key(title) && course.title.count < title.count) { course.title = title }
        if let p = parsed {
            course.instructor = p.instructor ?? course.instructor
            course.term = p.term ?? course.term
            course.termStart = p.termStart ?? course.termStart
            course.termEnd = p.termEnd ?? course.termEnd
            course.room = p.room ?? course.room
            if !p.meetings.isEmpty { course.meetings = p.meetings }
        }
        if !result.gradeComponents.isEmpty {
            course.gradeComponents = result.gradeComponents.map { GradeComponent(name: $0.name, weight: $0.weight, expectedCount: $0.expectedCount, cadence: $0.cadence, dropLowest: $0.dropLowest) }
        }
        if !result.noClassDates.isEmpty {
            course.noClassDates = result.noClassDates.map { ClosedDateRange(start: $0.start, end: $0.end ?? $0.start, label: $0.dateAsWritten) }
        }
        for platform in Set(result.obligations.map(\.platform.rawValue)) where !course.platforms.contains(platform) { course.platforms.append(platform) }
        return course
    }

    /// Index of the row a parsed item is: the same title on the same day; else the same title when exactly one side is
    /// undated (a TBD resolving, or a date withdrawn); else a similar title on the same day; else the one row with the
    /// same title (its date moved: the re-ingest diff case).
    static func match(_ parsed: ParsedObligation, in pool: [Obligation], calendar: Calendar) -> Int? {
        let key = Normalize.key(parsed.title)
        func sameDay(_ o: Obligation) -> Bool {
            switch (o.due, parsed.due) {
            case (nil, nil): true
            case (let a?, let b?): calendar.isDate(a, inSameDayAs: b)
            default: false
            }
        }
        let exact = pool.indices.filter { Normalize.key(pool[$0].title) == key }
        if let i = exact.first(where: { sameDay(pool[$0]) }) { return i }
        if let i = exact.first(where: { (pool[$0].due == nil) != (parsed.due == nil) }) { return i }
        if let i = pool.indices.first(where: { sameDay(pool[$0]) && Normalize.similarity(pool[$0].title, parsed.title) >= 0.5 }) { return i }
        return exact.count == 1 ? exact[0] : nil
    }

    /// Writes document-owned fields, honouring overrides. Returns the names of fields that changed. A document that
    /// disagrees with a hand edit does not win, but the disagreement is recorded so the row can show it.
    private func apply(_ parsed: ParsedObligation, to item: Obligation, document: SourceDocument, calendar: Calendar, isNew: Bool = false) -> [String] {
        var changed: [String] = []
        var conflicts: [String] = []
        let overrides = Set(item.userOverrides)

        if item.title != parsed.title {
            if overrides.contains(.title) { conflicts.append("title “\(parsed.title)”") }
            else { if !isNew { changed.append("title \(item.title) → \(parsed.title)") }; item.title = parsed.title }
        }
        let sameInstant: Bool = switch (item.due, parsed.due) {
            case (nil, nil): true
            case (let a?, let b?): calendar.isDate(a, inSameDayAs: b) && (!(item.dueHasTime && parsed.dueHasTime) || abs(a.timeIntervalSince(b)) < 60)
            default: false
        }
        if !sameInstant || item.dueHasTime != parsed.dueHasTime {
            if overrides.contains(.due) {
                conflicts.append("due \(parsed.due.map(Self.short) ?? "TBD")")
                if let new = parsed.due { item.conflictingDate = new }
            } else {
                // A date the user may rely on moving or vanishing is a diff to confirm; a TBD gaining its date is not.
                if !isNew, let old = item.due {
                    changed.append("due \(Self.short(old)) → \(parsed.due.map(Self.short) ?? "TBD")")
                    if let new = parsed.due, !calendar.isDate(old, inSameDayAs: new) { item.conflictingDate = old }
                }
                item.due = parsed.due; item.dueHasTime = parsed.dueHasTime
            }
        }
        if item.platform != parsed.platform, parsed.platform != .syllabusOnly {
            if overrides.contains(.platform) { conflicts.append("platform \(parsed.platform.rawValue)") }
            else { if !isNew { changed.append("platform → \(parsed.platform.rawValue)") }; item.platform = parsed.platform }
        }
        if let name = parsed.componentName, item.componentName != name, !overrides.contains(.componentName) { item.componentName = name }
        item.pointsAtStake = parsed.pointsAtStake ?? item.pointsAtStake
        item.confidence = parsed.confidence
        item.flags = parsed.flags.map(\.rawValue)
        item.dateAsWritten = parsed.dateAsWritten
        item.sourcePage = parsed.sourcePage
        item.sourceDocument = document
        item.updatedAt = Date()
        if isNew {
            item.state = switch parsed.status { case .ready: .readyToProject; case .needsReview: .pendingReview; case .awaitingDate: .awaitingDate }
        } else if !changed.isEmpty {
            item.changeNote = changed.joined(separator: "; ")
            item.state = .pendingReview
        } else if item.state == .awaitingDate, item.due != nil {
            item.state = parsed.status == .ready ? .readyToProject : .pendingReview
        }
        if !conflicts.isEmpty {
            item.changeNote = "Document now says " + conflicts.joined(separator: ", ") + "; your edit was kept"
        }
        return changed
    }

    private static func short(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Documents

    /// Records a document by content hash. The same file again is the same record; a failed one is queued again.
    public func enqueueDocument(filename: String, sha256: String, kind: String, deviceName: String) throws -> DocumentSnapshot {
        if let existing = try fetchDocuments().first(where: { $0.sha256 == sha256 }) {
            if existing.status == .failed { existing.status = .queued; existing.failure = nil; try modelContext.save() }
            return snapshot(existing)
        }
        let doc = SourceDocument(filename: filename, sha256: sha256, kind: kind, deviceName: deviceName)
        modelContext.insert(doc)
        try modelContext.save()
        return snapshot(doc)
    }

    public func queuedDocuments() throws -> [DocumentSnapshot] {
        try fetchDocuments().filter { $0.status == .queued || $0.status == .awaitingCloudParse }.map(snapshot)
    }

    public func documents() throws -> [DocumentSnapshot] { try fetchDocuments().map(snapshot) }

    public func markDocument(id: UUID, status: DocumentStatus, failure: String? = nil) throws {
        guard let doc = try fetchDocument(id: id) else { return }
        doc.status = status; doc.failure = failure
        try modelContext.save()
    }

    private func fetchDocuments() throws -> [SourceDocument] {
        try modelContext.fetch(FetchDescriptor<SourceDocument>(sortBy: [SortDescriptor(\.queuedAt, order: .reverse)]))
    }

    private func fetchDocument(id: UUID) throws -> SourceDocument? {
        try modelContext.fetch(FetchDescriptor<SourceDocument>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Obligations

    public func obligations(includeDeleted: Bool = false) throws -> [ObligationSnapshot] {
        try fetchObligations().filter { includeDeleted || $0.deletedAt == nil }.map(snapshot)
    }

    public func reviewQueue() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt == nil && $0.state == .pendingReview }.map(snapshot)
    }

    /// Items to write to Reminders: confirmed or confident, not deleted, not yet projected in their current form.
    public func pendingProjection() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt == nil && $0.state == .readyToProject }.map(snapshot)
    }

    /// Discarded items that still have a reminder Horizon created.
    public func deletedAwaitingRemoval() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt != nil && $0.ekExternalID != nil && $0.origin != .reminders }.map(snapshot)
    }

    public func clearExternalID(id: UUID) throws {
        guard let item = try fetchObligation(id: id) else { return }
        item.ekExternalID = nil
        try modelContext.save()
    }

    public func markProjected(id: UUID, externalID: String?, title: String, due: Date?, notes: String?) throws {
        guard let item = try fetchObligation(id: id) else { return }
        if let externalID { item.ekExternalID = externalID }
        item.projectedTitle = title
        item.projectedDue = due
        item.projectedNotes = notes
        item.state = .projected
        item.updatedAt = Date()
        try modelContext.save()
    }

    /// The review queue's one-tap confirm, also the manual editor's save: hand edits become overrides.
    public func confirm(id: UUID, edits: ObligationEdits = ObligationEdits()) throws {
        guard let item = try fetchObligation(id: id) else { return }
        applyEdits(edits, to: item)
        item.changeNote = nil
        item.conflictingDate = nil
        item.state = item.due == nil ? .awaitingDate : .readyToProject
        item.updatedAt = Date()
        try modelContext.save()
    }

    public func addManual(title: String, due: Date?, dueHasTime: Bool, courseID: UUID?, componentName: String?, notes: String?, deviceName: String) throws -> ObligationSnapshot {
        let item = Obligation(title: title)
        item.origin = .manual
        item.createdOn = deviceName
        item.confidence = 1
        item.due = due; item.dueHasTime = dueHasTime
        item.componentName = componentName
        item.notes = notes
        item.userOverrides = [.title, .due, .componentName, .notes]
        item.course = try courseID.flatMap { try fetchCourse(id: $0) }
        item.state = due == nil ? .awaitingDate : .readyToProject
        modelContext.insert(item)
        try modelContext.save()
        return snapshot(item)
    }

    public func softDelete(id: UUID) throws {
        guard let item = try fetchObligation(id: id) else { return }
        item.deletedAt = Date()
        item.updatedAt = Date()
        try modelContext.save()
    }

    /// Hard-deletes tombstones older than `tombstoneAge`. Never runs on a record that has not had time to sync.
    @discardableResult
    public func purgeTombstones(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.tombstoneAge)
        let dead = try fetchObligations().filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        dead.forEach(modelContext.delete)
        try modelContext.save()
        return dead.count
    }

    private func applyEdits(_ edits: ObligationEdits, to item: Obligation) {
        if let title = edits.title, title != item.title { item.title = title; item.userOverrides.appendIfMissing(.title) }
        if let due = edits.due { item.due = due; item.userOverrides.appendIfMissing(.due) }
        if let hasTime = edits.dueHasTime { item.dueHasTime = hasTime; item.userOverrides.appendIfMissing(.due) }
        if let platform = edits.platform, platform != item.platform { item.platform = platform; item.userOverrides.appendIfMissing(.platform) }
        if let component = edits.componentName { item.componentName = component; item.userOverrides.appendIfMissing(.componentName) }
        if let notes = edits.notes { item.notes = notes; item.userOverrides.appendIfMissing(.notes) }
        if let courseID = edits.courseID { item.course = try? courseID.flatMap { try fetchCourse(id: $0) } }
    }

    // MARK: Reconciliation (SPEC §4.4)

    public func applyReconciliation(_ changes: [ReconcileChange]) throws {
        for change in changes {
            switch change {
            case .importUnattributed(let item):
                let ob = Obligation(title: item.title)
                ob.origin = .reminders
                ob.confidence = 1
                ob.state = .projected
                ob.ekExternalID = item.externalID
                ob.due = item.due; ob.dueHasTime = item.hasTime
                ob.projectedTitle = item.title; ob.projectedDue = item.due
                ob.completedAt = item.completionDate
                ob.notes = ReminderDraft.userText(in: item.notes).nilIfEmpty
                ob.projectedNotes = ob.notes
                modelContext.insert(ob)
            case .deletedInReminders(let id):
                if let ob = try fetchObligation(id: id) { ob.deletedAt = Date(); ob.ekExternalID = nil; ob.updatedAt = Date() }
            case .completion(let id, let date):
                if let ob = try fetchObligation(id: id) { ob.completedAt = date }
            case .userEdited(let id, let title, let due, let hasTime, let notes):
                if let ob = try fetchObligation(id: id) {
                    if let title { ob.title = title; ob.projectedTitle = title; ob.userOverrides.appendIfMissing(.title) }
                    if let due { ob.due = due; ob.dueHasTime = hasTime; ob.projectedDue = due; ob.userOverrides.appendIfMissing(.due) }
                    if let notes { ob.notes = notes.nilIfEmpty; ob.projectedNotes = notes.nilIfEmpty; ob.userOverrides.appendIfMissing(.notes) }
                    ob.updatedAt = Date()
                }
            case .repairExternalID(let id, let externalID):
                if let ob = try fetchObligation(id: id) { ob.ekExternalID = externalID }
            }
        }
        try modelContext.save()
    }

    // MARK: Courses

    public func courses() throws -> [CourseSnapshot] {
        try modelContext.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\.code)])).map {
            CourseSnapshot(id: $0.id, code: $0.code, title: $0.title, term: $0.term, gradeComponents: $0.gradeComponents, lastIngested: $0.lastIngested)
        }
    }

    private func fetchCourse(id: UUID) throws -> Course? {
        try modelContext.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })).first
    }

    private func fetchObligations() throws -> [Obligation] {
        try modelContext.fetch(FetchDescriptor<Obligation>(sortBy: [SortDescriptor(\.due), SortDescriptor(\.title)]))
    }

    private func fetchObligation(id: UUID) throws -> Obligation? {
        try modelContext.fetch(FetchDescriptor<Obligation>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Snapshots

    func snapshot(_ o: Obligation) -> ObligationSnapshot {
        ObligationSnapshot(id: o.id, title: o.title, due: o.due, dueHasTime: o.dueHasTime, platform: o.platform, componentName: o.componentName,
                           pointsAtStake: o.pointsAtStake, confidence: o.confidence, state: o.state, origin: o.origin, flags: o.flags, notes: o.notes,
                           userOverrides: o.userOverrides, ekExternalID: o.ekExternalID, projectedTitle: o.projectedTitle, projectedDue: o.projectedDue,
                           projectedNotes: o.projectedNotes, completedAt: o.completedAt, deletedAt: o.deletedAt, changeNote: o.changeNote, createdOn: o.createdOn, courseID: o.course?.id,
                           courseCode: o.course?.code, sourceDocumentID: o.sourceDocument?.id, sourcePage: o.sourcePage)
    }

    func snapshot(_ d: SourceDocument) -> DocumentSnapshot {
        DocumentSnapshot(id: d.id, filename: d.filename, sha256: d.sha256, kind: d.kind, status: d.status, queuedAt: d.queuedAt, ingestedAt: d.ingestedAt, deviceName: d.deviceName, failure: d.failure)
    }
}

public enum StoreError: Error { case missingDocument }

extension Array where Element: Equatable {
    mutating func appendIfMissing(_ element: Element) { if !contains(element) { append(element) } }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
