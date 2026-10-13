import Foundation
import Testing
import CoreData
import _SwiftData_CoreData
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

    /// A store opened at a path (a copy, for testing) can never be the user's: opening one migrates it to the build's
    /// schema, and an old build doing that to the user's store once cut fields out of it.
    @Test func aScratchStoreIsNeverTheUsers() {
        let folders = [URL(fileURLWithPath: "/Users/someone/Library/Application Support/Horizon", isDirectory: true)]
        #expect(HorizonContainer.isUserStoreFolder(URL(fileURLWithPath: "/Users/someone/Library/Application Support/Horizon/Horizon.store"), folders: folders))
        #expect(HorizonContainer.isUserStoreFolder(URL(fileURLWithPath: "/Users/someone/Library/Application Support/Scratch/../Horizon/Horizon.store"), folders: folders))   // however it is spelled
        #expect(HorizonContainer.isUserStoreFolder(URL(fileURLWithPath: "/Users/someone/Library/Application Support/Horizon", isDirectory: true), folders: folders))
        #expect(!HorizonContainer.isUserStoreFolder(URL(fileURLWithPath: "/Users/someone/Library/Application Support/Horizon Scratch/Horizon.store"), folders: folders))   // a neighbour whose name starts the same
        #expect(!HorizonContainer.isUserStoreFolder(URL(fileURLWithPath: "/tmp/scratch/Horizon.store"), folders: folders))
        #expect(HorizonContainer.userStoreFolders.contains { $0.path.hasSuffix("Application Support/Horizon") })
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
        #expect(hw1.state == .pendingReview && hw1.changeNote?.hasPrefix("schedule says due Sep 9 → Sep 10") == true && hw1.changeNote?.hasSuffix("earlier from calc") == true)   // documents by the app's name for them
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
        _ = try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
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
        _ = try await store.ingest(schedule, documentID: doc.id, calendar: Fixture.calendar)
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

        let noCloud = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in throw IngestError.claudeUnavailable("no connection") })
        _ = await noCloud.drain()
        let parked = try await store.documents().first!
        #expect(parked.status == .awaitingCloudParse && parked.failure == "no connection")   // waits for Claude: a processing task with the network, or the user's word
        // The user's word: the device may read this one. The coordinator hands the parser the device route for it alone.
        try await store.readOnDevice(id: parked.id)
        let routes = Routes()
        let onDevice = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, options in routes.append(options.route); throw IngestError.modelNotReady("loading") })
        _ = await onDevice.drain()
        #expect(routes.value == [.onDevice])
        #expect(try await store.documents().first?.status == .queued)   // cleared for the device, and back in the queue

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
            options.progress(.started(document: "x", textChunks: 1, images: 0, resumed: 0))
            options.progress(.partial(chunk: 0, obligations: [ProvisionalObligation(id: "0-0", title: "HW 1", dateAsWritten: "Wed 9/9")]))
            options.progress(.finished(obligations: 5))
            return Fixture.calculus()
        })
        let doc = try await coordinator.enqueue(fileURL: file)
        _ = await coordinator.drain()
        let seen = events.all
        #expect(seen.count == 3 && seen.allSatisfy { $0.documentID == doc.id && $0.name == DocumentName.tidy(file.lastPathComponent) })
        if case .partial(_, let items) = seen[1].event { #expect(items.first?.title == "HW 1") } else { Issue.record("expected a partial event") }
    }

    @Test func aDocumentIsNamedAlongTheWayAndTheNameOutlivesAFailedRead() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MA-UY_1124_syllabus_\(UUID().uuidString.prefix(6)).txt")
        try "syllabus".write(to: file, atomically: true, encoding: .utf8)
        let asked = Requests()
        // The read names the document, then Claude cannot be reached: the document waits, named.
        let fails = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, options in
            asked.append(options.titleRequest)
            options.progress(.named(title: "Calculus II Syllabus"))
            throw IngestError.claudeUnavailable("no connection")
        })
        let doc = try await fails.enqueue(fileURL: file)
        #expect(doc.title == nil && doc.displayName.hasPrefix("MA-UY 1124 syllabus"))   // until it has a title: the file's name, tidied
        _ = await fails.drain()
        try await Task.sleep(for: .milliseconds(50))   // the title is kept off the progress callback
        let waiting = try await store.documents().first!
        #expect(waiting.status == .awaitingCloudParse && waiting.title == "Calculus II Syllabus" && waiting.displayName == "Calculus II Syllabus")
        #expect(asked.value.first??.filename == file.lastPathComponent)
        // The next read is not asked to name it again, and the reading bar is given the title.
        let events = EventLog()
        let reads = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", progress: { events.append($0) }, parse: { _, options in
            asked.append(options.titleRequest)
            options.progress(.started(document: "x", textChunks: 1, images: 0, resumed: 0))
            return Fixture.calculus()
        })
        _ = await reads.drain()
        #expect(asked.value.count == 2 && asked.value[1] == nil)
        #expect(events.all.first?.name == "Calculus II Syllabus")
        // A title on file stands: a later naming does not replace it.
        try await store.setDocumentTitle(id: doc.id, title: "Something Else")
        #expect(try await store.documents().first?.title == "Calculus II Syllabus")
    }

    @Test func documentsOnFileAreNamedLaterAndAskedOnlyOnce() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        var ids: [UUID] = []
        for name in ["calc.txt", "scan.txt", "lab.txt"] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(name)")
            try name.write(to: file, atomically: true, encoding: .utf8)
            let quiet = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in Fixture.calculus(sha: name) })
            ids.append(try await quiet.enqueue(fileURL: file, filename: name).id)
            _ = await quiet.drain()
        }
        #expect(try await store.untitledDocuments().count == 3)
        let calls = Requests()
        let namer = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in Fixture.calculus() }, name: { _, request, digest in
            calls.append(request)
            #expect(digest?.contains("Calculus II") == true && digest?.contains("HW 1") == true || request.filename != "lab.txt")   // what was read from it, for a picture
            return request.filename == "scan.txt" ? .nothing : .titled("Calculus II \(request.filename == "calc.txt" ? "Syllabus" : "Lab Schedule")")
        })
        await namer.nameUntitled()
        let named = try await store.documents()
        #expect(Set(named.map(\.displayName)) == ["Calculus II Syllabus", "Calculus II Lab Schedule", "scan"])
        #expect(calls.value.compactMap { $0?.course }.allSatisfy { $0 == "Calculus II" })   // the course it is filed under goes with the question
        await namer.nameUntitled()
        #expect(calls.value.count == 3)   // the one the model had no name for is not asked again
        // A model that is not there ends the pass, and the document is asked another time.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))-late.txt")
        try "late".write(to: file, atomically: true, encoding: .utf8)
        let away = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, _ in Fixture.calculus(sha: "late") }, name: { _, _, _ in .unavailable })
        _ = try await away.enqueue(fileURL: file, filename: "late.txt")
        _ = await away.drain()
        await away.nameUntitled()
        #expect(try await store.untitledDocuments().map(\.filename) == ["late.txt"])
    }

    @Test func aReadThatStopsGoesOnFromItsCheckpoint() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).txt")
        try "syllabus".write(to: file, atomically: true, encoding: .utf8)
        // The first read finishes one part, keeps it, then is cut off (the app suspended): the document stays queued.
        let cut = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, options in
            await options.checkpoint?(IngestCheckpoint(route: .onDevice, textChunks: 2, images: 0))
            throw CancellationError()
        })
        let doc = try await cut.enqueue(fileURL: file)
        _ = await cut.drain()
        let paused = try await store.documents().first!
        #expect(paused.status == .queued && paused.failure == nil)
        let kept = try await store.checkpoint(for: doc.id).map { try IngestCheckpoint(data: $0) }
        #expect(kept?.textChunks == 2 && kept?.route == .onDevice)
        // The next read is handed the checkpoint, finishes, and the checkpoint goes.
        let resumed = Resumed()
        let goesOn = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "Mac", parse: { _, options in
            resumed.value = options.resume
            return Fixture.calculus()
        })
        _ = await goesOn.drain()
        #expect(resumed.value?.textChunks == 2 && resumed.value?.route == .onDevice)
        let done = try await store.documents().first!
        #expect(done.status == .parsed)
        #expect(try await store.checkpoint(for: doc.id) == nil)
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

final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DocumentTitleRequest?] = []
    var value: [DocumentTitleRequest?] { lock.withLock { stored } }
    func append(_ request: DocumentTitleRequest?) { lock.withLock { stored.append(request) } }
}

final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: IngestCheckpoint?
    var value: IngestCheckpoint? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class Routes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [IngestOptions.RoutePolicy] = []
    var value: [IngestOptions.RoutePolicy] { lock.withLock { stored } }
    func append(_ route: IngestOptions.RoutePolicy) { lock.withLock { stored.append(route) } }
}

/// What a deletion, a hand edit or a second document does to a read, and what follows from them: points, the bin's
/// order, freshness, failures that a retry cannot fix, the store's generation, days across time zones.
struct StoreFollowThroughTests {
    @Test func aReadFinishingIntoTheBinStaysThereAndARestoreReadsItAgain() async throws {
        let store = try Fixture.store()
        let doc = try await store.enqueueDocument(filename: "calc.pdf", sha256: "abc", kind: "pdf", deviceName: "A")
        try await store.saveCheckpoint(id: doc.id, data: Data("parts read".utf8))
        try await store.deleteDocument(id: doc.id)                                      // the wrong file: deleted while it is read
        let summary = try await store.ingest(Fixture.calculus(), documentID: doc.id, calendar: Fixture.calendar)
        let live = try await store.obligations(), courses = try await store.courses(), toWrite = try await store.pendingProjection()
        #expect(summary.binned && summary.created == 0 && live.isEmpty && courses.isEmpty && toWrite.isEmpty)
        #expect(try await store.deletedDocuments().map(\.id) == [doc.id])
        #expect(try await store.checkpoint(for: doc.id) != nil)                         // what was read waits with it
        // Restored, it is queued again, and read.
        try await store.restoreDocument(id: doc.id)
        #expect(try await store.queuedDocuments().map(\.id) == [doc.id])
        let again = try await store.ingest(Fixture.calculus(), documentID: doc.id, calendar: Fixture.calendar)
        #expect(!again.binned && again.created == 5)
    }

    @Test func aCourseDeletedWhileItsDocumentIsReadStaysDeleted() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let schedule = try await store.enqueueDocument(filename: "schedule.pdf", sha256: "sched", kind: "pdf", deviceName: "A", courseID: calc.id)
        try await store.deleteCourse(id: calc.id)
        let summary = try await store.ingest(Fixture.calculus(sha: "sched"), documentID: schedule.id, calendar: Fixture.calendar)
        let courses = try await store.courses(), live = try await store.obligations(), binned = try await store.deletedCourses()
        #expect(summary.binned && courses.isEmpty && live.isEmpty && binned.map(\.id) == [calc.id])
        #expect(try await store.deletedDocuments().isEmpty)                              // both documents sit under the course
        // The course back: the schedule with it, queued, and read into it without doubling anything.
        try await store.restoreCourse(id: calc.id)
        #expect(try await store.queuedDocuments().map(\.id) == [schedule.id])
        _ = try await store.ingest(Fixture.calculus(sha: "sched"), documentID: schedule.id, calendar: Fixture.calendar)
        #expect(try await store.obligations().count == 5)
    }

    @Test func aDocumentQueuedBeforeItsCourseWasDeletedDoesNotBringItBack() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let loose = try await store.enqueueDocument(filename: "update.pdf", sha256: "upd", kind: "pdf", deviceName: "A")   // its course is known only once read
        try await store.deleteCourse(id: calc.id)
        let summary = try await store.ingest(Fixture.calculus(sha: "upd"), documentID: loose.id, calendar: Fixture.calendar)
        let courses = try await store.courses(), documents = try await store.documents(), alone = try await store.deletedDocuments()
        #expect(summary.binned && courses.isEmpty && documents.isEmpty && alone.isEmpty)  // it went into the bin with the course
        try await store.restoreCourse(id: calc.id)
        #expect(try await store.queuedDocuments().map(\.id) == [loose.id])
        // Shared after the deletion, a document is a fresh request and brings the course back.
        try await store.deleteCourse(id: calc.id)
        try await Fixture.ingest(Fixture.calculus(sha: "new"), into: store)
        #expect(try await store.courses().map(\.id) == [calc.id])
    }

    @Test(.timeLimit(.minutes(1))) func deletingADocumentStopsItsReadAndTheDrainGoesOn() async throws {
        let store = try Fixture.store()
        let fileA = try Fixture.file("a.txt", "first"), fileB = try Fixture.file("b.txt", "second"), fileC = try Fixture.file("c.txt", "third")
        let held = try DocumentStorage.sha256(fileAt: fileC)   // the newest is read first
        let started = Gate(), parsed = Counter()
        let coordinator = IngestCoordinator(store: store, storage: DocumentStorage.temporary(), sync: nil, deviceName: "A", parse: { url, _ in
            let sha = url.deletingPathExtension().lastPathComponent
            parsed.append(sha)
            if sha == held { await started.release(); try await Task.sleep(for: .seconds(30)) }   // a long read, stopped only by its cancellation
            return Fixture.calculus(sha: sha)
        })
        let a = try await coordinator.enqueue(fileURL: fileA), b = try await coordinator.enqueue(fileURL: fileB), c = try await coordinator.enqueue(fileURL: fileC)
        let drain = Task { await coordinator.drain() }
        await started.wait()
        #expect(await coordinator.documentBeingRead == c.id)
        try await coordinator.deleteDocument(id: b.id)                                  // waiting its turn: never read
        try await coordinator.deleteDocument(id: c.id)                                  // being read: the read stops
        let reports = await drain.value
        #expect(parsed.value == [c.sha256, a.sha256])
        #expect(reports.map(\.document.id) == [a.id])
        #expect(try await store.obligations().count == 5)
        #expect(Set(try await store.deletedDocuments().map(\.id)) == [b.id, c.id])
        #expect(try await store.document(id: c.id)?.status == .queued)                  // unread, for a restore to read
        #expect(await coordinator.documentBeingRead == nil)
    }

    @Test func handEditsAreNotNewItemsOnTheNextRead() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        try await store.confirm(id: hw1.id, edits: ObligationEdits(title: "HW 1 — sections 7.1 to 7.3"))   // renamed
        let recitation = try await store.addCourse(CourseEdits(title: "Calculus Recitation", code: "MA-UY 1124R"))
        let quiz = try await store.obligations().first { $0.title == "Quiz 1" }!
        try await store.confirm(id: quiz.id, edits: ObligationEdits(componentName: .some("Recitation Quizzes"), courseID: .some(recitation.id)))   // moved
        let summary = try await Fixture.ingest(Fixture.calculus(sha: "v2"), into: store)   // the syllabus, reissued
        #expect(summary.created == 0)
        let live = try await store.obligations()
        #expect(live.count == 5 && live.contains { $0.title == "HW 1 — sections 7.1 to 7.3" })
        let moved = live.first { $0.id == quiz.id }
        #expect(moved?.courseID == recitation.id && moved?.componentName == "Recitation Quizzes")   // where the user put it, its row the new course's
    }

    @Test func deletingALaterDocumentGivesItsItemsBackToTheEarlierOne() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        let syllabus = try await store.documents().first!
        let update = try await store.enqueueDocument(filename: "update.pdf", sha256: "upd", kind: "pdf", deviceName: "A", courseID: calc.id)
        var moves = Fixture.calculus(sha: "upd"); moves.course = nil; moves.gradeComponents = []; moves.policies = []
        moves.obligations = [ParsedObligation(title: "HW 2", platform: .webAssign, componentName: "Homework", dateAsWritten: "9/18", due: Fixture.day(9, 18), status: .ready, sourcePage: 1),
                             ParsedObligation(title: "Lab Report", dateAsWritten: "9/25", due: Fixture.day(9, 25), status: .ready)]
        _ = try await store.ingest(moves, documentID: update.id, calendar: Fixture.calendar)
        #expect(try await store.obligations().first { $0.title == "HW 2" }?.sourceDocumentID == update.id)
        try await store.deleteDocument(id: update.id)
        let live = try await store.obligations()
        #expect(live.map(\.title).sorted() == ["Final Exam", "HW 1", "HW 2", "Midterm 1", "Quiz 1"])   // the syllabus still lists HW 2
        let hw2 = live.first { $0.title == "HW 2" }!
        #expect(hw2.sourceDocumentID == syllabus.id && hw2.due == Fixture.day(9, 16) && hw2.state == .pendingReview)   // its date, said in review
        #expect(hw2.changeNote?.contains("Sep 18 → Sep 16") == true)
        #expect(try await store.obligations(includeDeleted: true).filter { $0.deletedAt != nil }.map(\.title) == ["Lab Report"])   // only what went is in the bin
    }

    @Test func pointsFollowEveryHandEdit() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let calc = try await store.courses().first!
        func points(_ title: String) async throws -> Double { try await store.obligations().first { $0.title == title }?.pointsAtStake ?? -1 }
        // Homework from 15% to 30% over its stated ten.
        var table = calc.gradeComponents; table[0].weight = 0.30
        try await store.updateCourse(id: calc.id, edits: CourseEdits(gradeComponents: table))
        #expect(abs(try await points("HW 1") - 3) < 1e-9)
        // HW 2 moved to Quizzes (12% over what is on file): two quizzes now.
        let hw2 = try await store.obligations().first { $0.title == "HW 2" }!
        try await store.confirm(id: hw2.id, edits: ObligationEdits(componentName: .some("Quizzes")))
        let (hw2Points, quizPoints) = (try await points("HW 2"), try await points("Quiz 1"))
        #expect(abs(hw2Points - 6) < 1e-9 && abs(quizPoints - 6) < 1e-9)
        // A quiz added by hand shares the row; deleted, the rest share it again.
        let quiz2 = try await store.addManual(title: "Quiz 2", due: Fixture.day(9, 24), dueHasTime: false, courseID: calc.id, componentName: "Quizzes", notes: nil, deviceName: "A")
        let (addedPoints, firstPoints) = (try await points("Quiz 2"), try await points("Quiz 1"))
        #expect(abs(addedPoints - 4) < 1e-9 && abs(firstPoints - 4) < 1e-9)
        try await store.softDelete(id: quiz2.id)
        #expect(abs(try await points("Quiz 1") - 6) < 1e-9)
    }

    @Test func anItemAddedByHandKeepsItsSite() async throws {
        let store = try Fixture.store()
        let item = try await store.addManual(title: "WebAssign 3.4", due: Fixture.day(9, 24), dueHasTime: false, courseID: nil, componentName: nil, platform: .webAssign, notes: nil, deviceName: "A")
        #expect(item.platform == .webAssign && item.userOverrides.contains(.platform))
        let plain = try await store.addManual(title: "Read ch. 3", due: nil, dueHasTime: false, courseID: nil, componentName: nil, notes: nil, deviceName: "A")
        #expect(plain.platform == .syllabusOnly && !plain.userOverrides.contains(.platform))
    }

    @Test func theBinKeepsACoursesPlaceAndARevivedCourseStartsAfresh() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        var biology = Fixture.calculus(sha: "bio"); biology.course = ParsedCourse(code: "BIO-UA 11", title: "Biology")
        try await Fixture.ingest(biology, into: store)
        let calc = try await store.courses().first { $0.code == "MA-UY 1124" }!, bio = try await store.courses().first { $0.code == "BIO-UA 11" }!
        try await store.reorderCourses([bio.id, calc.id])
        try await store.deleteCourse(id: calc.id)
        try await store.restoreCourse(id: calc.id)
        #expect(try await store.courses().first { $0.id == calc.id }?.sortOrder == 1)   // back in its place
        // Revived by a document later, its silence counts from then.
        try await store.deleteCourse(id: calc.id)
        let before = Date()
        try await Fixture.ingest(Fixture.calculus(sha: "again"), into: store)
        #expect((try await store.courses().first { $0.id == calc.id }?.createdAt ?? .distantPast) >= before)
        // "Updated" counts only documents still on file.
        for doc in try await store.documents() where doc.courseID == calc.id { try await store.deleteDocument(id: doc.id) }
        #expect(try await store.courses().first { $0.id == calc.id }?.lastIngested == nil)
        // A stale second delete of an item keeps the stamp of the deletion that took it.
        let gone = try await store.obligations(includeDeleted: true).first { $0.courseID == calc.id && $0.deletedAt != nil }!
        try await store.softDelete(id: gone.id)
        #expect(try await store.obligations(includeDeleted: true).first { $0.id == gone.id }?.deletedAt == gone.deletedAt)
    }

    @Test func aFailureTheFileCannotGetPastOffersNoRetry() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        let broken = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "A", parse: { _, _ in throw IngestError.unreadable("PDFKit could not open it") })
        let doc = try await broken.enqueue(fileURL: try Fixture.file("empty.txt"))
        _ = await broken.drain()
        var record = try await store.document(id: doc.id)
        #expect(record?.status == .failed && record?.failureIsPermanent == true)
        try await store.markDocument(id: doc.id, status: .queued)                      // a Retry anyway: queued, the mark cleared
        record = try await store.document(id: doc.id)
        #expect(record?.status == .queued && record?.failureIsPermanent == false)
        // One a retry can fix is not permanent.
        let flaky = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "A", parse: { _, _ in throw IngestError.extractionFailed("nothing") })
        _ = await flaky.drain()
        record = try await store.document(id: doc.id)
        #expect(record?.status == .failed && record?.failureIsPermanent == false)
        // A kind Horizon cannot read is refused before it is copied in, and never queued.
        let refused = try await broken.enqueue(fileURL: try Fixture.file("notes.zip"))
        #expect(refused.status == .failed && refused.failureIsPermanent && refused.failure == "Horizon cannot read .zip files.")
        #expect(!storage.exists(sha256: refused.sha256, extension: "zip"))
        #expect(try await store.queuedDocuments().allSatisfy { $0.id != refused.id })
        for readable in ["a.pdf", "b.png", "c.txt", "d.md", "e"] { #expect(IngestCoordinator.refusal(for: URL(fileURLWithPath: "/tmp/\(readable)")) == nil, "\(readable)") }
        // A Word document off a Mac says what to do instead.
        #expect(IngestCoordinator.explain(IngestError.unsupportedFile("docx (macOS only)"), kind: "docx") == "Word documents can only be read on a Mac. Save it as a PDF and add that instead.")
        #expect(IngestCoordinator.explain(IngestError.unsupportedFile("zip"), kind: "zip") == "Horizon cannot read .zip files.")
    }

    @Test func aStoreANewerBuildOpenedIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Horizon.store")
        let marker = HorizonContainer.generationMarker(for: url)
        let generation = HorizonContainer.storeGeneration
        // No record (a store from before the guard): it opens, and records this build's generation.
        do { _ = try HorizonContainer.at(url) }
        #expect(HorizonContainer.recordedGeneration(at: marker) == generation)
        // An older record is raised to this build's.
        try "1".write(to: marker, atomically: true, encoding: .utf8)
        do { _ = try HorizonContainer.at(url) }
        #expect(HorizonContainer.recordedGeneration(at: marker) == generation)
        // A newer one is refused before anything is opened, and left as it was.
        try String(generation + 1).write(to: marker, atomically: true, encoding: .utf8)
        #expect(throws: StoreTooNew(recorded: generation + 1, supported: generation)) { _ = try HorizonContainer.at(url) }
        #expect(HorizonContainer.recordedGeneration(at: marker) == generation + 1)
    }

    @Test func daysStayDaysWhenTheTimeZoneChanges() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)                       // read in New York: HW 1 at 23:59 on Sep 9
        let timed = try await store.addManual(title: "Exam review", due: Fixture.day(9, 20, hour: 18, minute: 0), dueHasTime: true, courseID: nil, componentName: nil, notes: nil, deviceName: "A")
        let suite = "horizon-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await DayAnchor.settle(store, suite: suite, zone: Fixture.calendar.timeZone)  // the first run only records the zone
        let la = TimeZone(identifier: "America/Los_Angeles")!
        try await DayAnchor.settle(store, suite: suite, zone: la)                       // the student flies west
        var west = Calendar(identifier: .gregorian); west.timeZone = la
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(west.dateComponents([.month, .day, .hour, .minute], from: hw1.due!) == DateComponents(month: 9, day: 9, hour: 23, minute: 59))
        #expect(west.dateComponents([.month, .day, .hour], from: try await store.courses().first!.termStart!) == DateComponents(month: 9, day: 2, hour: 0))
        #expect(try await store.obligations().first { $0.id == timed.id }?.due == Fixture.day(9, 20, hour: 18, minute: 0))   // an instant stays
        try await DayAnchor.settle(store, suite: suite, zone: la)                       // the same zone again: nothing moves
        #expect(try await store.obligations().first { $0.title == "HW 1" }?.due == hw1.due)
    }

    @Test func aCourseMadeByHandWithoutACodeTakesItFromItsFirstDocument() async throws {
        let store = try Fixture.store()
        let chem = try await store.addCourse(CourseEdits(title: "General Chemistry", code: ""))   // as the editor sends it when no code is typed
        let doc = try await store.enqueueDocument(filename: "chem.pdf", sha256: "chem", kind: "pdf", deviceName: "A", courseID: chem.id)
        var syllabus = Fixture.calculus(sha: "chem")
        syllabus.course = ParsedCourse(code: "CHEM-UA 225", title: "General Chemistry I", term: "Fall 2026", termStart: Fixture.day(9, 2, hour: 0, minute: 0))
        let summary = try await store.ingest(syllabus, documentID: doc.id, calendar: Fixture.calendar)
        var course = try await store.courses().first { $0.id == chem.id }!
        #expect(summary.warnings.isEmpty && course.code == "CHEM-UA 225" && course.title == "General Chemistry")   // its code taken, the name given kept
        #expect(course.gradeComponents.map(\.name) == ["Homework", "Quizzes", "Final Exam"] && course.term == "Fall 2026")
        // A later document naming only the code is the same course.
        var schedule = Fixture.calculus(sha: "chem-schedule"); schedule.course = ParsedCourse(code: "CHEM-UA 225"); schedule.gradeComponents = []; schedule.policies = []
        try await Fixture.ingest(schedule, into: store)
        #expect(try await store.courses().map(\.id) == [chem.id])
        // A code another course has is not taken: the document stays where it was filed, with a warning, and touches nothing.
        let lab = try await store.addCourse(CourseEdits(title: "Chemistry Lab"))
        let labDoc = try await store.enqueueDocument(filename: "lab.pdf", sha256: "lab", kind: "pdf", deviceName: "A", courseID: lab.id)
        var labSyllabus = syllabus; labSyllabus.document = DocumentInfo(name: "lab.pdf", sha256: "lab", kind: .pdf, pageCount: 1)
        let warned = try await store.ingest(labSyllabus, documentID: labDoc.id, calendar: Fixture.calendar)
        course = try await store.courses().first { $0.id == lab.id }!
        #expect(course.code.isEmpty && course.gradeComponents.isEmpty && warned.warnings.contains { $0.contains("CHEM-UA 225") })
        // An empty code kept as the user's (every course made by hand was once marked so) is no code to keep either.
        try await store.updateCourse(id: lab.id, edits: CourseEdits(code: "CHEM-UA 9"))
        try await store.updateCourse(id: lab.id, edits: CourseEdits(code: ""))
        let notes = try await store.enqueueDocument(filename: "notes.pdf", sha256: "lab-notes", kind: "pdf", deviceName: "A", courseID: lab.id)
        var labNotes = labSyllabus; labNotes.course = ParsedCourse(code: "CHEM-UA 226"); labNotes.document = DocumentInfo(name: "notes.pdf", sha256: "lab-notes", kind: .pdf, pageCount: 1)
        _ = try await store.ingest(labNotes, documentID: notes.id, calendar: Fixture.calendar)
        #expect(try await store.courses().first { $0.id == lab.id }?.code == "CHEM-UA 226")
    }

    @Test func aModelAnthropicDoesNotHaveStopsTheDrain() async throws {
        let store = try Fixture.store()
        let sent = Counter()
        let coordinator = IngestCoordinator(store: store, storage: DocumentStorage.temporary(), sync: nil, deviceName: "A", parse: { url, _ in
            sent.append(url.lastPathComponent)
            throw IngestError.claudeUnavailable(ClaudeError.modelNotFound("claude-sonnet-9").localizedDescription)
        })
        _ = try await coordinator.enqueue(fileURL: try Fixture.file("a.txt", "first"))
        _ = try await coordinator.enqueue(fileURL: try Fixture.file("b.txt", "second"))
        let reports = await coordinator.drain()
        #expect(sent.value.count == 1 && reports.count == 1)                            // the second is not sent for the same answer
        #expect(try await store.queuedDocuments().count == 2)                           // both still wait to be read
        // Which waits stop a drain, and which are the key's or the model's (Settings), by ClaudeError's own words.
        let cases: [(ClaudeError, stops: Bool, settings: Bool)] = [
            (.unauthorized, true, true), (.forbidden(model: "claude-opus-5"), true, true), (.modelNotFound("claude-sonnet-9"), true, true),
            (.badRequest("max_tokens: too large"), true, true), (.billing, true, false), (.network("offline"), true, false),
            (.rateLimited(retryAfter: 30), false, false), (.overloaded, false, false), (.server(status: 529, message: "rejected upstream"), false, false)]
        for (error, stops, settings) in cases {
            let why = error.localizedDescription
            #expect(IngestCoordinator.stopsDrain(why) == stops && IngestCoordinator.isKeyOrModelProblem(why) == settings, "\(why)")
        }
        #expect(IngestCoordinator.stopsDrain("no API key") && IngestCoordinator.isKeyOrModelProblem("no API key"))
    }

    @Test func aPictureWithNothingToNameItFromYetHoldsUpNoOtherDocument() async throws {
        let store = try Fixture.store()
        let storage = DocumentStorage.temporary()
        // An older document read but not yet named, and a newer picture still waiting for Claude.
        let reads = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "A", parse: { _, _ in Fixture.calculus() })
        let older = try await reads.enqueue(fileURL: try Fixture.file("calc.txt"), filename: "calc.txt")
        _ = await reads.drain()
        let waits = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "A", parse: { _, _ in throw IngestError.claudeUnavailable("no connection") })
        let picture = try await waits.enqueue(fileURL: try Fixture.picture("scan.png"), filename: "scan.png")
        _ = await waits.drain()
        #expect(try await store.untitledDocuments().map(\.id) == [picture.id, older.id])  // newest first
        // The picture is asked about as the app asks (it has no words, and nothing has been read of it); the older one is
        // named by a stand-in for the device model.
        let asked = Counter()
        let namer = IngestCoordinator(store: store, storage: storage, sync: nil, deviceName: "A", parse: { _, _ in IngestResult(document: DocumentInfo(name: "scan.png", sha256: picture.sha256, kind: .image, pageCount: 1)) },
                                      name: { url, request, digest in
            asked.append(request.filename)
            return request.filename == "scan.png" ? await Ingestor.title(fileURL: url, request: request, digest: digest) : .titled("Calculus II Syllabus")
        })
        await namer.nameUntitled()
        let named = try await store.document(id: older.id)?.title, waiting = try await store.document(id: picture.id)?.title
        #expect(asked.value == ["scan.png", "calc.txt"] && named == "Calculus II Syllabus" && waiting == nil)   // the picture is asked again once read
        await namer.nameUntitled()
        #expect(asked.value == ["scan.png", "calc.txt"])                                // and not opened again before then
        // Read, and still nothing in it to name it from: marked as having no name, and not asked about again.
        _ = await namer.drain()
        await namer.nameUntitled()
        await namer.nameUntitled()
        #expect(try await store.document(id: picture.id)?.title == "" && asked.value == ["scan.png", "calc.txt", "scan.png"])
    }
}


extension StoreFollowThroughTests {
    /// Each generation's schema, as Core Data fingerprints its entities. A stored property added, removed or retyped
    /// changes it: bump `HorizonContainer.storeGeneration` and record the new fingerprint under the new number (a field
    /// added to a Codable value stored in a row does not show here, and needs the bump all the same).
    static let fingerprints: [Int: String] = [2: "390b92db4ace32b6624a1ee2df759ba6752544ec9e00a86327af20a0e601ee6b"]

    @Test func theStoredSchemaIsItsGenerations() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: HorizonSchemaV1.self)))
        let hashes = model.entityVersionHashesByName.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.base64EncodedString())" }.joined(separator: ";")
        let fingerprint = DocumentStorage.sha256(Data(hashes.utf8))
        #expect(Self.fingerprints[HorizonContainer.storeGeneration] == fingerprint,
                "a stored property changed: bump HorizonContainer.storeGeneration and record \(fingerprint) for it")
    }
}
