import Foundation
import Testing
import IngestKit
@testable import HorizonCore

struct CoverageTests {
    let now = Fixture.day(9, 21, hour: 12, minute: 0)   // Monday, September 21, 2026
    func course(_ code: String, components: [GradeComponent] = [], platforms: [String] = [], lastIngested: Date? = nil, createdAt: Date? = nil) -> CourseSnapshot {
        CourseSnapshot(code: code, title: code, termStart: Fixture.day(9, 2), termEnd: Fixture.day(12, 14), gradeComponents: components, platforms: platforms,
                       lastIngested: lastIngested, createdAt: createdAt)
    }
    func obligation(_ title: String, due: Date?, course: CourseSnapshot, component: String? = nil, completed: Bool = false, completedAt: Date? = nil,
                    platform: Platform = .syllabusOnly, document: UUID? = nil) -> ObligationSnapshot {
        ObligationSnapshot(id: UUID(), title: title, due: due, dueHasTime: false, platform: platform, componentName: component, pointsAtStake: nil, confidence: 1,
                           state: .projected, origin: .document, flags: [], notes: nil, userOverrides: [], ekExternalID: nil, projectedTitle: nil, projectedDue: nil,
                           projectedNotes: nil, completedAt: completedAt ?? (completed ? now : nil), deletedAt: nil, changeNote: nil, createdOn: "A", courseID: course.id,
                           courseCode: course.code, sourceDocumentID: document, sourcePage: nil)
    }

    @Test func nothingOnFile() {
        let empty = course("PHIL-UA 1")
        let c = Coverage.assess(course: empty, obligations: [], documents: [], now: now, calendar: Fixture.calendar)
        #expect(c.daysSilent == nil && c.upcoming14 == 0 && c.cadenceGaps.isEmpty && c.suspicion == 1)
        #expect(c.headline == "PHIL-UA 1 has nothing on file." && c.updatedLine == nil)
        // A parsed document says how fresh the course is when the course itself records nothing; queued ones do not count,
        // and reading one is not the user doing anything: the silence is untouched.
        let parsed = DocumentSnapshot(id: UUID(), filename: "a.pdf", sha256: "a", kind: "pdf", status: .parsed, queuedAt: now, ingestedAt: Fixture.day(9, 14), deviceName: "A", platform: nil, courseID: empty.id)
        let queued = DocumentSnapshot(id: UUID(), filename: "b.pdf", sha256: "b", kind: "pdf", status: .queued, queuedAt: now, ingestedAt: now, deviceName: "A", platform: nil, courseID: empty.id)
        let read = Coverage.assess(course: empty, obligations: [], documents: [parsed, queued], now: now, calendar: Fixture.calendar)
        #expect(read.daysSinceUpdate == 7 && read.updatedLine == "Updated 7 days ago" && read.daysSilent == nil)
        #expect(read.headline == "PHIL-UA 1 has nothing due in the next two weeks." && read.suspicion == 0)   // something was read: not "nothing on file"
        #expect(Coverage.assess(course: course("PHIL-UA 1", lastIngested: now), obligations: [], documents: [], now: now, calendar: Fixture.calendar).updatedLine == "Updated today")
    }

    @Test func windowRunsThroughTheEndOfDayFourteen() {
        let bio = course("BIO-UA 11", lastIngested: now)
        let onDay14 = obligation("Quiz", due: Fixture.day(10, 5), course: bio)          // Oct 5 23:59, the 14th day from Sep 21
        let onDay15 = obligation("Late", due: Fixture.day(10, 6, hour: 0, minute: 30), course: bio)
        let earlierToday = obligation("Gone", due: Fixture.day(9, 21, hour: 9, minute: 0), course: bio)
        let c = Coverage.assess(course: bio, obligations: [onDay14, onDay15, earlierToday], documents: [], now: now, calendar: Fixture.calendar)
        #expect(c.upcoming14 == 1)
        // Across the end of daylight time (Nov 1) the window is still whole days.
        let nov = Fixture.day(10, 25, hour: 12, minute: 0)
        let edge = obligation("Quiz", due: Fixture.day(11, 8), course: bio)
        #expect(Coverage.assess(course: bio, obligations: [edge], documents: [], now: nov, calendar: Fixture.calendar).upcoming14 == 1)
    }

    @Test func rhythmIsOnlyExpectedInsideTheTerm() {
        let quizzes = [GradeComponent(name: "Quizzes", weight: 0.2, cadence: .weekly)]
        let bio = course("BIO-UA 11", components: quizzes, lastIngested: now)
        // Read before the term starts: no quizzes are expected yet.
        #expect(Coverage.assess(course: bio, obligations: [], documents: [], now: Fixture.day(8, 20, hour: 12, minute: 0), calendar: Fixture.calendar).cadenceGaps.isEmpty)
        // The last week of term expects one quiz, not two.
        let lastWeek = Fixture.day(12, 8, hour: 12, minute: 0)
        let one = [obligation("Quiz 13", due: Fixture.day(12, 11), course: bio, component: "Quizzes")]
        #expect(Coverage.assess(course: bio, obligations: one, documents: [], now: lastWeek, calendar: Fixture.calendar).cadenceGaps.isEmpty)
        #expect(Coverage.assess(course: bio, obligations: [], documents: [], now: lastWeek, calendar: Fixture.calendar).cadenceGaps.map(\.expectedInWindow) == [1])
        // Mid-term, one of two on file reads as a partial gap.
        let partial = Coverage.assess(course: bio, obligations: [obligation("Quiz 3", due: Fixture.day(9, 25), course: bio, component: "Quizzes")], documents: [], now: now, calendar: Fixture.calendar)
        #expect(partial.headline == "BIO-UA 11's syllabus implies weekly quizzes; only 1 of 2 on file for the next two weeks.")
    }

    @Test func biweeklyAndCountedComponents() {
        let labs = [GradeComponent(name: "Lab Reports", weight: 0.2, expectedCount: 10, cadence: .biweekly), GradeComponent(name: "Essays", weight: 0.3, expectedCount: 4)]
        let bio = course("BIO-UA 11", components: labs, lastIngested: now)
        let items = [obligation("Lab Report 2", due: Fixture.day(9, 28), course: bio, component: "Lab Reports"), obligation("Essay 1", due: Fixture.day(10, 20), course: bio, component: "Essays")]
        let c = Coverage.assess(course: bio, obligations: items, documents: [], now: now, calendar: Fixture.calendar)
        #expect(c.cadenceGaps.map(\.component) == ["Essays"])   // one biweekly lab in the window is enough; 1 of 4 essays is under half
        #expect(c.headline == "BIO-UA 11's syllabus lists 4 essays; 1 on file.")
    }

    @Test func silenceCountsFromTheLastCompletionAndACheckResetsIt() {
        // In the app since Sep 7; last checked something off on Sep 12; a reading fell due on Sep 15 and is still open.
        let bio = course("BIO-UA 11", lastIngested: Fixture.day(9, 20), createdAt: Fixture.day(9, 7))
        let checked = obligation("Lab Report 0", due: Fixture.day(9, 11), course: bio, completedAt: Fixture.day(9, 12, hour: 20, minute: 0))
        let overdue = obligation("Reading 1", due: Fixture.day(9, 15), course: bio)
        let ahead = [obligation("Lab Report 1", due: Fixture.day(9, 25), course: bio), obligation("Exam 1", due: Fixture.day(10, 2), course: bio),
                     obligation("Lab Report 2", due: Fixture.day(10, 26), course: bio)]
        func assess(_ items: [ObligationSnapshot], _ c: CourseSnapshot? = nil) -> CourseCoverage {
            Coverage.assess(course: c ?? bio, obligations: items, documents: [], now: now, calendar: Fixture.calendar)
        }
        let silent = assess([checked, overdue] + ahead)
        #expect(silent.daysSilent == 9 && silent.isSilent && silent.upcoming14 == 2 && silent.suspicion == 9 * 0.05)
        #expect(silent.headline == "BIO-UA 11 has been silent for 9 days.")
        #expect(silent.daysSinceUpdate == 1 && silent.updatedLine == "Updated yesterday")   // a document read yesterday is not the user's doing
        // A check this morning resets the count; unchecked again, the silence runs from Sep 12 as before (the same items as `silent`).
        let reset = assess([checked, overdue, obligation("Quiz 0", due: Fixture.day(9, 18), course: bio, completedAt: Fixture.day(9, 21, hour: 9, minute: 0))] + ahead)
        #expect(reset.daysSilent == 0 && !reset.isSilent && reset.suspicion == 0)
        #expect(reset.headline == "BIO-UA 11 looks covered: 2 due in the next two weeks.")
        // Nothing fell due during the silence: the count stands, but the course is quiet, not silent.
        let quiet = assess([checked] + ahead)
        #expect(quiet.daysSilent == 9 && !quiet.isSilent && quiet.headline == "BIO-UA 11 looks covered: 2 due in the next two weeks.")
        // Nothing completed yet: the silence runs from the course's arrival, and what fell due before it does not count.
        let beforeArrival = obligation("HW 0", due: Fixture.day(9, 3), course: bio)
        let neverChecked = assess([beforeArrival, overdue] + ahead)
        #expect(neverChecked.daysSilent == 14 && neverChecked.isSilent)
        #expect(!assess([beforeArrival] + ahead).isSilent)
        // Under a week is not silence yet, whatever fell due.
        let newer = course("BIO-UA 11", createdAt: Fixture.day(9, 16))
        let recent = assess([obligation("Reading 2", due: Fixture.day(9, 18), course: newer)], newer)
        #expect(recent.daysSilent == 5 && !recent.isSilent && recent.headline == "BIO-UA 11 has nothing due in the next two weeks.")
        // A deleted item's check does not count.
        var gone = obligation("Quiz 0", due: Fixture.day(9, 18), course: bio, completedAt: now); gone.deletedAt = now
        #expect(assess([checked, overdue, gone] + ahead).daysSilent == 9)
    }

    @Test func weeklyCadenceWithNothingOnFileIsAGap() {
        let bio = course("BIO-UA 11", components: [GradeComponent(name: "Quizzes", weight: 0.2, cadence: .weekly), GradeComponent(name: "Final Exam", weight: 0.2, cadence: .once)],
                         lastIngested: Fixture.day(9, 12), createdAt: Fixture.day(9, 12))
        let c = Coverage.assess(course: bio, obligations: [obligation("Exam 1", due: Fixture.day(10, 2), course: bio, component: "Exam 1"), obligation("Reading 2", due: Fixture.day(9, 14), course: bio)],
                                documents: [], now: now, calendar: Fixture.calendar)
        #expect(c.cadenceGaps.map(\.component) == ["Quizzes"])
        #expect(c.headline == "BIO-UA 11 has been silent for 9 days and its syllabus implies weekly quizzes; none on file for the next two weeks.")
        // A grade row that names its own rhythm is not said twice.
        #expect(CadenceGap(component: "Weekly Quizzes", cadence: .weekly, expectedInWindow: 2, onFileInWindow: 0, onFileTotal: 0, expectedTotal: nil).sentence
                == "syllabus implies weekly quizzes; none on file for the next two weeks")
        // Two quizzes on file for the window satisfy a weekly rhythm.
        let covered = Coverage.assess(course: bio, obligations: [obligation("Quiz 3", due: Fixture.day(9, 25), course: bio, component: "Quizzes"), obligation("Quiz 4", due: Fixture.day(10, 2), course: bio, component: "Quizzes")], documents: [], now: now, calendar: Fixture.calendar)
        #expect(covered.cadenceGaps.isEmpty)
    }

    @Test func platformsNeverIngested() {
        // The grading row says homework is on WebAssign; the item on file came from the syllabus.
        let calc = course("MA-UY 1124", components: [GradeComponent(name: "Homework", weight: 0.15, platform: .webAssign)], lastIngested: now)
        let syllabus = DocumentSnapshot(id: UUID(), filename: "calc.pdf", sha256: "a", kind: "pdf", status: .parsed, queuedAt: now, ingestedAt: now, deviceName: "A", failure: nil, platform: nil, courseID: calc.id)
        let hw = obligation("HW 3", due: Fixture.day(9, 23), course: calc, component: "Homework")
        let blind = Coverage.assess(course: calc, obligations: [hw], documents: [syllabus], now: now, calendar: Fixture.calendar)
        #expect(blind.neverIngested == [PlatformGap(platform: .webAssign, components: ["Homework"])])
        #expect(blind.headline == "MA-UY 1124's homework is on WebAssign, from which nothing has ever been read.")
        // A screenshot whose text names the site counts.
        var shot = syllabus; shot.platform = .webAssign; shot.id = UUID()
        let seen = Coverage.assess(course: calc, obligations: [hw], documents: [syllabus, shot], now: now, calendar: Fixture.calendar)
        #expect(seen.neverIngested.isEmpty && seen.headline == "MA-UY 1124 looks covered: 1 due in the next two weeks.")
        // So does a picture whose text never spells the site, once an item on that site came from it.
        var photo = syllabus; photo.kind = "png"; photo.id = UUID()
        let fromPhoto = obligation("HW 4", due: Fixture.day(9, 30), course: calc, component: "Homework", platform: .webAssign, document: photo.id)
        #expect(Coverage.assess(course: calc, obligations: [hw, fromPhoto], documents: [syllabus, photo], now: now, calendar: Fixture.calendar).neverIngested.isEmpty)
        // An item's own row can name a site the grade table does not; then the claim names no component.
        let quiz = obligation("Quiz 1", due: Fixture.day(9, 24), course: calc, platform: .gradescope)
        let two = Coverage.assess(course: calc, obligations: [hw, quiz], documents: [syllabus], now: now, calendar: Fixture.calendar)
        #expect(two.neverIngested.map(\.platform) == [.webAssign, .gradescope])
        #expect(two.neverIngested[1].sentence(name: "MA-UY 1124", first: false) == "it has items on Gradescope, from which nothing has ever been read")
        // Several components on one site, and plurals: "quizzes are", "homework is".
        let many = PlatformGap(platform: .lms, components: ["Homework", "Quizzes", "Lab Reports"])
        #expect(many.sentence(name: "Bio", first: true) == "Bio's homework, quizzes and lab reports are on LMS, from which nothing has ever been read")
        #expect(PlatformGap(platform: .lms, components: ["Quizzes"]).sentence(name: "Bio", first: false) == "its quizzes are on LMS, from which nothing has ever been read")
        // The course's own record of sites ever seen is not evidence: nothing live names MyLab, so nothing is claimed.
        let stale = course("ECON-UA 2", platforms: ["myLab"], lastIngested: now)
        #expect(Coverage.assess(course: stale, obligations: [obligation("HW 1", due: Fixture.day(9, 23), course: stale)], documents: [syllabus], now: now, calendar: Fixture.calendar).neverIngested.isEmpty)
    }

    @Test func coursesSortBySuspicionNotName() async throws {
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)   // fresh, dated items, homework on WebAssign never ingested
        var quiet = Fixture.calculus(sha: "q"); quiet.course = ParsedCourse(code: "AAA 1", title: "Quiet"); quiet.obligations = []; quiet.gradeComponents = [ParsedGradeComponent(name: "Quizzes", weight: 1, cadence: .weekly)]
        try await Fixture.ingest(quiet, into: store)
        let coverage = try await store.coverage(now: Fixture.day(10, 5, hour: 12, minute: 0), calendar: Fixture.calendar)
        #expect(coverage.map(\.course.code) == ["AAA 1", "MA-UY 1124"])   // the silent, gap-ridden course first despite sorting last by name
        #expect(coverage[0].cadenceGaps.first?.component == "Quizzes")
        #expect(coverage[1].neverIngested == [PlatformGap(platform: .webAssign, components: ["Homework"])])   // from the items' own platform, under their component
    }
}
