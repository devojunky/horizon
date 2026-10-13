import Foundation
import SwiftData
import IngestKit

/// Every write to the model store, and the reads the app's work needs (views read through `@Query`). One actor, so
/// field ownership and soft deletes are enforced in one place.
@ModelActor
public actor HorizonStore {
    public static let tombstoneAge: TimeInterval = 180 * 86400

    // MARK: Ingest

    /// Folds an `IngestResult` into the store (SPEC §4.4 field ownership). Existing obligations are matched by what the
    /// document said of them (`documentWords`: its title and day as printed, whatever the user has made of the row), among
    /// the course's rows and the rows moved out of its documents; document-owned fields update unless the user overrode
    /// them, and a changed title, date or site goes back to review with a `changeNote` rather than moving silently.
    public func ingest(_ result: IngestResult, documentID: UUID, calendar: Calendar = .current) throws -> IngestSummary {
        var summary = IngestSummary(warnings: result.warnings)
        guard let document = try fetchDocument(id: documentID) else { throw StoreError.missingDocument }
        // Deleted while it was read (on its own, or with its course): nothing comes back from the bin and nothing is
        // folded in. The document waits there with its checkpoint, so a restore reads it again from the parts read.
        if document.deletedAt != nil { summary.binned = true; return summary }
        // A document filed under a course by the user stays there; its facts apply only if it names no other course. A
        // course made by hand without a code has none to differ: the first document filed there gives it its code, and
        // its facts, unless another course on file has that code.
        let course: Course?
        if let hinted = document.course {
            if wentAfterQueueing(hinted, document) { return try setAside(document, with: hinted, summary) }
            let named = result.course?.code.map(Normalize.collapseWhitespace) ?? ""
            var applies = named.isEmpty || Normalize.key(named) == Normalize.key(hinted.code)
            if !applies, hinted.code.isEmpty {
                applies = try !fetchCourses().contains { $0.id != hinted.id && $0.deletedAt == nil && Normalize.key($0.code) == Normalize.key(named) }
            }
            if applies { applyFacts(from: result, to: hinted) }
            else { summary.warnings.append("The document names \(named); filed under \(hinted.displayName) as asked") }
            revive(hinted)
            course = hinted
        } else if let named = try upsertCourse(from: result) {
            if wentAfterQueueing(named, document) { return try setAside(document, with: named, summary) }
            revive(named)   // a document naming a deleted course brings it back (shared after the deletion: see above)
            applyFacts(from: result, to: named)
            course = named
        } else {
            course = nil
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

        // Candidates: this course's rows, and those read from its documents that the user has since moved to another
        // course; or the course-less rows when the document names no course. Each is matched once. Tombstones the user
        // made stay matched (deleted stays deleted); rows retired with a deleted course or document are out of the
        // running, so a document read again brings its items back as new rows.
        var pool: [Obligation]
        if let course {
            let own = course.obligations ?? []
            let moved = (course.documents ?? []).flatMap { $0.obligations ?? [] }.filter { $0.course?.id != course.id }
            pool = own + moved.filter { item in !own.contains { $0.id == item.id } }
        } else {
            pool = try fetchObligations().filter { $0.course == nil }
        }
        pool = pool.filter { $0.deletedAt == nil || !Self.retired($0) }
        var elsewhere: [Course] = []
        for parsed in result.obligations {
            if let index = Self.match(parsed, in: pool, calendar: calendar) {
                let existing = pool.remove(at: index)
                if existing.deletedAt != nil { summary.unchanged += 1; continue }   // deleted in Reminders stays deleted
                let ownCourse = existing.course?.id == course?.id
                if !ownCourse, let other = existing.course, !elsewhere.contains(where: { $0.id == other.id }) { elsewhere.append(other) }
                let changes = apply(parsed, to: existing, document: document, ownCourse: ownCourse, calendar: calendar)
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
        for affected in [course].compactMap({ $0 }) + elsewhere { recomputePoints(for: affected) }
        try modelContext.save()
        return summary
    }

    /// The course went to the bin (or for good) after the document was queued: the user deleted it while the document
    /// waited or was read, so the read must not bring it back. A document shared (or restored, or retried) after the
    /// deletion is a fresh request, and does.
    private func wentAfterQueueing(_ course: Course, _ document: SourceDocument) -> Bool {
        guard let deletedAt = course.deletedAt else { return false }
        return document.queuedAt < deletedAt
    }

    /// A read that finds its course deleted since the document was queued folds nothing in: the document goes with the
    /// course, unread, its checkpoint kept. Under a course in the bin it sits under the course and comes back with it
    /// (then read from its checkpoint); a course erased leaves it in the bin on its own, where a restore queues it again.
    private func setAside(_ document: SourceDocument, with course: Course, _ summary: IngestSummary) throws -> IngestSummary {
        if course.isBinned { document.course = course; document.deletedAt = course.deletedAt }
        else { document.course = nil; document.deletedAt = Date() }
        try modelContext.save()
        var summary = summary
        summary.binned = true
        return summary
    }

    /// A tombstone that went with its source rather than by the user's hand: flagged as such, or (before the flag
    /// existed) a document's item whose document is gone.
    static func retired(_ item: Obligation) -> Bool {
        item.retiredWithSource || (item.origin == .document && item.sourceDocument == nil)
    }

    /// Points at stake per item, over everything on file for the course (its documents together): weight over a stated
    /// count, else the rhythm over the term, else what is on file. Run whenever any of those changes: a read, an item
    /// added, moved, deleted or restored, a grade table or term edited. A reminder showing the old figure ("Worth 1.5%",
    /// its priority) is written again.
    private func recomputePoints(for course: Course) {
        let live = (course.obligations ?? []).filter { $0.deletedAt == nil }
        for component in course.gradeComponents {
            guard let weight = component.weight else { continue }
            let members = live.filter { $0.componentName.map(Normalize.key) == Normalize.key(component.name) }
            let points = PointsAtStake.perItem(weight: weight, expectedCount: component.expectedCount, dropLowest: component.dropLowest, cadence: component.cadence,
                                               termStart: course.termStart, termEnd: course.termEnd, onFile: members.count)
            for item in members where item.pointsAtStake != points {
                item.pointsAtStake = points
                item.updatedAt = Date()
                if item.state == .projected { item.state = .readyToProject }
            }
        }
    }

    /// Recomputes points for each course given once, nil skipped.
    private func recomputePoints(for courses: [Course?]) {
        var done: [UUID] = []
        for case let course? in courses where !done.contains(course.id) { done.append(course.id); recomputePoints(for: course) }
    }

    /// The course's name changed (by hand, or a document's longer one): every reminder of its items carries it ("HW 1 ·
    /// Calculus II"), so each item already written there is written again by the next sync. An item in review or waiting
    /// for a date takes the new name when it is next written; meanwhile the reconcile still reads the old one on its
    /// reminder as the course's (`Reconciler.stripCourse`).
    private func rewriteReminders(of course: Course) {
        for item in course.obligations ?? [] where item.deletedAt == nil && item.state == .projected {
            item.state = .readyToProject
            item.updatedAt = Date()
        }
    }

    /// "Updated N days ago" counts only documents still on file: the last read of one, nil when none is left.
    private func refreshLastIngested(_ course: Course, excluding gone: UUID? = nil) {
        course.lastIngested = (course.documents ?? []).filter { $0.id != gone && $0.deletedAt == nil && $0.status == .parsed }.compactMap(\.ingestedAt).max()
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

    /// Files a parsed document (and the items it produced without a course) under a course. Their reminders carry the
    /// course's name from then on, so the ones already written are written again.
    public func assignDocument(id: UUID, to courseID: UUID) throws {
        guard let document = try fetchDocument(id: id), let course = try fetchCourse(id: courseID) else { return }
        document.course = course
        let names = course.gradeComponents.map(\.name)
        for item in document.obligations ?? [] where item.course == nil && item.deletedAt == nil {
            item.course = course
            if item.componentName == nil || !names.contains(where: { Normalize.key($0) == Normalize.key(item.componentName ?? "") }) {
                item.componentName = ComponentNames.infer(title: item.title, among: names) ?? item.componentName
            }
            if item.state == .projected { item.state = .readyToProject }
            item.updatedAt = Date()
        }
        recomputePoints(for: course)
        try modelContext.save()
    }

    /// The course a document names: the same course when the code matches; a title that reads the same when either side
    /// has no code; else a new one. Nil when it names none. The caller revives and fills it.
    private func upsertCourse(from result: IngestResult) throws -> Course? {
        let parsed = result.course
        let code = parsed?.code.map(Normalize.collapseWhitespace) ?? ""
        let title = parsed?.title.map(Normalize.collapseWhitespace) ?? ""
        guard !code.isEmpty || !title.isEmpty else { return nil }
        let all = try modelContext.fetch(FetchDescriptor<Course>()).sorted { ($0.deletedAt == nil ? 0 : 1) < ($1.deletedAt == nil ? 0 : 1) }   // a live course before a tombstone with its code
        return all.first { !code.isEmpty && Normalize.key($0.code) == Normalize.key(code) }
            ?? all.first { (code.isEmpty || $0.code.isEmpty) && !title.isEmpty && Normalize.similarity($0.title, title) >= 0.6 }
            ?? { let c = Course(code: code, title: title); modelContext.insert(c); return c }()
    }

    /// A document naming a course in the bin (or erased) brings it back for a fresh start: every tombstone it holds
    /// is retired, so the read creates new rows rather than matching what was once deleted. Its other documents stay
    /// in the bin, restorable on their own. Its silence counts from now: it has only just come back.
    private func revive(_ course: Course) {
        guard course.deletedAt != nil else { return }
        course.deletedAt = nil
        course.erasedAt = nil
        course.createdAt = Date()
        for item in course.obligations ?? [] where item.deletedAt != nil { item.retiredWithSource = true }
    }

    /// A document shared again while in the bin is read afresh: back on file, queued as a new request, its tombstones
    /// retired.
    private func revive(_ document: SourceDocument) {
        guard document.deletedAt != nil else { return }
        document.deletedAt = nil
        document.status = .queued
        document.failure = nil
        document.failureIsPermanent = false
        document.checkpoint = nil
        document.queuedAt = Date()
        for item in document.obligations ?? [] where item.deletedAt != nil { item.retiredWithSource = true }
    }

    /// What a document says about its course, except where the user's hand edits stand. A course without a code takes the
    /// document's whatever its overrides say: an empty code is no edit of the user's to keep (a course made by hand once
    /// had its code marked as theirs, given or not, and then never took one).
    private func applyFacts(from result: IngestResult, to course: Course) {
        let parsed = result.course
        let code = parsed?.code.map(Normalize.collapseWhitespace) ?? ""
        let title = parsed?.title.map(Normalize.collapseWhitespace) ?? ""
        let kept = Set(course.userOverrides)   // hand-edited fields stay
        let name = course.displayName
        defer { if course.displayName != name { rewriteReminders(of: course) } }
        if course.code.isEmpty { course.code = code }
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
    /// same title (its date moved: the re-ingest diff case). A row is known by its document's word on it (the current
    /// source's), not by what the user has made of it: renamed or moved in the app or in Reminders, it is still the item.
    static func match(_ parsed: ParsedObligation, in pool: [Obligation], calendar: Calendar) -> Int? {
        let key = Normalize.key(parsed.title)
        let words = pool.map { $0.documentWords.last.map { (title: $0.title, due: $0.due) } ?? (title: $0.title, due: $0.due) }
        func sameDay(_ i: Int) -> Bool {
            switch (words[i].due, parsed.due) {
            case (nil, nil): true
            case (let a?, let b?): calendar.isDate(a, inSameDayAs: b)
            default: false
            }
        }
        let exact = pool.indices.filter { Normalize.key(words[$0].title) == key }
        if let i = exact.first(where: sameDay) { return i }
        if let i = exact.first(where: { (words[$0].due == nil) != (parsed.due == nil) }) { return i }
        if let i = pool.indices.first(where: { sameDay($0) && Normalize.similarity(words[$0].title, parsed.title) >= 0.5 }) { return i }
        return exact.count == 1 ? exact[0] : nil
    }

    /// Writes document-owned fields, honouring overrides. Returns the names of fields that changed. A document that
    /// disagrees with a hand edit does not win, but the disagreement is recorded so the row can show it. A row the user
    /// moved to another course (`ownCourse` false) keeps its grade row and points: those are its new course's.
    private func apply(_ parsed: ParsedObligation, to item: Obligation, document: SourceDocument, ownCourse: Bool = true, calendar: Calendar, isNew: Bool = false) -> [String] {
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
        if ownCourse, let name = parsed.componentName, item.componentName != name, !overrides.contains(.componentName) { item.componentName = name }
        if ownCourse { item.pointsAtStake = parsed.pointsAtStake ?? item.pointsAtStake }   // a weighted row's share is then worked out over the course
        item.confidence = parsed.confidence
        item.flags = parsed.flags.map(\.rawValue)
        item.dateAsWritten = parsed.dateAsWritten
        item.sourcePage = parsed.sourcePage
        let previous = item.sourceDocument.flatMap { $0.filename == document.filename ? nil : $0.displayName }   // another document fed it before; the same file reissued is not another
        // The document's word on the item, kept whatever the overrides (what a later read matches on, and what the item
        // goes back to if a later source is deleted). Only a document's own row takes it as its source: one the user made,
        // here or in Reminders, is never the document's to take with it when it goes.
        item.documentWords.removeAll { $0.document == document.id }
        item.documentWords.append(DocumentWord(document: document.id, title: parsed.title, due: parsed.due, dueHasTime: parsed.dueHasTime))
        if item.documentWords.count > 8 { item.documentWords.removeFirst(item.documentWords.count - 8) }
        if item.origin == .document { item.sourceDocument = document }
        item.updatedAt = Date()
        if isNew {
            item.state = switch parsed.status { case .ready: .readyToProject; case .needsReview: .pendingReview; case .awaitingDate: .awaitingDate }
        } else if !changed.isEmpty {
            // "Lab Schedule says due Oct 6 → Oct 8; earlier from Calculus II Syllabus" names both sides of a disagreement.
            item.changeNote = previous.map { "\(document.displayName) says " + changed.joined(separator: "; ") + "; earlier from \($0)" }
                ?? "Reissued document: " + changed.joined(separator: "; ")
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
    /// `refusal`: the file is of a kind Horizon cannot read, said in the user's words; it is recorded as failed for good
    /// (no Retry), never queued.
    public func enqueueDocument(filename: String, sha256: String, kind: String, deviceName: String, courseID: UUID? = nil, refusal: String? = nil) throws -> DocumentSnapshot {
        let course = try courseID.flatMap { try fetchCourse(id: $0) }
        if let existing = try fetchDocuments().first(where: { $0.sha256 == sha256 }) {
            revive(existing)   // shared again from the bin: a fresh read
            if let refusal { existing.status = .failed; existing.failure = refusal; existing.failureIsPermanent = true }
            else if existing.status == .failed || existing.status == .cancelled { requeue(existing) }
            if let course, existing.course == nil { existing.course = course }
            try modelContext.save()
            return snapshot(existing)
        }
        let doc = SourceDocument(filename: filename, sha256: sha256, kind: kind, deviceName: deviceName)
        doc.course = course   // the user's word on where it belongs; the parser learns the course from it
        if let refusal { doc.status = .failed; doc.failure = refusal; doc.failureIsPermanent = true }
        modelContext.insert(doc)
        try modelContext.save()
        return snapshot(doc)
    }

    /// A document failed or cancelled, queued again by the user (shared again, Retry): a new request, counted from now.
    private func requeue(_ document: SourceDocument) {
        document.status = .queued
        document.failure = nil
        document.failureIsPermanent = false
        document.queuedAt = Date()
    }

    /// One document as it is now, the bin included.
    public func document(id: UUID) throws -> DocumentSnapshot? { try fetchDocument(id: id).map(snapshot) }

    public func queuedDocuments() throws -> [DocumentSnapshot] {
        try fetchDocuments().filter { $0.deletedAt == nil && ($0.status == .queued || $0.status == .awaitingCloudParse) }.map(snapshot)
    }

    /// Documents on file, the bin excluded.
    public func documents() throws -> [DocumentSnapshot] { try fetchDocuments().filter { $0.deletedAt == nil }.map(snapshot) }

    /// Documents in Recently Deleted on their own (one deleted with its course sits under the course).
    public func deletedDocuments() throws -> [DocumentSnapshot] { try fetchDocuments().filter(\.isBinned).map(snapshot) }

    // MARK: Recently Deleted

    /// Puts a document in the bin: it leaves Documents and the items it is the source of go with it (soft-deleted, so
    /// their reminders go on the next sync); an item another document has since fed stays. An item this document took
    /// over from an earlier one still on file (a schedule update moving a syllabus's date) goes back to that document
    /// and its word on it, not into the bin. The file stays until the document is erased or the bin expires; sharing
    /// the same file again meanwhile reads it afresh.
    public func deleteDocument(id: UUID) throws {
        guard let doc = try fetchDocument(id: id), doc.deletedAt == nil else { return }
        let now = Date()
        doc.deletedAt = now
        var courses = [doc.course]
        for item in doc.obligations ?? [] where item.deletedAt == nil {
            courses.append(item.course)
            if item.origin != .document { item.sourceDocument = nil }   // the user's own row: never the document's to take
            else if let earlier = try earlierSource(of: item, besides: doc) { fallBack(item, to: earlier.document, word: earlier.word, from: doc) }
            else { retire(item, at: now) }
        }
        if let course = doc.course { refreshLastIngested(course) }
        recomputePoints(for: courses)
        try modelContext.save()
    }

    /// The latest other document still on file that listed the item, with its word on it.
    private func earlierSource(of item: Obligation, besides doc: SourceDocument) throws -> (document: SourceDocument, word: DocumentWord)? {
        for word in item.documentWords.reversed() where word.document != doc.id {
            if let earlier = try fetchDocument(id: word.document), earlier.deletedAt == nil { return (earlier, word) }
        }
        return nil
    }

    /// The item goes back to an earlier document's word on it, except where the user's edits stand. A title or date
    /// that moves back is a change the user may be relying on, so it goes to review saying why, as a re-read's would.
    private func fallBack(_ item: Obligation, to earlier: SourceDocument, word: DocumentWord, from gone: SourceDocument) {
        item.documentWords.removeAll { $0.document == gone.id }
        item.sourceDocument = earlier
        let overrides = Set(item.userOverrides)
        var changed: [String] = []
        if item.title != word.title, !overrides.contains(.title) { changed.append("title \(item.title) → \(word.title)"); item.title = word.title }
        let same: Bool = switch (item.due, word.due) {
            case (nil, nil): true
            case (let a?, let b?): abs(a.timeIntervalSince(b)) < 60
            default: false
        }
        if !same || item.dueHasTime != word.dueHasTime, !overrides.contains(.due) {
            changed.append("due \(item.due.map(Self.short) ?? "TBD") → \(word.due.map(Self.short) ?? "TBD")")
            if let old = item.due, word.due != nil { item.conflictingDate = old }
            item.due = word.due; item.dueHasTime = word.dueHasTime
        }
        item.updatedAt = Date()
        guard !changed.isEmpty else { return }
        item.changeNote = "\(gone.displayName) was deleted; \(earlier.displayName) says " + changed.joined(separator: "; ")
        item.state = item.due == nil ? .awaitingDate : .pendingReview
    }

    /// Back from the bin with the items that went with it, and its course if that is in the bin too. A document that
    /// was never read to the end (deleted while it waited or was read) goes back in the queue as a new request, and is
    /// read from its checkpoint.
    public func restoreDocument(id: UUID) throws {
        guard let doc = try fetchDocument(id: id), let deletedAt = doc.deletedAt else { return }
        if let course = doc.course, course.deletedAt != nil { restore(course) }
        doc.deletedAt = nil
        if doc.status == .queued || doc.status == .awaitingCloudParse { doc.queuedAt = Date() }
        restore(doc.obligations ?? [], deletedAt: deletedAt, in: doc.course)
        if let course = doc.course { refreshLastIngested(course); recomputePoints(for: course) }
        try modelContext.save()
    }

    /// Gone for good: the record is removed (the file with it, by the caller) and what came from it stays retired.
    @discardableResult
    public func eraseDocument(id: UUID) throws -> DocumentSnapshot? {
        guard let doc = try fetchDocument(id: id) else { return nil }
        let record = snapshot(doc)
        let now = Date()
        for item in doc.obligations ?? [] where item.origin == .document { retire(item, at: now) }
        let course = doc.course
        if let course { refreshLastIngested(course, excluding: doc.id) }
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
        course.deletedAt = now   // its place in the user's order is kept, for a restore
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
        refreshLastIngested(course)
        recomputePoints(for: course)
    }

    /// The items a deletion took come back live; a tombstone from before stays one; an item the course has since gained
    /// again (a re-read while this sat in the bin) is not doubled. A restored item that had a reminder gets one again,
    /// checked if it was: the deletion took the checked reminder, and Reminders, which owns completion, would otherwise
    /// hand back the new one's unchecked state.
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
            if item.completedAt != nil { item.completionPending = true }
        }
    }

    /// `permanent`: a failure that is the file's own (`IngestCoordinator.isPermanent`), so no Retry is offered. A failed
    /// or cancelled document queued again (the user's Retry) is a new request, counted from now.
    public func markDocument(id: UUID, status: DocumentStatus, failure: String? = nil, permanent: Bool = false) throws {
        guard let doc = try fetchDocument(id: id) else { return }
        if status == .queued, doc.status == .failed || doc.status == .cancelled { doc.queuedAt = Date() }
        doc.status = status; doc.failure = failure
        doc.failureIsPermanent = status == .failed && permanent
        try modelContext.save()
    }

    /// Where a read of the document stopped, if one did.
    public func checkpoint(for id: UUID) throws -> Data? { try fetchDocument(id: id)?.checkpoint }

    /// The user's word that the device model may read this document instead of Claude: it goes back in the queue,
    /// its Claude checkpoint set aside (the device chunks differently).
    public func readOnDevice(id: UUID) throws {
        guard let doc = try fetchDocument(id: id) else { return }
        doc.readOnDevice = true
        doc.status = .queued; doc.failure = nil; doc.failureIsPermanent = false; doc.checkpoint = nil
        try modelContext.save()
    }

    /// The device model's name for the document; an empty one records that it was asked and had none, so it is not
    /// asked again. A title already on file stands.
    public func setDocumentTitle(id: UUID, title: String) throws {
        guard let doc = try fetchDocument(id: id), (doc.title ?? "").isEmpty else { return }
        doc.title = title
        try modelContext.save()
    }

    /// Documents nobody has tried to name yet (read before titles existed, or while the device model was away).
    /// One being read is named by its read.
    public func untitledDocuments() throws -> [DocumentSnapshot] {
        try fetchDocuments().filter { $0.deletedAt == nil && $0.title == nil && $0.status != .queued }.map(snapshot)
    }

    /// What a document turned out to hold, in a few lines, for naming a picture the device model never saw: the
    /// course, the site, its items.
    public func digest(for id: UUID) throws -> String? {
        guard let doc = try fetchDocument(id: id) else { return nil }
        var lines: [String] = []
        if let course = doc.course { lines.append([course.code, course.title].filter { !$0.isEmpty }.joined(separator: " ")) }
        if let platform = doc.platform, platform != .syllabusOnly { lines.append("Site: \(platform.rawValue)") }
        let items = (doc.obligations ?? []).filter { $0.deletedAt == nil }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(12)
        if !items.isEmpty { lines.append("Items: " + items.map { "\($0.title)\($0.dateAsWritten.map { ", \($0)" } ?? "")" }.joined(separator: "; ")) }
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
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

    /// What waits for the user's eye. An item checked off needs none: it leaves the queue, and comes back if unchecked.
    public func reviewQueue() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt == nil && $0.state == .pendingReview && $0.completedAt == nil }.map(snapshot)
    }

    /// The user's check in the app, on or off. Reminders owns completion (SPEC §4.4), so the mark is held against the
    /// reconciler (`completionPending`) until the projector has written it to the item's reminder; an item with no
    /// reminder keeps it here. Nothing else about the item changes: a check is not a confirmation. Done on a skipped item
    /// replaces the skip (its reminder is checked already); not done on one leaves it skipped (`setSkipped` opens it).
    public func setCompleted(id: UUID, _ done: Bool, at now: Date = Date()) throws {
        guard let item = try fetchObligation(id: id), item.deletedAt == nil, (item.completedAt != nil && item.skippedAt == nil) != done else { return }
        if done {
            if item.completedAt == nil { item.completionPending = true }
            item.completedAt = now
            item.skippedAt = nil
        } else {
            guard item.skippedAt == nil else { return }
            item.completedAt = nil
            item.completionPending = true
        }
        item.updatedAt = now
        try modelContext.save()
    }

    /// The user's Skip, or taken back. Skipped, the item is closed as a done one is (`completedAt`, and its reminder
    /// checked off, through `completionPending` as a check goes) and marked as set aside, not done; taken back, it is
    /// open again and its reminder unchecked. A done item skipped stays closed, now skipped.
    public func setSkipped(id: UUID, _ skipped: Bool, at now: Date = Date()) throws {
        guard let item = try fetchObligation(id: id), item.deletedAt == nil, (item.skippedAt != nil) != skipped else { return }
        if skipped {
            if item.completedAt == nil { item.completedAt = now; item.completionPending = true }
            item.skippedAt = now
        } else {
            item.skippedAt = nil
            item.completedAt = nil
            item.completionPending = true
        }
        item.updatedAt = now
        try modelContext.save()
    }

    /// Checks made in the app that Reminders has not been told of.
    public func pendingCompletions() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt == nil && $0.completionPending }.map(snapshot)
    }

    /// The check is in Reminders now: from here on Reminders' word on it wins again. `done` is what was written; an
    /// item checked or unchecked again while it was being written keeps its mark pending, and the next pass writes that.
    public func completionProjected(id: UUID, wrote done: Bool) throws {
        guard let item = try fetchObligation(id: id), (item.completedAt != nil) == done else { return }
        item.completionPending = false
        try modelContext.save()
    }

    /// Items to write to Reminders: confirmed or confident, not deleted, not yet projected in their current form.
    public func pendingProjection() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt == nil && $0.state == .readyToProject }.map(snapshot)
    }

    /// Discarded items that still have a reminder Horizon created.
    public func deletedAwaitingRemoval() throws -> [ObligationSnapshot] {
        try fetchObligations().filter { $0.deletedAt != nil && $0.ekExternalID != nil && $0.origin != .reminders }.map(snapshot)
    }

    /// The reminders of every live item that are not in the Horizon list any more because the list itself went (deleted
    /// and made again): each item is written afresh by the next sync. The old identifier is forgotten, so its absence can
    /// never read as a deletion; a projected item goes back to the projector's queue; a checked one carries its check
    /// to the new reminder. Items in review get theirs when confirmed, as any item does. Returns how many were reset.
    @discardableResult
    public func forgetReminders(except present: Set<String>) throws -> Int {
        var count = 0
        for item in try fetchObligations() where item.deletedAt == nil {
            guard let id = item.ekExternalID, !present.contains(id) else { continue }
            item.ekExternalID = nil
            item.projectedTitle = nil; item.projectedDue = nil; item.projectedNotes = nil
            if item.state == .projected { item.state = .readyToProject }
            if item.completedAt != nil { item.completionPending = true }
            count += 1
        }
        if count > 0 { try modelContext.save() }
        return count
    }

    public func clearExternalID(id: UUID) throws {
        guard let item = try fetchObligation(id: id) else { return }
        item.ekExternalID = nil
        try modelContext.save()
    }

    /// The reminder now says `title`, `due` and `notes`: recorded as written whatever the row says now, so a hand edit in
    /// Reminders is still told from ours. The row counts as projected only if it still says the same: one a re-read sent
    /// to review, or the user edited, while its reminder was being written stays as it is, and its own pass writes it.
    public func markProjected(id: UUID, externalID: String?, title: String, due: Date?, notes: String?) throws {
        guard let item = try fetchObligation(id: id) else { return }
        if let externalID { item.ekExternalID = externalID }
        item.projectedTitle = title
        item.projectedDue = due
        item.projectedNotes = notes
        let sameDue: Bool = switch (item.due, due) {
            case (nil, nil): true
            case (let a?, let b?): abs(a.timeIntervalSince(b)) < 60
            default: false
        }
        if item.state == .readyToProject, sameDue, ObligationSnapshot(item).reminderTitle == title, item.notes == notes { item.state = .projected }
        item.updatedAt = Date()
        try modelContext.save()
    }

    /// The review queue's one-tap confirm, also the manual editor's save: hand edits become overrides.
    public func confirm(id: UUID, edits: ObligationEdits = ObligationEdits()) throws {
        guard let item = try fetchObligation(id: id) else { return }
        let before = item.course
        applyEdits(edits, to: item)
        item.changeNote = nil
        item.conflictingDate = nil
        item.state = item.due == nil ? .awaitingDate : .readyToProject
        item.updatedAt = Date()
        recomputePoints(for: [before, item.course])   // a grade row or course changed: both shares are worked out again
        try modelContext.save()
    }

    public func addManual(title: String, due: Date?, dueHasTime: Bool, courseID: UUID?, componentName: String?, platform: Platform = .syllabusOnly,
                          notes: String?, notesFromSiri: Bool = false, deviceName: String) throws -> ObligationSnapshot {
        let item = Obligation(title: title)
        item.origin = .manual
        item.createdOn = deviceName
        item.confidence = 1
        item.due = due; item.dueHasTime = dueHasTime
        item.componentName = componentName
        item.platform = platform
        item.notes = notes
        item.notesFromSiri = notesFromSiri && notes != nil
        item.userOverrides = [.title, .due, .componentName, .notes] + (platform == .syllabusOnly ? [] : [.platform])
        item.course = try courseID.flatMap { try fetchCourse(id: $0) }
        item.state = due == nil ? .awaitingDate : .readyToProject
        modelContext.insert(item)
        recomputePoints(for: [item.course])
        try modelContext.save()
        return snapshot(item)
    }

    /// What a day plan may schedule: live, incomplete items due within the coming days, with their course's name.
    public func planObligations(from day: Date, days: Int = 7, calendar: Calendar = .current) throws -> [PlanObligation] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        return try fetchObligations()
            .filter { $0.deletedAt == nil && $0.completedAt == nil && ($0.due.map { $0 >= start && $0 < end } ?? false) }
            .map { PlanObligation(title: $0.title, course: $0.course?.displayName, component: $0.componentName, due: $0.due!, points: $0.pointsAtStake, notes: $0.notes) }
    }

    /// Hand edits to a course; each edited field becomes an override a later document leaves alone.
    public func updateCourse(id: UUID, edits: CourseEdits) throws {
        guard let course = try fetchCourse(id: id) else { return }
        let name = course.displayName
        Self.apply(edits, to: course)
        if course.displayName != name { rewriteReminders(of: course) }   // its items' reminders carry the name
        recomputePoints(for: course)   // weights, counts and the term's dates set the points at stake
        try modelContext.save()
    }

    /// A course entered by hand (the fallback for a course with no document yet). Every field given is an override; a
    /// name or code left empty is none, so the first document filed under the course fills it in.
    public func addCourse(_ edits: CourseEdits) throws -> CourseSnapshot {
        let course = Course(code: edits.code ?? "", title: edits.title ?? "")
        for (field, value) in [("title", edits.title), ("code", edits.code)] where !(value ?? "").allSatisfy(\.isWhitespace) { course.userOverrides.append(field) }
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

    /// The user's order, for Coverage and the Mac's sidebar alike; every course listed gets its position, the rest keep none.
    public func reorderCourses(_ ids: [UUID]) throws {
        let all = try modelContext.fetch(FetchDescriptor<Course>())
        for course in all { course.sortOrder = ids.firstIndex(of: course.id) }
        try modelContext.save()
    }

    /// The user's own deletion of one item. An item already deleted keeps its stamp (a stale action must not move it
    /// out of the deletion that took it, `Bin.wentWith`).
    public func softDelete(id: UUID) throws {
        guard let item = try fetchObligation(id: id), item.deletedAt == nil else { return }
        item.deletedAt = Date()
        item.updatedAt = Date()
        recomputePoints(for: [item.course])   // the rest of its grade row share what is on file
        try modelContext.save()
    }

    /// The user's own deletion of one item, undone (⌘Z, a shake): live again as it was. Its reminder went (or goes) with
    /// the deletion, so one that had it is queued for a new one, checked if it was checked; an item in review or waiting
    /// for a date stays so. An item that went with its course or document comes back only with them (Recently Deleted).
    public func undelete(id: UUID) throws {
        guard let item = try fetchObligation(id: id), item.deletedAt != nil, !item.retiredWithSource else { return }
        item.deletedAt = nil
        item.updatedAt = Date()
        if item.state == .projected { item.state = .readyToProject }
        if item.completedAt != nil { item.completionPending = true }
        recomputePoints(for: [item.course])
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
        if let notes = edits.notes { item.notes = notes; item.notesFromSiri = edits.notesFromSiri && notes != nil; item.userOverrides.appendIfMissing(.notes) }
        if let courseID = edits.courseID { item.course = try? courseID.flatMap { try fetchCourse(id: $0) } }
    }

    // MARK: Reconciliation (SPEC §4.4)

    /// `since`: when the snapshot the changes were worked out from was read. A check made in the app since (pending) and
    /// a row the app has changed since keep the app's word over the snapshot's; the next pass compares again.
    public func applyReconciliation(_ changes: [ReconcileChange], since: Date? = nil) throws {
        var courses: [Course?] = []
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
                ob.notes = ReminderDraft.trimmingBlankLines(item.notes).joined(separator: "\n").nilIfEmpty   // Horizon never wrote to it: every line is the user's
                ob.projectedNotes = ob.notes
                ob.userOverrides = [.title, .due, .notes]   // the user's own words: a document naming the same thing does not rewrite them
                modelContext.insert(ob)
            case .deletedInReminders(let id):
                if let ob = try fetchObligation(id: id), ob.deletedAt == nil { ob.deletedAt = Date(); ob.ekExternalID = nil; ob.updatedAt = Date(); courses.append(ob.course) }
            case .completion(let id, let date):
                // Unchecked in Reminders opens it again, skipped or done; checked there is done.
                if let ob = try fetchObligation(id: id), !ob.completionPending { ob.completedAt = date; ob.skippedAt = nil }
            case .userEdited(let id, let title, let due, let hasTime, let notes, let reminderTitle):
                if let ob = try fetchObligation(id: id), since.map({ ob.updatedAt <= $0 }) ?? true {
                    // Recorded as the reminder reads, course and all: a course renamed since leaves its old name there until the
                    // reminder is next written, and a title made from the new one would read as another edit on the next pass.
                    if let title { ob.title = title; ob.projectedTitle = reminderTitle; ob.userOverrides.appendIfMissing(.title) }
                    if let due { ob.due = due; ob.dueHasTime = hasTime; ob.projectedDue = due; ob.userOverrides.appendIfMissing(.due) }
                    if let notes { ob.notes = notes.nilIfEmpty; ob.projectedNotes = notes.nilIfEmpty; ob.notesFromSiri = false; ob.userOverrides.appendIfMissing(.notes) }   // typed in Reminders
                    ob.updatedAt = Date()
                }
            case .repairExternalID(let id, let externalID):
                if let ob = try fetchObligation(id: id) { ob.ekExternalID = externalID }
            }
        }
        recomputePoints(for: courses)
        try modelContext.save()
    }

    // MARK: Days

    /// Date-only dates are days, stored as an instant in the zone they were read in (an item's 23:59, a term's midnight).
    /// When the device's time zone changes each is moved to the same time of day in the new zone, so the day stays the
    /// day: in the app, in what the projector writes, and in what the reconciler compares (an EventKit date-only due
    /// comes back at 23:59 in the zone the device is in now, and the old instant would read as a hand edit). Timed
    /// dates are instants and stay. Returns how many rows moved. Run through `DayAnchor`.
    @discardableResult
    public func reanchorDays(from old: TimeZone, to new: TimeZone) throws -> Int {
        guard old.identifier != new.identifier else { return 0 }
        var from = Calendar(identifier: .gregorian); from.timeZone = old
        var to = Calendar(identifier: .gregorian); to.timeZone = new
        func move(_ date: Date) -> Date { to.date(from: from.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)) ?? date }
        var moved = 0
        for item in try fetchObligations() {
            var touched = false
            if !item.dueHasTime {
                if let due = item.due { item.due = move(due); touched = true }
                if let due = item.projectedDue { item.projectedDue = move(due) }
                if let other = item.conflictingDate { item.conflictingDate = move(other) }
            }
            if item.documentWords.contains(where: { !$0.dueHasTime && $0.due != nil }) {
                item.documentWords = item.documentWords.map { word in var word = word; if !word.dueHasTime, let due = word.due { word.due = move(due) }; return word }
                touched = true
            }
            if touched { moved += 1 }
        }
        for course in try fetchCourses() {
            if let start = course.termStart { course.termStart = move(start) }
            if let end = course.termEnd { course.termEnd = move(end) }
            if !course.noClassDates.isEmpty { course.noClassDates = course.noClassDates.map { ClosedDateRange(start: move($0.start), end: move($0.end), label: $0.label) } }
        }
        try modelContext.save()
        return moved
    }

    // MARK: Courses

    public func courses() throws -> [CourseSnapshot] {
        try modelContext.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.code)])).map(CourseSnapshot.init)
    }

    /// A live course, or nil (gone to the bin, erased, or never there).
    public func course(id: UUID) throws -> CourseSnapshot? {
        try fetchCourse(id: id).flatMap { $0.deletedAt == nil ? CourseSnapshot($0) : nil }
    }

    /// A live item, or nil.
    public func obligation(id: UUID) throws -> ObligationSnapshot? {
        try fetchObligation(id: id).flatMap { $0.deletedAt == nil ? snapshot($0) : nil }
    }

    /// The live courses' policies.
    public func policies() throws -> [PolicySnapshot] {
        try modelContext.fetch(FetchDescriptor<Policy>()).filter { $0.course?.deletedAt == nil && $0.course != nil }.map(PolicySnapshot.init)
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

/// The time zone the store's days are anchored in, kept in the App Group's defaults. Run `settle` at launch and on
/// `.NSSystemTimeZoneDidChange`, before a sync: when the zone has changed since, the days move with it
/// (`HorizonStore.reanchorDays`), so a date-only item is still due on its day and Reminders' copy of it does not read as
/// a hand edit. The first run only records the zone.
public enum DayAnchor {
    static let key = "dayAnchorZone"

    public static func settle(_ store: HorizonStore, suite: String = Identifiers.appGroup, zone: TimeZone = .current) async throws {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        if let recorded = defaults.string(forKey: key).flatMap(TimeZone.init(identifier:)), recorded.identifier != zone.identifier {
            try await store.reanchorDays(from: recorded, to: zone)
        }
        defaults.set(zone.identifier, forKey: key)
    }
}

extension Array where Element: Equatable {
    mutating func appendIfMissing(_ element: Element) { if !contains(element) { append(element) } }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
