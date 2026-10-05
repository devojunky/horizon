import Testing
@testable import IngestKit

struct ScoringTests {
    typealias O = FixtureShape.Obligation
    let expected = FixtureShape(course: .init(code: "MA-UY 1124", title: "Calculus II"),
                                gradeComponents: [.init(name: "Homework", weight: 0.15), .init(name: "Quizzes", weight: 0.12)],
                                obligations: [O(title: "HW 1", due: "2026-09-09"), O(title: "HW 2", due: "2026-09-16"), O(title: "Quiz 1", due: "2026-09-17"), O(title: "Final Exam", due: nil)])

    @Test func perfectRun() {
        let produced = FixtureShape(course: .init(code: "MA-UY 1124", title: "Calculus II"),
                                    gradeComponents: [.init(name: "Homework", weight: 0.15), .init(name: "Quizzes", weight: 0.12)],
                                    obligations: [O(title: "Homework 1", due: "2026-09-09"), O(title: "Homework 2", due: "2026-09-16"), O(title: "Quiz 1", due: "2026-09-17"), O(title: "Final Exam", due: nil)])
        let s = Scoring.score(produced: produced, expected: expected)
        #expect(s.recall == 1 && s.dateAccuracy == 1 && s.weightAccuracy == 1 && s.falsePositives == 0 && s.courseFound)
    }

    @Test func missesWrongDatesAndSpurious() {
        let produced = FixtureShape(course: .init(code: "MA-UY 1124"),
                                    gradeComponents: [.init(name: "Homework", weight: 0.10)],
                                    obligations: [O(title: "HW 1", due: "2026-09-10"), O(title: "HW 3", due: "2026-09-23"), O(title: "Final Exam", due: nil), O(title: "Reading", due: "2026-09-04")])
        let s = Scoring.score(produced: produced, expected: expected)
        #expect(s.matched == 2 && s.recall == 0.5)            // HW 1 and Final Exam; HW 3 must not match HW 2
        #expect(s.dateAccuracy == 0)                          // HW 1 on the wrong day
        #expect(s.weightAccuracy == 0)                        // Homework weight wrong, Quizzes missing
        #expect(s.falsePositives == 2 && s.falsePositiveRate == 0.5 && s.readyErrors == 3)   // two spurious plus HW 1 on the wrong day
        #expect(s.notes.contains("missed: HW 2 (2026-09-16)") && s.notes.contains("spurious: Reading (2026-09-04, ?)"))
    }

    @Test func sameDayMatchAcceptsWeakerTitles() {
        let expected = FixtureShape(obligations: [O(title: "HW 1", due: "2027-02-07", platform: .myLab), O(title: "Lab 1", due: "2027-02-04"), O(title: "Quiz 3", due: "2026-10-01")])
        let produced = FixtureShape(obligations: [O(title: "MyLab Homework", due: "2027-02-07", platform: .myLab, status: .ready),
                                                  O(title: "Lab 1 Data and R basics", due: "2027-02-04", status: .ready),
                                                  O(title: "HW 3", due: "2026-10-01", status: .needsReview)])   // same day, same number, wrong kind
        let s = Scoring.score(produced: produced, expected: expected)
        #expect(s.matched == 2 && s.falsePositives == 1 && s.readyErrors == 0 && s.platformAccuracy == 1)
        let wrongDate = Scoring.score(produced: FixtureShape(obligations: [O(title: "HW 1", due: "2027-02-08", status: .ready)]), expected: FixtureShape(obligations: [O(title: "HW 1", due: "2027-02-07")]))
        #expect(wrongDate.matched == 1 && wrongDate.dateAccuracy == 0 && wrongDate.readyErrors == 1)   // a wrong date shipped as ready is an error
        #expect(s.notes.contains("title: HW 1 got MyLab Homework") && s.notes.contains("missed: Quiz 3 (2026-10-01)"))
    }

    @Test func aDateInventedForATBDItemIsAReadyError() {
        let expected = FixtureShape(obligations: [O(title: "Final Exam", due: nil)])
        let ready = Scoring.score(produced: FixtureShape(obligations: [O(title: "Final Exam", due: "2026-12-17", status: .ready)]), expected: expected)
        #expect(ready.recall == 1 && ready.readyErrors == 1 && ready.notes.contains("date: Final Exam expected TBD got 2026-12-17 (ready)"))
        let reviewed = Scoring.score(produced: FixtureShape(obligations: [O(title: "Final Exam", due: "2026-12-17", status: .needsReview)]), expected: expected)
        #expect(reviewed.readyErrors == 0)   // caught by review: reported, not fatal
    }

    @Test func seriesItemsMatchByDate() {
        let expected = FixtureShape(obligations: [O(title: "Quiz", due: "2026-09-10"), O(title: "Quiz", due: "2026-09-17")])
        let produced = FixtureShape(obligations: [O(title: "Quiz", due: "2026-09-17"), O(title: "Quiz", due: "2026-09-10")])
        let s = Scoring.score(produced: produced, expected: expected)
        #expect(s.recall == 1 && s.dateAccuracy == 1)
    }

    @Test func similarityHonorsNumbersAndAbbreviations() {
        #expect(Normalize.similarity("HW 3", "Homework 3") == 1)
        #expect(Normalize.similarity("HW 3", "Homework 4") == 0)
        #expect(Normalize.similarity("PS 1", "Problem Set 1") == 1)
        #expect(Normalize.similarity("Lab 1 report", "Lab 1") > 0.5)
    }
}
