import Foundation
import Testing
import IngestKit
@testable import HorizonCore

struct StoreTests {
    @Test func ingestCreatesCourseComponentsPoliciesAndStates() async throws {
        let store = try Fixture.store()
        let summary = try await Fixture.ingest(Fixture.calculus(quizStatus: .needsReview), into: store)
        #expect(summary.created == 5 && summary.pendingReview == 1 && summary.courseCode == "MA-UY 1124")
        let course = try await store.courses().first!
        #expect(course.title == "Calculus II" && course.gradeComponents.map(\.name) == ["Homework", "Quizzes", "Final Exam"] && course.lastIngested != nil)
        let states = Dictionary(uniqueKeysWithValues: try await store.obligations().map { ($0.title, $0.state) })
        #expect(states == ["HW 1": .readyToProject, "HW 2": .readyToProject, "Quiz 1": .pendingReview, "Midterm 1": .readyToProject, "Final Exam": .awaitingDate])
        let queue = try await store.reviewQueue().map(\.title)
        let docStatus = try await store.documents().first?.status
        #expect(queue == ["Quiz 1"] && docStatus == .parsed)
    }

    @Test func courseEditsSurviveAReissuedDocument() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let course = try await store.courses().first!
        try await store.updateCourse(id: course.id, edits: CourseEdits(title: "Calc 2", term: .some("Fall 2026"), termEnd: .some(nil)))
        var again = Fixture.calculus(sha: "v2"); again.course?.title = "Calculus II, revised"
        try await Fixture.ingest(again, into: store)
        let after = try await store.courses().first!
        #expect(after.title == "Calc 2" && after.displayName == "Calc 2" && after.term == "Fall 2026")   // the hand edits stay
        #expect(after.termEnd == nil)                                                                   // an edited field is not refilled by the document
        let hw = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(hw.reminderTitle == "HW 1 · Calc 2" && hw.courseName == "Calc 2")                        // Reminders carry the course's name
    }

    @Test func aHandMadeCourseAndEditedComponentsOutliveDocuments() async throws {
        let store = try Fixture.store()
        let made = try await store.addCourse(CourseEdits(title: "Studio", code: "ART-UY 101", gradeComponents: [GradeComponent(name: "Critiques", weight: 0.5, cadence: .weekly)]))
        #expect(made.displayName == "Studio" && made.gradeComponents.map(\.name) == ["Critiques"])
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first { $0.code == "MA-UY 1124" }!
        try await store.updateCourse(id: calc.id, edits: CourseEdits(gradeComponents: [GradeComponent(name: "Labs", weight: 1)]))
        try await Fixture.ingest(Fixture.calculus(sha: "v2"), into: store)   // the reissued document carries the original table
        let after = try await store.courses().first { $0.code == "MA-UY 1124" }!
        #expect(after.gradeComponents.map(\.name) == ["Labs"])            // the hand-edited table stays
        #expect(try await store.courses().count == 2)
    }

    @Test func deletingACourseRetiresItsItemsAndADocumentRevivesIt() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        try await store.deleteCourse(id: calc.id)
        #expect(try await store.courses().isEmpty)
        #expect(try await store.obligations().allSatisfy { $0.deletedAt != nil })
        try await Fixture.ingest(Fixture.calculus(sha: "again"), into: store)
        #expect(try await store.courses().map(\.id) == [calc.id])   // the same row, back
    }

    @Test func coursesKeepTheUsersOrder() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let art = try await store.addCourse(CourseEdits(title: "Studio", code: "ART-UY 101"))
        let calc = try await store.courses().first { $0.code == "MA-UY 1124" }!
        try await store.reorderCourses([calc.id, art.id])
        let orders = Dictionary(uniqueKeysWithValues: try await store.courses().map { ($0.code, $0.sortOrder) })
        #expect(orders == ["MA-UY 1124": 0, "ART-UY 101": 1])
    }

    @Test func aDocumentFiledUnderACourseReadsAsThatCourse() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        // The schedule names no course; the user filed it under Calculus from the course page.
        let doc = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched", kind: "pdf", deviceName: "A", courseID: calc.id)
        #expect(doc.courseID == calc.id)
        let known = try await store.knownCourse(for: calc.id)
        #expect(known?.code == "MA-UY 1124" && known?.components.map(\.name) == ["Homework", "Quizzes", "Final Exam"] && known?.components.first?.platform == .webAssign)
        var schedule = Fixture.calculus(sha: "sched"); schedule.course = nil; schedule.gradeComponents = []; schedule.policies = []
        schedule.obligations = [ParsedObligation(title: "HW 3", platform: .syllabusOnly, componentName: "Homework", dateAsWritten: "9/23", due: Fixture.day(9, 23), status: .ready, pointsAtStake: nil, sourcePage: 1)]
        let summary = try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
        #expect(summary.courseCode == "MA-UY 1124" && summary.created == 1)
        let hw3 = try await store.obligations().first { $0.title == "HW 3" }!
        #expect(hw3.courseID == calc.id && hw3.pointsAtStake == 1.5)   // 15% over the syllabus's stated ten
        #expect(try await store.courses().count == 1)
    }

    @Test func aFiledDocumentNamingAnotherCourseStaysPutWithAWarning() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let doc = try await store.enqueueDocument(filename: "other.pdf", sha256: "other", kind: "pdf", deviceName: "A", courseID: calc.id)
        var physics = Fixture.calculus(sha: "other"); physics.course = ParsedCourse(code: "PH-UY 1013", title: "Physics I")
        physics.obligations = [ParsedObligation(title: "Lab 1 report", platform: .syllabusOnly, componentName: nil, dateAsWritten: "9/18", due: Fixture.day(9, 18), status: .ready, pointsAtStake: nil, sourcePage: 1)]
        let summary = try await store.ingest(physics, documentID: doc.id, calendar: Fixture.calendar)
        #expect(summary.warnings.contains { $0.contains("PH-UY 1013") && $0.contains("filed under Calculus II") })
        let courses = try await store.courses()
        #expect(courses.count == 1 && courses[0].title == "Calculus II")   // the user's filing wins; the other course's facts do not touch this one
        #expect(try await store.obligations().first { $0.title == "Lab 1 report" }?.courseID == calc.id)
    }

    @Test func changeNotesNameBothDocuments() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let doc = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched2", kind: "pdf", deviceName: "A", courseID: calc.id)
        var schedule = Fixture.calculus(sha: "sched2"); schedule.course = nil; schedule.gradeComponents = []; schedule.policies = []
        schedule.obligations = [ParsedObligation(title: "HW 1", platform: .webAssign, componentName: "Homework", dateAsWritten: "9/10", due: Fixture.day(9, 10), status: .ready, pointsAtStake: nil, sourcePage: 1)]
        try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(hw1.state == .pendingReview && hw1.changeNote?.hasPrefix("schedule.pdf says due Sep 9 → Sep 10") == true && hw1.changeNote?.hasSuffix("earlier from calc.pdf") == true)
    }

    @Test func filingALooseDocumentMovesItsItemsUnderTheCourse() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        var loose = Fixture.calculus(sha: "loose"); loose.course = nil; loose.gradeComponents = []; loose.policies = []
        loose.obligations = [ParsedObligation(title: "Quiz 4", platform: .syllabusOnly, componentName: nil, dateAsWritten: "10/22", due: Fixture.day(10, 22), status: .ready, pointsAtStake: nil, sourcePage: 1)]
        try await Fixture.ingest(loose, into: store)   // no hint and no course named: it lands nowhere
        #expect(try await store.obligations().first { $0.title == "Quiz 4" }?.courseID == nil)
        let doc = try await store.documents().first { $0.sha256 == "loose" }!
        let calc = try await store.courses().first!
        try await store.assignDocument(id: doc.id, to: calc.id)
        let quiz = try await store.obligations().first { $0.title == "Quiz 4" }!
        #expect(quiz.courseID == calc.id && quiz.componentName == "Quizzes")
        #expect(quiz.pointsAtStake == 6)   // 12% over the two quizzes now on file
        #expect(try await store.documents().first { $0.sha256 == "loose" }?.courseID == calc.id)
    }

    @Test func sameDocumentTwiceIsRecordedOnce() async throws {
        let store = try Fixture.store()
        let a = try await store.enqueueDocument(filename: "calc.pdf", sha256: "abc", kind: "pdf", deviceName: "iPhone")
        let b = try await store.enqueueDocument(filename: "calc (1).pdf", sha256: "abc", kind: "pdf", deviceName: "iPhone")
        let count = try await store.documents().count
        #expect(a.id == b.id && count == 1)
    }

    @Test func reviewConfirmWithEditsSetsOverrides() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(quizStatus: .needsReview), into: store)
        let quiz = try await store.reviewQueue().first!
        try await store.confirm(id: quiz.id, edits: ObligationEdits(title: "Quiz 1 (chapters 1–2)", due: .some(Fixture.day(9, 18))))
        let confirmed = try await store.obligations().first { $0.id == quiz.id }!
        #expect(confirmed.state == .readyToProject && confirmed.userOverrides == [.title, .due] && confirmed.title == "Quiz 1 (chapters 1–2)")
        let remaining = try await store.reviewQueue()
        #expect(remaining.isEmpty)
    }

    @Test func courselessDocumentsMatchOnReingest() async throws {
        let store = try Fixture.store()
        var shot = Fixture.calculus(sha: "shot1"); shot.course = nil; shot.gradeComponents = []
        try await Fixture.ingest(shot, into: store)
        var again = Fixture.calculus(sha: "shot2"); again.course = nil; again.gradeComponents = []   // a second crop of the same list
        let summary = try await Fixture.ingest(again, into: store)
        #expect(summary.created == 0 && summary.unchanged == 5)
        let count = try await store.obligations().count
        #expect(count == 5)
    }

    @Test func coursesWithDifferentCodesStaySeparate() async throws {
        let store = try Fixture.store()
        var lecture = Fixture.calculus(sha: "lec"); lecture.course?.code = "CHEM 2301"; lecture.course?.title = "Organic Chemistry I"
        var lab = Fixture.calculus(sha: "lab"); lab.course?.code = "CHEM 2311"; lab.course?.title = "Organic Chemistry I Lab"
        try await Fixture.ingest(lecture, into: store)
        try await Fixture.ingest(lab, into: store)
        let courses = try await store.courses()
        #expect(courses.count == 2)
    }

    @Test func similarTitlesDoNotCaptureEachOther() async throws {
        // "Essay draft" (9/20) next to an existing "Essay" (10/1): a new row, not a retitled old one.
        let store = try Fixture.store()
        var first = Fixture.calculus(sha: "e1")
        first.obligations = [ParsedObligation(title: "Essay", dateAsWritten: "Oct 1", due: Fixture.day(10, 1), status: .ready)]
        try await Fixture.ingest(first, into: store)
        var revised = Fixture.calculus(sha: "e2")
        revised.obligations = [ParsedObligation(title: "Essay", dateAsWritten: "Oct 1", due: Fixture.day(10, 1), status: .ready),
                               ParsedObligation(title: "Essay draft", dateAsWritten: "Sep 20", due: Fixture.day(9, 20), status: .ready)]
        let summary = try await Fixture.ingest(revised, into: store)
        #expect(summary.created == 1 && summary.updated == 0)
        // And an identical re-ingest of "Project" (TBA) beside "Project proposal" (9/20) changes nothing.
        var tbd = Fixture.calculus(sha: "p1")
        tbd.obligations = [ParsedObligation(title: "Project", dateAsWritten: "TBA", due: nil, status: .awaitingDate),
                           ParsedObligation(title: "Project proposal", dateAsWritten: "Sep 20", due: Fixture.day(9, 20), status: .ready)]
        try await Fixture.ingest(tbd, into: store)
        var same = tbd; same.document = DocumentInfo(name: "p.pdf", sha256: "p2", kind: .pdf, pageCount: 1)
        let repeat_ = try await Fixture.ingest(same, into: store)
        #expect(repeat_.created == 0 && repeat_.updated == 0)
    }

    @Test func failedDocumentsCanBeQueuedAgain() async throws {
        let store = try Fixture.store()
        let doc = try await store.enqueueDocument(filename: "s.pdf", sha256: "f1", kind: "pdf", deviceName: "A")
        try await store.markDocument(id: doc.id, status: .failed, failure: "no model")
        let again = try await store.enqueueDocument(filename: "s.pdf", sha256: "f1", kind: "pdf", deviceName: "A")
        #expect(again.id == doc.id && again.status == .queued && again.failure == nil)
    }

    @Test func tbdResolvesOnReingest() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        var revised = Fixture.calculus(sha: "v2")
        revised.obligations[4] = ParsedObligation(title: "Final Exam", componentName: "Final Exam", dateAsWritten: "Dec 18", due: Fixture.day(12, 18), status: .ready)
        try await Fixture.ingest(revised, into: store)
        let final = try await store.obligations().first { $0.title == "Final Exam" }!
        let total = try await store.obligations().count
        #expect(final.state == .readyToProject && final.due != nil && total == 5)   // matched the TBD row, no duplicate
    }

    @Test func tombstonesPurgeAfter180Days() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        try await store.softDelete(id: hw1.id)
        let early = try await store.purgeTombstones(now: Date())
        let late = try await store.purgeTombstones(now: Date().addingTimeInterval(181 * 86400))
        let left = try await store.obligations(includeDeleted: true).count
        #expect(early == 0 && late == 1 && left == 4)
    }

    @Test func coordinatorKeepsDocumentsQueuedWhileTheModelLoads() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).txt")
        try "syllabus".write(to: file, atomically: true, encoding: .utf8)
        let notReady = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in throw IngestError.modelNotReady("loading") })
        _ = try await notReady.enqueue(fileURL: file)
        let reports = await notReady.drain()
        let doc = try await store.documents().first!
        #expect(reports.count == 1 && doc.status == .queued && doc.failure?.contains("Waiting") == true)   // still queued: retried next drain

        let noCloud = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in throw IngestError.cloudUnavailable("offline") })
        _ = await noCloud.drain()
        let parked = try await store.documents().first!
        #expect(parked.status == .awaitingCloudParse)   // a genuine cloud need waits for BGProcessingTask

        let parses = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in Fixture.calculus() })
        let done = await parses.drain()
        let parsed = try await store.documents().first!
        #expect(done.first?.summary?.created == 5 && parsed.status == .parsed)
    }

    @Test func coordinatorForwardsProgressWithTheDocument() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).txt")
        try "syllabus".write(to: file, atomically: true, encoding: .utf8)
        let events = EventLog()
        let coordinator = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", progress: { p in events.append(p) }, parse: { _, options in
            options.progress(.started(document: "x", textChunks: 1, images: 0))
            options.progress(.partial(chunk: 0, obligations: [ProvisionalObligation(id: "0-0", title: "HW 1", dateAsWritten: "Wed 9/9")]))
            options.progress(.finished(obligations: 5))
            return Fixture.calculus()
        })
        let doc = try await coordinator.enqueue(fileURL: file)
        _ = await coordinator.drain()
        let seen = events.all
        #expect(seen.count == 3 && seen.allSatisfy { $0.documentID == doc.id && $0.filename == file.lastPathComponent })
        if case .partial(_, let items) = seen[1].event { #expect(items.first?.title == "HW 1") } else { Issue.record("expected a partial event") }
    }

    @Test func coordinatorDrainsQueuedFilesAndSkipsOtherDevicesFiles() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        let coordinator = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).txt")
        try "not a syllabus".write(to: file, atomically: true, encoding: .utf8)
        let doc = try await coordinator.enqueue(fileURL: file)
        #expect(doc.status == .queued && storage.exists(sha256: doc.sha256, extension: "txt"))
        // A document recorded by another device, whose bytes are not here, is left alone.
        _ = try await store.enqueueDocument(filename: "elsewhere.pdf", sha256: "0000", kind: "pdf", deviceName: "iPad")
        let queued = try await store.queuedDocuments().count
        #expect(queued == 2)
    }
}


final class EventLog: @unchecked Sendable {
    private var events: [DocumentProgress] = []
    private let lock = NSLock()
    func append(_ p: DocumentProgress) { lock.withLock { events.append(p) } }
    var all: [DocumentProgress] { lock.withLock { events } }
}
