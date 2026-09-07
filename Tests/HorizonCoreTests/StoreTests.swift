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
        _ = try await store.enqueueDocument(filename: "loose.pdf", sha256: "loose-failed", kind: "pdf", deviceName: "A")
        try await store.markDocument(id: try await store.documents().first { $0.sha256 == "loose-failed" }!.id, status: .failed, failure: "x")
        try await store.deleteCourse(id: calc.id)                     // once more, with a loose document on file
        #expect(try await store.documents().map(\.sha256) == ["loose-failed"])   // the course's document goes; a loose one stays
        try await Fixture.ingest(Fixture.calculus(), into: store)
        #expect(try await store.courses().map(\.id) == [calc.id])   // the same row, back
        #expect(try await store.obligations().count == 5)             // with its items
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

    @Test func aDocumentReadAgainAfterItsCourseOrItselfWasDeletedBringsItsItemsBack() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let originally = try await store.obligations().count
        #expect(originally == 5)
        // The user discards one item by hand: that one stays gone on every later read.
        let quiz = try await store.obligations().first { $0.title == "Quiz 1" }!
        try await store.softDelete(id: quiz.id)
        try await store.deleteCourse(id: calc.id)
        #expect(try await store.obligations().isEmpty)
        try await Fixture.ingest(Fixture.calculus(), into: store)   // the same syllabus, shared again
        let back = try await store.obligations()
        #expect(back.map(\.title).sorted() == ["Final Exam", "HW 1", "HW 2", "Midterm 1", "Quiz 1"])   // the course went with its documents: a fresh start, discarded quiz included
        #expect(!back.contains { $0.id == quiz.id })                                                    // as new rows: the old ones stay tombstones for Reminders
        #expect(try await store.obligations(includeDeleted: true).count == originally + 5)
        // The same after deleting the document itself.
        let doc = try await store.documents().first!
        try await store.deleteDocument(id: doc.id)
        #expect(try await store.obligations().isEmpty)
        try await Fixture.ingest(Fixture.calculus(), into: store)
        #expect(try await store.obligations().map(\.title).sorted() == ["Final Exam", "HW 1", "HW 2", "Midterm 1", "Quiz 1"])
    }

    @Test func aComponentsSiteIsKeptAndToldToTheNextDocument() async throws {
        let store = try Fixture.store()
        var syllabus = Fixture.calculus()
        syllabus.gradeComponents[0].platform = .webAssign
        try await Fixture.ingest(syllabus, into: store)
        let calc = try await store.courses().first!
        #expect(calc.gradeComponents.first?.platform == .webAssign)
        #expect(try await store.knownCourse(for: calc.id)?.components.first?.platform == .webAssign)
        // A schedule that says nothing about the site leaves it standing.
        let doc = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched7", kind: "pdf", deviceName: "A", courseID: calc.id)
        var schedule = Fixture.calculus(sha: "sched7"); schedule.course = nil; schedule.policies = []
        schedule.gradeComponents = [ParsedGradeComponent(name: "Homework", weight: 0.15, expectedCount: 12)]
        try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
        #expect(try await store.courses().first?.gradeComponents.first?.platform == .webAssign)
        // The user's own word on the site is an override a reissued syllabus leaves alone.
        try await store.updateCourse(id: calc.id, edits: CourseEdits(gradeComponents: [GradeComponent(name: "Homework", weight: 0.15, expectedCount: 10, platform: nil)]))
        try await Fixture.ingest(syllabus, into: store)
        #expect(try await store.courses().first?.gradeComponents.first?.platform == nil)
    }

    @Test func aPartialGradeTableMergesAndACompleteOneReplaces() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        // A schedule filed under the course knows two components and states one weight: the syllabus's table stays.
        let doc = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched4", kind: "pdf", deviceName: "A", courseID: calc.id)
        var schedule = Fixture.calculus(sha: "sched4"); schedule.course = nil; schedule.policies = []
        schedule.gradeComponents = [ParsedGradeComponent(name: "Homework", weight: 0.15, expectedCount: 12), ParsedGradeComponent(name: "Labs", weight: nil)]
        try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
        var course = try await store.courses().first!
        #expect(course.gradeComponents.map(\.name) == ["Homework", "Quizzes", "Final Exam", "Labs"])
        #expect(course.gradeComponents.first?.expectedCount == 12)                            // a stated fact updates
        // A reissued syllabus with a whole table replaces it.
        var reissue = Fixture.calculus(sha: "v2")
        reissue.gradeComponents = [ParsedGradeComponent(name: "Homework", weight: 0.2), ParsedGradeComponent(name: "Midterm", weight: 0.3), ParsedGradeComponent(name: "Final Exam", weight: 0.5)]
        try await Fixture.ingest(reissue, into: store)
        course = try await store.courses().first!
        #expect(course.gradeComponents.map(\.name) == ["Homework", "Midterm", "Final Exam"])
    }

    @Test func aTombstoneWhoseDocumentIsGoneNoLongerCapturesARereadItem() async throws {
        // Data from before the flag existed: the user discarded an item, then deleted its document from Documents.
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        try await store.softDelete(id: hw1.id)                                         // by hand: stays deleted on a re-read
        try await Fixture.ingest(Fixture.calculus(), into: store)
        #expect(try await store.obligations().map(\.title).contains("HW 1") == false)
        let doc = try await store.documents().first!
        try await store.deleteDocument(id: doc.id)                                     // the document goes, and its tombstones with it
        try await Fixture.ingest(Fixture.calculus(), into: store)
        #expect(try await store.obligations().map(\.title).contains("HW 1"))            // a fresh read is a fresh start
    }

    @Test func deletingADocumentRetiresWhatCameFromItAndNothingElse() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        // A schedule refreshes HW 1 and adds HW 3; the syllabus stays the source of everything else.
        let doc = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched3", kind: "pdf", deviceName: "A", courseID: calc.id)
        var schedule = Fixture.calculus(sha: "sched3"); schedule.course = nil; schedule.gradeComponents = []; schedule.policies = []
        schedule.obligations = [ParsedObligation(title: "HW 1", platform: .webAssign, componentName: "Homework", dateAsWritten: "9/10", due: Fixture.day(9, 10), status: .ready, pointsAtStake: nil, sourcePage: 1),
                                ParsedObligation(title: "HW 3", platform: .webAssign, componentName: "Homework", dateAsWritten: "9/24", due: Fixture.day(9, 24), status: .ready, pointsAtStake: nil, sourcePage: 1)]
        try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
        let syllabus = try await store.documents().first { $0.sha256 == "abc" }!
        let before = try await store.obligations().filter { $0.deletedAt == nil }.map(\.title)
        #expect(before.contains("HW 3") && before.contains("Quiz 1"))
        try await store.deleteDocument(id: syllabus.id)
        #expect(try await store.deletedDocuments().map(\.filename) == ["calc.pdf"])   // in the bin
        let live = try await store.obligations().filter { $0.deletedAt == nil }.map(\.title)
        #expect(live.sorted() == ["HW 1", "HW 3"])                                  // the schedule's items stay, the syllabus's go
        #expect(try await store.documents().map(\.sha256) == ["sched3"])
        #expect(try await store.obligations(includeDeleted: true).contains { $0.title == "Quiz 1" && $0.deletedAt != nil })   // a tombstone, so its reminder goes
        let record = try await store.eraseDocument(id: syllabus.id)
        #expect(record?.sha256 == "abc")                                             // gone for good, the file's name handed back for removal
        #expect(try await store.deletedDocuments().isEmpty)
        #expect(try await store.eraseDocument(id: syllabus.id) == nil)               // gone is gone
    }

    @Test func aDeletedCourseComesBackWithExactlyWhatItsDeletionTook() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let quiz = try await store.obligations().first { $0.title == "Quiz 1" }!
        try await store.softDelete(id: quiz.id)                                       // by hand, before
        try await store.deleteCourse(id: calc.id)
        #expect(try await store.courses().isEmpty)
        #expect(try await store.documents().isEmpty)
        #expect(try await store.deletedCourses().map(\.id) == [calc.id])
        #expect(try await store.deletedDocuments().isEmpty)                          // its document sits under it, not on its own
        try await store.restoreCourse(id: calc.id)
        #expect(try await store.courses().map(\.id) == [calc.id])
        #expect(try await store.deletedCourses().isEmpty)
        #expect(try await store.documents().map(\.filename) == ["calc.pdf"])
        #expect(try await store.obligations().map(\.title).sorted() == ["Final Exam", "HW 1", "HW 2", "Midterm 1"])   // the quiz stays deleted
        try await Fixture.ingest(Fixture.calculus(), into: store)                     // and stays deleted on a re-read: its tombstone still counts
        #expect(try await store.obligations().map(\.title).sorted() == ["Final Exam", "HW 1", "HW 2", "Midterm 1"])
    }

    @Test func aDeletedDocumentComesBackWithoutDoublingWhatTheCourseGainedMeanwhile() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let syllabus = try await store.documents().first!
        try await store.deleteDocument(id: syllabus.id)
        #expect(try await store.obligations().isEmpty)
        #expect(try await store.deletedDocuments().map(\.id) == [syllabus.id])
        // A schedule read meanwhile lists HW 2 afresh.
        let doc = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched5", kind: "pdf", deviceName: "A", courseID: calc.id)
        var schedule = Fixture.calculus(sha: "sched5"); schedule.course = nil; schedule.gradeComponents = []; schedule.policies = []
        schedule.obligations = [ParsedObligation(title: "HW 2", platform: .webAssign, componentName: "Homework", dateAsWritten: "9/16", due: Fixture.day(9, 16), status: .ready, pointsAtStake: nil, sourcePage: 1)]
        try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
        try await store.restoreDocument(id: syllabus.id)
        let back = try await store.obligations()
        #expect(back.map(\.title).sorted() == ["Final Exam", "HW 1", "HW 2", "Midterm 1", "Quiz 1"])   // one HW 2, the schedule's
        #expect(back.first { $0.title == "HW 2" }?.sourceDocumentID == doc.id)
        #expect(back.first { $0.title == "HW 1" }?.pointsAtStake == 1.5)             // points recomputed over what is back
        #expect(try await store.documents().count == 2)
        #expect(try await store.deletedDocuments().isEmpty)
    }

    @Test func restoringADocumentRestoresTheCourseItSitsUnder() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let syllabus = try await store.documents().first!
        try await store.deleteDocument(id: syllabus.id)     // on its own first
        try await store.deleteCourse(id: calc.id)           // then the course: the document is hidden under it
        #expect(try await store.deletedDocuments().isEmpty)
        #expect(try await store.deletedCourses().count == 1)
        try await store.restoreCourse(id: calc.id)
        #expect(try await store.deletedDocuments().map(\.id) == [syllabus.id])   // the course's deletion did not take it, so it is still in the bin, now on its own
        #expect(try await store.obligations().isEmpty)
        try await store.deleteCourse(id: calc.id)
        try await store.restoreDocument(id: syllabus.id)    // restoring it brings the course back too
        #expect(try await store.courses().map(\.id) == [calc.id])
        #expect(try await store.obligations().count == 5)
    }

    @Test func theBinEmptiesAfterThirtyDaysAndAnErasedCourseStillRevives() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        try await store.deleteCourse(id: calc.id)
        #expect(try await store.expireBin(now: Date().addingTimeInterval(29 * 86400)).isEmpty)
        let files = try await store.expireBin(now: Date().addingTimeInterval(31 * 86400))
        #expect(files.map(\.sha256) == ["abc"])                                       // the file can go
        #expect(try await store.deletedCourses().isEmpty)                            // out of the bin, still a tombstone
        #expect(try await store.courses().isEmpty)
        #expect(try await store.obligations(includeDeleted: true).count == 5)       // its items too, for Reminders
        try await Fixture.ingest(Fixture.calculus(), into: store)                     // the same syllabus, shared again
        #expect(try await store.courses().map(\.id) == [calc.id])                    // the same row, fresh items
        #expect(try await store.obligations().count == 5)
        try await store.restoreCourse(id: calc.id)                                    // nothing to restore: a no-op
        #expect(try await store.obligations().count == 5)
        // A document on its own expires the same way.
        let doc = try await store.documents().first!
        try await store.deleteDocument(id: doc.id)
        #expect(try await store.expireBin(now: Date().addingTimeInterval(31 * 86400)).map(\.id) == [doc.id])
        #expect(try await store.documents().isEmpty)
        #expect(try await store.deletedDocuments().isEmpty)
    }

    @Test func aDeletedDocumentSharedAgainIsReadAfresh() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let doc = try await store.documents().first!
        try await store.deleteDocument(id: doc.id)
        let again = try await store.enqueueDocument(filename: "calc.pdf", sha256: "abc", kind: "pdf", deviceName: "A")
        #expect(again.id == doc.id && again.status == .queued && again.deletedAt == nil)   // the same record, back and queued
        #expect(try await store.deletedDocuments().isEmpty)
        #expect(try await store.queuedDocuments().map(\.id) == [doc.id])
    }

    @Test func purgeTakesErasedCoursesWithTheirTombstones() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        try await store.eraseCourse(id: calc.id)
        #expect(try await store.purgeTombstones(now: Date()) == 0)
        #expect(try await store.purgeTombstones(now: Date().addingTimeInterval(181 * 86400)) == 6)   // five items and the course
        #expect(try await store.obligations(includeDeleted: true).isEmpty)
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
