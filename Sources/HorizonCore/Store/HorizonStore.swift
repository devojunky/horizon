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
            revive(hinted)
            course = hinted
        } else {
            course = try upsertCourse(from: result)
        }
        summary.courseCode = course?.code
        document.course = course
        document.status = .parsed
        document.failure = nil
        document.checkpoint = nil   // read to the end
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
        // Tombstones the user made stay matched (deleted stays deleted); rows retired with a deleted course or document
        // are out of the running, so a document read again brings its items back as new rows.
        var pool = try (course.map { $0.obligations ?? [] } ?? fetchObligations().filter { $0.course == nil })
            .filter { $0.deletedAt == nil || !Self.retired($0) }
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

    /// A tombstone that went with its source rather than by the user's hand: flagged as such, or (before the flag
    /// existed) a document's item whose document is gone.
    static func retired(_ item: Obligation) -> Bool {
        item.retiredWithSource || (item.origin == .document && item.sourceDocument == nil)
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
            let platform = component.platform ?? Dictionary(grouping: platforms, by: { $0 }).max { $0.value.count < $1.value.count }?.key
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
        let all = try modelContext.fetch(FetchDescriptor<Course>()).sorted { ($0.deletedAt == nil ? 0 : 1) < ($1.deletedAt == nil ? 0 : 1) }   // a live course before a tombstone with its code
        let course = all.first { !code.isEmpty && Normalize.key($0.code) == Normalize.key(code) }
            ?? all.first { (code.isEmpty || $0.code.isEmpty) && !title.isEmpty && Normalize.similarity($0.title, title) >= 0.6 }
            ?? { let c = Course(code: code, title: title); modelContext.insert(c); return c }()
        revive(course)   // a document naming a deleted course brings it back
        applyFacts(from: result, to: course)
        return course
    }

    /// A document naming a course in the bin (or erased) brings it back for a fresh start: every tombstone it holds
    /// is retired, so the read creates new rows rather than matching what was once deleted. Its other documents stay
    /// in the bin, restorable on their own.
    private func revive(_ course: Course) {
        guard course.deletedAt != nil else { return }
        course.deletedAt = nil
        course.erasedAt = nil
        for item in course.obligations ?? [] where item.deletedAt != nil { item.retiredWithSource = true }
    }

    /// A document shared again while in the bin is read afresh: back on file, queued, its tombstones retired.
    private func revive(_ document: SourceDocument) {
        guard document.deletedAt != nil else { return }
        document.deletedAt = nil
        document.status = .queued
        document.failure = nil
        document.checkpoint = nil
        for item in document.obligations ?? [] where item.deletedAt != nil { item.retiredWithSource = true }
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
            // A whole grade table (weights that add up to about 100%) is the course's table; a partial one, such as
            // the components a schedule mentions, adds to what is on file and updates the facts it states.
            let parsed = result.gradeComponents.map { GradeComponent(name: $0.name, weight: $0.weight, expectedCount: $0.expectedCount, cadence: $0.cadence, dropLowest: $0.dropLowest, platform: $0.platform) }
            let total = parsed.compactMap(\.weight).reduce(0, +)
            if course.gradeComponents.isEmpty || (0.9...1.1).contains(total) {
                course.gradeComponents = parsed
            } else {
                var merged = course.gradeComponents
                for component in parsed {
                    if let i = merged.firstIndex(where: { Normalize.key($0.name) == Normalize.key(component.name) }) {
                        merged[i].weight = component.weight ?? merged[i].weight
                        merged[i].expectedCount = component.expectedCount ?? merged[i].expectedCount
                        merged[i].cadence = component.cadence ?? merged[i].cadence
                        merged[i].dropLowest = component.dropLowest ?? merged[i].dropLowest
                        merged[i].platform = component.platform ?? merged[i].platform
                    } else {
                        merged.append(component)
                    }
                }
                course.gradeComponents = merged
            }
        }
        if !kept.contains("noClassDates"), !result.noClassDates.isEmpty {
            course.noClassDates = result.noClassDates.map { ClosedDateRange(start: $0.start, end: $0.end ?? $0.start, label: $0.dateAsWritten) }
        }
        let seen = Set(result.obligations.map(\.platform.rawValue) + result.gradeComponents.compactMap { $0.platform?.rawValue })
        for platform in seen where !course.platforms.contains(platform) { course.platforms.append(platform) }
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
            revive(existing)   // shared again from the bin: a fresh read
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
        try fetchDocuments().filter { $0.deletedAt == nil && ($0.status == .queued || $0.status == .awaitingCloudParse) }.map(snapshot)
    }

    /// Documents on file, the bin excluded.
    public func documents() throws -> [DocumentSnapshot] { try fetchDocuments().filter { $0.deletedAt == nil }.map(snapshot) }

    /// Documents in Recently Deleted on their own (one deleted with its course sits under the course).
    public func deletedDocuments() throws -> [DocumentSnapshot] { try fetchDocuments().filter(\.isBinned).map(snapshot) }

    // MARK: Recently Deleted

    /// Puts a document in the bin: it leaves Documents and the items it is the source of go with it (soft-deleted, so
    /// their reminders go on the next sync); an item another document has since fed stays. The file stays until the
    /// document is erased or the bin expires; sharing the same file again meanwhile reads it afresh.
    public func deleteDocument(id: UUID) throws {
        guard let doc = try fetchDocument(id: id), doc.deletedAt == nil else { return }
        let now = Date()
        doc.deletedAt = now
        for item in doc.obligations ?? [] where item.deletedAt == nil { retire(item, at: now) }
        if let course = doc.course { recomputePoints(for: course) }
        try modelContext.save()
    }

    /// Back from the bin with the items that went with it, and its course if that is in the bin too.
    public func restoreDocument(id: UUID) throws {
        guard let doc = try fetchDocument(id: id), let deletedAt = doc.deletedAt else { return }
        if let course = doc.course, course.deletedAt != nil { restore(course) }
        doc.deletedAt = nil
        restore(doc.obligations ?? [], deletedAt: deletedAt, in: doc.course)
        if let course = doc.course { recomputePoints(for: course) }
        try modelContext.save()
    }

    /// Gone for good: the record is removed (the file with it, by the caller) and what came from it stays retired.
    @discardableResult
    public func eraseDocument(id: UUID) throws -> DocumentSnapshot? {
        guard let doc = try fetchDocument(id: id) else { return nil }
        let record = snapshot(doc)
        let now = Date()
        for item in doc.obligations ?? [] { retire(item, at: now) }
        let course = doc.course
        modelContext.delete(doc)
        if let course { recomputePoints(for: course) }
        try modelContext.save()
        return record
    }

    /// Puts a course in the bin with its items (their reminders go on the next sync) and its documents. Tombstones the
    /// user made before stay as they are, so a restore leaves them deleted.
    public func deleteCourse(id: UUID) throws {
        guard let course = try fetchCourse(id: id), course.deletedAt == nil else { return }
        let now = Date()
        course.deletedAt = now
        course.sortOrder = nil
        for item in course.obligations ?? [] where item.deletedAt == nil { retire(item, at: now) }
        for document in course.documents ?? [] where document.deletedAt == nil { document.deletedAt = now }
        try modelContext.save()
    }

    /// Back from the bin with exactly what its deletion took.
    public func restoreCourse(id: UUID) throws {
        guard let course = try fetchCourse(id: id) else { return }
        restore(course)
        try modelContext.save()
    }

    /// Gone for good: its documents are removed (their files by the caller), every tombstone it holds is retired, and
    /// the row stays a tombstone out of the bin until the purge. A document naming the course again still revives it.
    @discardableResult
    public func eraseCourse(id: UUID) throws -> [DocumentSnapshot] {
        guard let course = try fetchCourse(id: id) else { return [] }
        let now = Date()
        if course.deletedAt == nil { course.deletedAt = now; course.sortOrder = nil }
        course.erasedAt = now
        for item in course.obligations ?? [] { retire(item, at: now) }
        let documents = (course.documents ?? []).map(snapshot)
        for document in course.documents ?? [] { modelContext.delete(document) }
        try modelContext.save()
        return documents
    }

    /// What has sat in the bin for `Bin.age` goes for good. Returns the documents whose files can be removed.
    @discardableResult
    public func expireBin(now: Date = Date()) throws -> [DocumentSnapshot] {
        let cutoff = now.addingTimeInterval(-Bin.age)
        var files: [DocumentSnapshot] = []
        for course in try fetchCourses().filter({ $0.isBinned && $0.deletedAt! < cutoff }) { files += try eraseCourse(id: course.id) }
        for document in try fetchDocuments().filter({ $0.isBinned && $0.deletedAt! < cutoff }) { if let record = try eraseDocument(id: document.id) { files.append(record) } }
        return files
    }

    /// Courses in Recently Deleted.
    public func deletedCourses() throws -> [CourseSnapshot] { try fetchCourses().filter(\.isBinned).map(CourseSnapshot.init) }

    /// Soft-deletes a live item as part of its source's deletion; a tombstone is only marked as having gone with it.
    private func retire(_ item: Obligation, at now: Date) {
        if item.deletedAt == nil { item.deletedAt = now; item.updatedAt = now }
        item.retiredWithSource = true
    }

    private func restore(_ course: Course) {
        guard let deletedAt = course.deletedAt else { return }
        course.deletedAt = nil
        for document in course.documents ?? [] where Bin.wentWith(document.deletedAt, deletedAt) { document.deletedAt = nil }
        restore(course.obligations ?? [], deletedAt: deletedAt, in: course)
        recomputePoints(for: course)
    }

    /// The items a deletion took come back live; a tombstone from before stays one; an item the course has since gained
    /// again (a re-read while this sat in the bin) is not doubled. A restored item that had a reminder gets one again.
    private func restore(_ items: [Obligation], deletedAt: Date, in course: Course?, calendar: Calendar = .current) {
        let live = (course?.obligations ?? []).filter { $0.deletedAt == nil }
        let now = Date()
        for item in items where Bin.wentWith(item.deletedAt, deletedAt) {
            let twin = live.contains { twin in
                Normalize.key(twin.title) == Normalize.key(item.title) && (twin.due == nil) == (item.due == nil)
                    && (twin.due == nil || calendar.isDate(twin.due!, inSameDayAs: item.due!))
            }
            if twin { continue }
            item.deletedAt = nil
            item.retiredWithSource = false
            item.updatedAt = now
            if item.state == .projected { item.state = .readyToProject }   // its reminder went with the deletion
        }
    }

    public func markDocument(id: UUID, status: DocumentStatus, failure: String? = nil) throws {
        guard let doc = try fetchDocument(id: id) else { return }
        doc.status = status; doc.failure = failure
        try modelContext.save()
    }

    /// Where a read of the document stopped, if one did.
    public func checkpoint(for id: UUID) throws -> Data? { try fetchDocument(id: id)?.checkpoint }

    /// The user's word that the device model may read this document instead of Claude: it goes back in the queue,
    /// its Claude checkpoint set aside (the device chunks differently).
    public func readOnDevice(id: UUID) throws {
        guard let doc = try fetchDocument(id: id) else { return }
        doc.readOnDevice = true
        doc.status = .queued; doc.failure = nil; doc.checkpoint = nil
        try modelContext.save()
    }

    /// Keeps where a read stands, part by part, so a read that stops goes on from there.
    public func saveCheckpoint(id: UUID, data: Data?) throws {
        guard let doc = try fetchDocument(id: id) else { return }
        doc.checkpoint = data
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

    /// Hard-deletes tombstones older than `tombstoneAge`: items, and erased courses (whose tombstones are at least as
    /// old). Never runs on a record that has not had time to sync.
    @discardableResult
    public func purgeTombstones(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.tombstoneAge)
        let dead = try fetchObligations().filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        dead.forEach(modelContext.delete)
        let deadCourses = try fetchCourses().filter { $0.erasedAt != nil && ($0.deletedAt ?? .distantFuture) < cutoff }
        deadCourses.forEach(modelContext.delete)
        try modelContext.save()
        return dead.count + deadCourses.count
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
        let documents = try fetchDocuments().filter { $0.deletedAt == nil }.map(DocumentSnapshot.init)
        return try courses().map { Coverage.assess(course: $0, obligations: obligations, documents: documents, now: now, calendar: calendar) }
            .sorted { $0.suspicion > $1.suspicion }
    }

    private func fetchCourses() throws -> [Course] {
        try modelContext.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\.code)]))
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
