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
        // A document filed under a course by the user stays there; its facts apply only if it names no other course.
        let course: Course?
        if let hinted = document.course {
            let named = result.course?.code.map(Normalize.collapseWhitespace) ?? ""
            if named.isEmpty || Normalize.key(named) == Normalize.key(hinted.code) { applyFacts(from: result, to: hinted) }
            else { summary.warnings.append("The document names \(named); filed under \(hinted.displayName) as asked") }
            hinted.deletedAt = nil
            course = hinted
        } else {
            course = try upsertCourse(from: result)
        }
        summary.courseCode = course?.code
        document.course = course
        document.status = .parsed
        document.failure = nil
        document.ingestedAt = Date()
        document.pageCount = result.document.pageCount
        document.route = result.route.rawValue
        document.platform = result.sourcePlatform
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
        if let course { recomputePoints(for: course) }
        try modelContext.save()
        return summary
    }

    /// Points at stake per item, over everything on file for the course (its documents together): weight over a stated
    /// count, else the rhythm over the term, else what is on file.
    private func recomputePoints(for course: Course) {
        let live = (course.obligations ?? []).filter { $0.deletedAt == nil }
        for component in course.gradeComponents {
            guard let weight = component.weight else { continue }
            let members = live.filter { $0.componentName.map(Normalize.key) == Normalize.key(component.name) }
            let points = PointsAtStake.perItem(weight: weight, expectedCount: component.expectedCount, cadence: component.cadence,
                                               termStart: course.termStart, termEnd: course.termEnd, onFile: members.count)
            for item in members where item.pointsAtStake != points { item.pointsAtStake = points; item.updatedAt = Date() }
        }
    }

    /// What the parser should already know when it reads a document filed under this course.
    public func knownCourse(for id: UUID) throws -> KnownCourse? {
        guard let course = try fetchCourse(id: id) else { return nil }
        let live = (course.obligations ?? []).filter { $0.deletedAt == nil }
        let components = course.gradeComponents.map { component in
            let platforms = live.filter { $0.componentName.map(Normalize.key) == Normalize.key(component.name) }.map(\.platform).filter { $0 != .syllabusOnly }
            let platform = Dictionary(grouping: platforms, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            return KnownComponent(name: component.name, weight: component.weight, expectedCount: component.expectedCount, cadence: component.cadence, platform: platform)
        }
        return KnownCourse(code: course.code.isEmpty ? nil : course.code, title: course.title.isEmpty ? nil : course.title, term: course.term,
                           termStart: course.termStart, termEnd: course.termEnd, components: components)
    }

    /// Files a parsed document (and the items it produced without a course) under a course.
    public func assignDocument(id: UUID, to courseID: UUID) throws {
        guard let document = try fetchDocument(id: id), let course = try fetchCourse(id: courseID) else { return }
        document.course = course
        let names = course.gradeComponents.map(\.name)
        for item in document.obligations ?? [] where item.course == nil && item.deletedAt == nil {
            item.course = course
            if item.componentName == nil || !names.contains(where: { Normalize.key($0) == Normalize.key(item.componentName ?? "") }) {
                item.componentName = ComponentNames.infer(title: item.title, among: names) ?? item.componentName
            }
            item.updatedAt = Date()
        }
        recomputePoints(for: course)
        try modelContext.save()
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
        course.deletedAt = nil   // a document naming a retired course brings it back
        applyFacts(from: result, to: course)
        return course
    }

    /// What a document says about its course, except where the user's hand edits stand.
    private func applyFacts(from result: IngestResult, to course: Course) {
        let parsed = result.course
        let code = parsed?.code.map(Normalize.collapseWhitespace) ?? ""
        let title = parsed?.title.map(Normalize.collapseWhitespace) ?? ""
        let kept = Set(course.userOverrides)   // hand-edited fields stay
        if course.code.isEmpty, !kept.contains("code") { course.code = code }
        if !kept.contains("title"), course.title.isEmpty || (!title.isEmpty && Normalize.key(course.title) != Normalize.key(title) && course.title.count < title.count) { course.title = title }
        if let p = parsed {
            if !kept.contains("instructor") { course.instructor = p.instructor ?? course.instructor }
            if !kept.contains("term") { course.term = p.term ?? course.term }
            if !kept.contains("termStart") { course.termStart = p.termStart ?? course.termStart }
            if !kept.contains("termEnd") { course.termEnd = p.termEnd ?? course.termEnd }
            if !kept.contains("room") { course.room = p.room ?? course.room }
            if !kept.contains("meetings"), !p.meetings.isEmpty { course.meetings = p.meetings }
        }
        if !kept.contains("gradeComponents"), !result.gradeComponents.isEmpty {
            course.gradeComponents = result.gradeComponents.map { GradeComponent(name: $0.name, weight: $0.weight, expectedCount: $0.expectedCount, cadence: $0.cadence, dropLowest: $0.dropLowest) }
        }
        if !kept.contains("noClassDates"), !result.noClassDates.isEmpty {
            course.noClassDates = result.noClassDates.map { ClosedDateRange(start: $0.start, end: $0.end ?? $0.start, label: $0.dateAsWritten) }
        }
        for platform in Set(result.obligations.map(\.platform.rawValue)) where !course.platforms.contains(platform) { course.platforms.append(platform) }
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
        let previous = item.sourceDocument?.filename
        item.sourceDocument = document
        item.updatedAt = Date()
        if isNew {
            item.state = switch parsed.status { case .ready: .readyToProject; case .needsReview: .pendingReview; case .awaitingDate: .awaitingDate }
        } else if !changed.isEmpty {
            // "schedule.pdf says due Oct 6 → Oct 8; earlier from syllabus.pdf" names both sides of a disagreement.
            item.changeNote = previous != nil && previous != document.filename
                ? "\(document.filename) says " + changed.joined(separator: "; ") + "; earlier from \(previous!)"
                : "Reissued document: " + changed.joined(separator: "; ")
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
    public func enqueueDocument(filename: String, sha256: String, kind: String, deviceName: String, courseID: UUID? = nil) throws -> DocumentSnapshot {
        let course = try courseID.flatMap { try fetchCourse(id: $0) }
        if let existing = try fetchDocuments().first(where: { $0.sha256 == sha256 }) {
            if existing.status == .failed || existing.status == .cancelled { existing.status = .queued; existing.failure = nil }
            if let course, existing.course == nil { existing.course = course }
            try modelContext.save()
            return snapshot(existing)
        }
        let doc = SourceDocument(filename: filename, sha256: sha256, kind: kind, deviceName: deviceName)
        doc.course = course   // the user's word on where it belongs; the parser learns the course from it
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

    /// What a day plan may schedule: live, incomplete items due within the coming days, with their course's name.
    public func planObligations(from day: Date, days: Int = 7, calendar: Calendar = .current) throws -> [PlanObligation] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        return try fetchObligations()
            .filter { $0.deletedAt == nil && $0.completedAt == nil && ($0.due.map { $0 >= start && $0 < end } ?? false) }
            .map { PlanObligation(title: $0.title, course: $0.course?.displayName, due: $0.due!, points: $0.pointsAtStake, notes: $0.notes) }
    }

    /// Hand edits to a course; each edited field becomes an override a later document leaves alone.
    public func updateCourse(id: UUID, edits: CourseEdits) throws {
        guard let course = try fetchCourse(id: id) else { return }
        Self.apply(edits, to: course)
        try modelContext.save()
    }

    /// A course entered by hand (the fallback for a course with no document yet). Every field given is an override.
    public func addCourse(_ edits: CourseEdits) throws -> CourseSnapshot {
        let course = Course(code: edits.code ?? "", title: edits.title ?? "")
        course.userOverrides = ["title", "code"]
        Self.apply(edits, to: course)
        modelContext.insert(course)
        try modelContext.save()
        return CourseSnapshot(course)
    }

    private static func apply(_ edits: CourseEdits, to course: Course) {
        func keep(_ field: String) { if !course.userOverrides.contains(field) { course.userOverrides.append(field) } }
        if let title = edits.title, title != course.title { course.title = title; keep("title") }
        if let code = edits.code, code != course.code { course.code = code; keep("code") }
        if let term = edits.term { course.term = term; keep("term") }
        if let start = edits.termStart { course.termStart = start; keep("termStart") }
        if let end = edits.termEnd { course.termEnd = end; keep("termEnd") }
        if let instructor = edits.instructor { course.instructor = instructor; keep("instructor") }
        if let room = edits.room { course.room = room; keep("room") }
        if let meetings = edits.meetings { course.meetings = meetings; keep("meetings") }
        if let components = edits.gradeComponents { course.gradeComponents = components; keep("gradeComponents") }
        if let breaks = edits.noClassDates { course.noClassDates = breaks; keep("noClassDates") }
    }

    /// Retires a course: it and its items leave every screen, and the items' reminders go on the next sync.
    public func deleteCourse(id: UUID) throws {
        guard let course = try fetchCourse(id: id) else { return }
        let now = Date()
        course.deletedAt = now
        course.sortOrder = nil
        for item in course.obligations ?? [] where item.deletedAt == nil { item.deletedAt = now; item.updatedAt = now }
        try modelContext.save()
    }

    /// The user's order for the Coverage screen; every course listed gets its position, the rest keep none.
    public func reorderCourses(_ ids: [UUID]) throws {
        let all = try modelContext.fetch(FetchDescriptor<Course>())
        for course in all { course.sortOrder = ids.firstIndex(of: course.id) }
        try modelContext.save()
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
        try modelContext.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.code)])).map(CourseSnapshot.init)
    }

    /// Where the app is probably blind, per course, most suspicious first (SPEC §6.1).
    public func coverage(now: Date = Date(), calendar: Calendar = .current) throws -> [CourseCoverage] {
        let obligations = try fetchObligations().filter { $0.deletedAt == nil }.map(ObligationSnapshot.init)
        let documents = try fetchDocuments().map(DocumentSnapshot.init)
        return try courses().map { Coverage.assess(course: $0, obligations: obligations, documents: documents, now: now, calendar: calendar) }
            .sorted { $0.suspicion > $1.suspicion }
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

    func snapshot(_ o: Obligation) -> ObligationSnapshot { ObligationSnapshot(o) }
    func snapshot(_ d: SourceDocument) -> DocumentSnapshot { DocumentSnapshot(d) }
}

public enum StoreError: Error { case missingDocument }

extension Array where Element: Equatable {
    mutating func appendIfMissing(_ element: Element) { if !contains(element) { append(element) } }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
