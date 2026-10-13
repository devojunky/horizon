import Foundation
import Testing
import IngestKit
@testable import HorizonCore

/// What the App Intents, the widgets and search answer with: pure, so Siri's answers are tested here, not by Siri.
struct AssistantTests {
    let cal = Fixture.calendar

    func course(_ title: String, _ code: String, components: [GradeComponent] = [], closed: [ClosedDateRange] = []) -> CourseSnapshot {
        CourseSnapshot(code: code, title: title, gradeComponents: components, noClassDates: closed)
    }

    func item(_ title: String, _ due: Date?, points: Double? = nil, course: UUID? = nil, done: Bool = false, state: ObligationState = .projected) -> ObligationSnapshot {
        ObligationSnapshot(id: UUID(), title: title, due: due, dueHasTime: true, platform: .syllabusOnly, componentName: nil, pointsAtStake: points, confidence: 1,
                           state: state, origin: .document, flags: [], notes: nil, userOverrides: [], ekExternalID: nil, projectedTitle: nil, projectedDue: nil,
                           projectedNotes: nil, completedAt: done ? Fixture.day(9, 1) : nil, deletedAt: nil, changeNote: nil, createdOn: "test", courseID: course,
                           courseCode: nil, sourceDocumentID: nil, sourcePage: nil)
    }

    // MARK: Courses by name

    @Test func aCourseIsNamedTheWayPeopleSayIt() {
        let calc = course("Calculus II", "MA-UY 1124"), bio = course("Biology", "BIO 101"), ob = course("Organizational Behavior", "MGMT 2100")
        let all = [bio, calc, ob]
        #expect(CourseMatch.ranked("Calc", in: all).first == calc)
        #expect(CourseMatch.ranked("calculus 2", in: all).first == calc)
        #expect(CourseMatch.ranked("Calculus II", in: all).first == calc)
        #expect(CourseMatch.ranked("MA 1124", in: all).first == calc)
        #expect(CourseMatch.ranked("1124", in: all).first == calc)
        #expect(CourseMatch.ranked("bio", in: all).first == bio)
        #expect(CourseMatch.ranked("OB", in: all).first == ob)
        #expect(CourseMatch.ranked("org behavior", in: all).first == ob)
        #expect(CourseMatch.ranked("chemistry", in: all).isEmpty)   // nothing guessed
        #expect(CourseMatch.score("Calculus II", name: "Calculus II", code: "MA-UY 1124") > CourseMatch.score("calc", name: "Calculus II", code: "MA-UY 1124"))
    }

    // MARK: A rhythm into items

    @Test func aWeeklyRhythmBecomesNumberedItemsUpToTheExam() throws {
        let start = Fixture.day(10, 8, hour: 16, minute: 0)   // a Thursday, 4 PM
        let rule = Calendar.RecurrenceRule.weekly(calendar: cal, weekdays: [.every(.thursday)])
        let exam = Fixture.day(11, 5, hour: 9, minute: 0)     // the midterm, Thursday morning: no quiz that day
        let dates = ItemSeries.dates(rule: rule, start: start, end: ItemSeries.end(beforeDayOf: exam, calendar: cal), skipping: [], calendar: cal)
        #expect(dates.map { cal.component(.day, from: $0) } == [8, 15, 22, 29])
        #expect(dates.allSatisfy { cal.component(.hour, from: $0) == 16 && cal.component(.weekday, from: $0) == 5 })
        let items = ItemSeries.items(stem: "Quiz", first: 4, dates: dates, hasTime: true)
        #expect(items.map(\.title) == ["Quiz 4", "Quiz 5", "Quiz 6", "Quiz 7"])
        // A day the user names is included; a break is skipped without using up a number.
        let fall = ClosedDateRange(start: Fixture.day(10, 22, hour: 0, minute: 0), end: Fixture.day(10, 23, hour: 0, minute: 0), label: "Fall break")
        let through = ItemSeries.dates(rule: rule, start: start, end: ItemSeries.end(throughDay: Fixture.day(10, 29, hour: 0, minute: 0), calendar: cal), skipping: [fall], calendar: cal)
        #expect(through.map { cal.component(.day, from: $0) } == [8, 15, 29])
        // No end: the series stops at the limit, never floods Reminders.
        #expect(ItemSeries.dates(rule: rule, start: start, end: nil, skipping: [], calendar: cal).count == ItemSeries.limit)
    }

    @Test func aSeriesStartingMidweekBeginsOnItsFirstDay() {
        let monday = Fixture.day(10, 5, hour: 16, minute: 0)
        let rule = Calendar.RecurrenceRule.weekly(calendar: cal, weekdays: [.every(.thursday)])
        let dates = ItemSeries.dates(rule: rule, start: monday, end: Fixture.day(10, 20, hour: 0, minute: 0), skipping: [], calendar: cal)
        #expect(dates.map { cal.component(.day, from: $0) } == [8, 15])   // Thursdays only, never the Monday it was asked on
    }

    @Test func aTitleKnowsItsNumberAndTheNextOne() {
        #expect(ItemSeries.stem(of: "Quiz 3") == ("Quiz", 3))
        #expect(ItemSeries.stem(of: "Problem Set #2").stem == "Problem Set" && ItemSeries.stem(of: "Problem Set #2").number == 2)
        #expect(ItemSeries.stem(of: "Lab Report").number == nil)
        #expect(ItemSeries.nextNumber(for: "Quiz", existing: ["Quiz 1", "Quiz 3", "quiz 2", "Exam 1", "Quiz"]) == 4)
        #expect(ItemSeries.nextNumber(for: "Lab", existing: ["Quiz 1"]) == 1)
    }

    @Test func aSeriesTakesTheGradeRowItsNameFallsUnder() {
        let rows = [GradeComponent(name: "Quizzes", weight: 0.1), GradeComponent(name: "Weekly Homework", weight: 0.2), GradeComponent(name: "Exams", weight: 0.5)]
        #expect(ItemSeries.component(for: "Quiz", in: rows) == "Quizzes")
        #expect(ItemSeries.component(for: "Homework", in: rows) == "Weekly Homework")
        #expect(ItemSeries.component(for: "Reading response", in: rows) == nil)
        #expect(ItemSeries.component(for: "Quiz", in: rows + [GradeComponent(name: "Pop Quizzes")]) == nil)   // two rows fit: no guess
    }

    // MARK: What's due

    @Test func whatIsDueFallsInItsPeriodInDateOrder() {
        let now = Fixture.day(10, 5, hour: 10, minute: 0)   // Monday
        let calc = UUID()
        let items = [
            item("Late", Fixture.day(10, 4)),
            item("Tonight", Fixture.day(10, 5, hour: 23, minute: 59), points: 2, course: calc),
            item("Done", Fixture.day(10, 5, hour: 20, minute: 0), done: true),
            item("Thursday", Fixture.day(10, 8, hour: 9, minute: 0), points: 20),
            item("Next week", Fixture.day(10, 13)),
            item("Undated", nil),
        ]
        let today = DuePeriod.today.interval(at: now, calendar: cal)
        #expect(DueQuery.items(items, in: today).map(\.title) == ["Tonight"])
        #expect(DueQuery.items(items, in: today, includeDone: true).map(\.title) == ["Done", "Tonight"])
        #expect(DueQuery.items(items, in: DuePeriod.thisWeek.interval(at: now, calendar: cal)).map(\.title) == ["Tonight", "Thursday"])
        #expect(DueQuery.items(items, in: DuePeriod.nextTwoWeeks.interval(at: now, calendar: cal), course: calc).map(\.title) == ["Tonight"])
        #expect(DueQuery.overdue(items, now: now).map(\.title) == ["Late"])
        let tomorrow = DuePeriod.tomorrow.interval(at: now, calendar: cal)
        #expect(cal.component(.day, from: tomorrow.start) == 6 && tomorrow.duration == 86400)
    }

    @Test func nextIsTheHeaviestOfTheComingTwoWeeksNotTheSoonest() {
        let now = Fixture.day(10, 5, hour: 10, minute: 0)
        let items = [
            item("Problem Set", Fixture.day(10, 6), points: 2),
            item("Midterm", Fixture.day(10, 14, hour: 9, minute: 0), points: 25),
            item("Final", Fixture.day(12, 15), points: 35),                  // heavier, but not next
            item("Done exam", Fixture.day(10, 7), points: 30, done: true),
        ]
        #expect(DueQuery.nextByWeight(items, now: now)?.title == "Midterm")
        // Two as heavy: the earlier.
        let twin = item("Midterm (other)", Fixture.day(10, 9), points: 25)
        #expect(DueQuery.nextByWeight(items + [twin], now: now)?.title == "Midterm (other)")
        // No weights anywhere: the soonest.
        #expect(DueQuery.nextByWeight([item("B", Fixture.day(10, 9)), item("A", Fixture.day(10, 7))], now: now)?.title == "A")
        #expect(DueQuery.nextByWeight([item("Far", Fixture.day(11, 30), points: 10)], now: now) == nil)

        // The whole list, heaviest first: what "what matters most?" says, its first the same as next's.
        let twoWeeks = DuePeriod.nextTwoWeeks.interval(at: now, calendar: cal)
        let unweighed = item("Reading", Fixture.day(10, 7))
        let gone = item("This morning", Fixture.day(10, 5, hour: 8, minute: 0), points: 40)   // today, but already past
        #expect(DueQuery.byWeight(items + [twin, unweighed, gone], in: twoWeeks, now: now).map(\.title) == ["Midterm (other)", "Midterm", "Problem Set", "Reading"])
        #expect(DueQuery.byWeight([item("B", Fixture.day(10, 9)), item("A", Fixture.day(10, 7))], in: twoWeeks, now: now).map(\.title) == ["A", "B"])
    }

    // MARK: The Search tab before anything is typed

    @Test func searchSuggestsWhatMattersNowEachOnce() {
        let now = Fixture.day(10, 5, hour: 10, minute: 0)   // Monday
        let early = item("Reading quiz", Fixture.day(10, 5, hour: 8, minute: 0))          // today, gone by: still today's
        let tonight = item("Problem Set 4", Fixture.day(10, 5, hour: 23, minute: 59), points: 2)
        let midterm = item("Midterm", Fixture.day(10, 14, hour: 9, minute: 0), points: 25)
        let tomorrow = item("Lab report", Fixture.day(10, 6, hour: 17, minute: 0), points: 5)
        let review = item("Quiz 5", Fixture.day(10, 9, hour: 16, minute: 0), state: .pendingReview)
        let thursday = item("Essay draft", Fixture.day(10, 8, hour: 12, minute: 0))
        let all = [early, tonight, midterm, tomorrow, review, thursday,
                   item("Done today", Fixture.day(10, 5, hour: 20, minute: 0), done: true), item("Far", Fixture.day(11, 20), points: 40)]

        let suggested = SearchSuggestions.items(all, now: now, calendar: cal)
        #expect(suggested.map(\.id) == [early.id, tonight.id, tomorrow.id, midterm.id, review.id])
        #expect(suggested.map(\.reason) == [.dueToday, .dueToday, .dueTomorrow, .mattersMost, .toReview])
        // Room for more: the rest of the week by date, and an item due today is never offered twice.
        let more = SearchSuggestions.items(all, now: now, calendar: cal, limit: 8)
        #expect(more.map(\.id) == [early.id, tonight.id, tomorrow.id, midterm.id, review.id, thursday.id])
        #expect(SearchSuggestions.items([], now: now, calendar: cal).isEmpty)
    }

    @Test func searchSuggestsQueriesFromTheLibrary() {
        let now = Fixture.day(10, 5, hour: 10, minute: 0)
        let calc = UUID(), bio = UUID()
        let policies = [
            PolicySnapshot(id: UUID(), kind: .lateWork, text: "Late homework loses 10% per day.", verbatim: true, courseID: calc, courseName: "Calculus II"),
            PolicySnapshot(id: UUID(), kind: .lateWork, text: "No late labs.", verbatim: true, courseID: bio, courseName: "Biology"),
            PolicySnapshot(id: UUID(), kind: .makeupExam, text: "One make-up exam a semester.", verbatim: true, courseID: calc, courseName: "Calculus II"),
            PolicySnapshot(id: UUID(), kind: .attendance, text: "Attendance is taken.", verbatim: true, courseID: bio, courseName: "Biology"),
            PolicySnapshot(id: UUID(), kind: .other, text: "No calculators.", verbatim: true, courseID: calc, courseName: "Calculus II"),
        ]
        var quiz = item("Quiz 4", Fixture.day(10, 8)); quiz.componentName = "Quizzes"
        var quiz2 = item("Quiz 5", Fixture.day(10, 15)); quiz2.componentName = "Quizzes"
        var lab = item("Lab 2", Fixture.day(10, 9)); lab.componentName = "Labs"
        let syllabus = DocumentSnapshot(filename: "MA1124 Syllabus Fall 2026.pdf", sha256: "x", kind: "pdf", status: .parsed, queuedAt: now, deviceName: "test")
        // Late work is stated twice, so it leads; makeup exams beat attendance on the kinds' own order.
        #expect(SearchSuggestions.queries(policies: policies, items: [quiz, quiz2, lab], documents: [syllabus], now: now, calendar: cal)
                == ["late work policy", "makeup exam policy", "Quizzes", "syllabus"])
        #expect(SearchSuggestions.queries(policies: [], items: [], documents: [], now: now, calendar: cal).isEmpty)
    }

    @Test func recentSearchesKeepTheNewestOnce() {
        #expect(SearchSuggestions.remembering("  makeup exam  ", in: ["quiz", "Makeup Exam", "lab"]) == ["makeup exam", "quiz", "lab"])
        #expect(SearchSuggestions.remembering("", in: ["quiz"]) == ["quiz"])
        #expect(SearchSuggestions.remembering("g", in: ["a", "b", "c", "d", "e", "f"]) == ["g", "a", "b", "c", "d", "e"])
    }

    // MARK: Policies

    @Test func aQuestionAboutACourseFindsItsTopic() {
        #expect(CourseQuestion.topic(of: "How is Calc graded?") == .grading)
        #expect(CourseQuestion.topic(of: "what's the final worth") == .grading)
        #expect(CourseQuestion.topic(of: "who teaches Biology") == .overview)
        #expect(CourseQuestion.topic(of: "office hours") == .overview)
        #expect(CourseQuestion.topic(of: "test makeups") == .policy(.makeupExam))   // a policy's words come first
        #expect(CourseQuestion.topic(of: "late work") == .policy(.lateWork))
        #expect(CourseQuestion.topic(of: "calculators") == nil)
    }

    @Test func aQuestionFindsThePolicyItIsAbout() {
        #expect(PolicyLookup.kind(of: "test makeups") == .makeupExam)
        #expect(PolicyLookup.kind(of: "What happens if I miss the final?") == .makeupExam)
        #expect(PolicyLookup.kind(of: "can I hand in homework late") == .lateWork)
        #expect(PolicyLookup.kind(of: "extensions") == .lateWork)
        #expect(PolicyLookup.kind(of: "do they drop the lowest quiz") == .dropRule)
        #expect(PolicyLookup.kind(of: "attendance") == .attendance)
        #expect(PolicyLookup.kind(of: "calculators") == nil)
        let calc = UUID()
        let policies = [
            PolicySnapshot(id: UUID(), kind: .makeupExam, text: "No makeup exams will be given except for documented emergencies.", verbatim: true, courseID: calc, courseName: "Calculus II"),
            PolicySnapshot(id: UUID(), kind: .lateWork, text: "Late homework loses 10% per day.", verbatim: true, courseID: calc, courseName: "Calculus II"),
            PolicySnapshot(id: UUID(), kind: .other, text: "Calculators are not allowed on exams.", verbatim: true, courseID: calc, courseName: "Calculus II"),
        ]
        #expect(PolicyLookup.answers("test makeups", in: policies).first?.kind == .makeupExam)
        #expect(PolicyLookup.answers("calculator", in: policies).map(\.kind) == [.other])
        #expect(PolicyLookup.answers(nil, kind: .lateWork, in: policies).map(\.kind) == [.lateWork])
        #expect(PolicyLookup.answers("parking", in: policies).isEmpty)
        #expect(PolicyLookup.answers(nil, in: policies).count == 3)
    }

    // MARK: Search

    @Test func searchFindsEveryWordAndRanksNamesFirst() {
        let calc = course("Calculus II", "MA-UY 1124")
        let items = [
            item("Quiz 3", Fixture.day(10, 8), course: calc.id),
            item("Lab report", Fixture.day(10, 9)),
            item("Problem set", Fixture.day(10, 10), course: calc.id),
        ]
        let policies = [PolicySnapshot(id: UUID(), kind: .makeupExam, text: "No makeup quizzes.", verbatim: true, courseID: calc.id, courseName: "Calculus II")]
        let r = HorizonSearch.run("quiz", items: items, courses: [calc], policies: policies, documents: [])
        #expect(r.items.map(\.title) == ["Quiz 3"])
        #expect(r.policies.count == 1)                              // "quizzes" starts with "quiz"
        #expect(HorizonSearch.run("calc quiz", items: items, courses: [calc], policies: [], documents: []).items.map(\.title) == ["Quiz 3"])   // the course's name counts
        #expect(HorizonSearch.run("calc", items: items, courses: [calc], policies: [], documents: []).courses == [calc])
        #expect(HorizonSearch.run("  ", items: items, courses: [calc], policies: [], documents: []).isEmpty)
        #expect(HorizonSearch.run("Énergie", items: [item("energie review", nil)], courses: [], policies: [], documents: []).items.count == 1)   // accents fold
    }

    @Test func searchReadsAQuestionAndLetsSpotlightLead() {
        let calc = course("Calculus II", "MA-UY 1124")
        let bio = course("Principles of Biology I", "BIO-UA 11")
        let calcMakeup = PolicySnapshot(id: UUID(), kind: .makeupExam, text: "Students will be allowed a maximum of one make-up exam throughout the entire semester.",
                                        verbatim: true, courseID: calc.id, courseName: "Calculus II")
        let bioMakeup = PolicySnapshot(id: UUID(), kind: .makeupExam, text: "No quiz makeups are given for any reason.", verbatim: true, courseID: bio.id, courseName: "Principles of Biology I")
        let calcLate = PolicySnapshot(id: UUID(), kind: .lateWork, text: "Late homework loses 10% a day.", verbatim: true, courseID: calc.id, courseName: "Calculus II")
        let exam = item("Exam 1", Fixture.day(10, 8), course: calc.id)
        let policies = [bioMakeup, calcLate, calcMakeup]

        // Siri's whole sentence (what it handed the in-app search on the owner's phone): the filler goes, "policy" names
        // the policies, and the course's own makeup policy leads, the other course's after it.
        let asked = HorizonSearch.run("What's the makeup exam policy for Calc in Horizon", items: [exam], courses: [calc, bio], policies: policies, documents: [])
        #expect(asked.policies.map(\.id) == [calcMakeup.id, bioMakeup.id])
        #expect(asked.items.isEmpty)                                  // "Exam 1" in Calc carries two of the four words
        // The owner's own wording: "test" for exam, a plural for its singular, "make-up" as printed.
        #expect(HorizonSearch.run("test makeups for calc", items: [], courses: [calc, bio], policies: policies, documents: []).policies.first?.id == calcMakeup.id)
        #expect(HorizonSearch.run("make-up", items: [], courses: [], policies: [calcMakeup], documents: []).policies.count == 1)

        // What carries every word comes first in its own order; then Spotlight's finds (meaning brings what the words
        // miss; an id no longer on file is passed over); then what carries most of the words. Each once.
        var spotlight = HorizonSearch.Ranked()
        spotlight.policies = [calcLate.id, UUID(), calcMakeup.id]
        #expect(HorizonSearch.run("makeup exam policy for Calc", items: [], courses: [calc, bio], policies: policies, documents: [], spotlight: spotlight).policies.map(\.id)
                == [calcMakeup.id, calcLate.id, bioMakeup.id])
        // A plain word keeps the words' order (by date for items), whatever order Spotlight ranked them in.
        let quizzes = [item("Quiz 1", Fixture.day(9, 17), course: calc.id), item("Quiz 2", Fixture.day(10, 1), course: calc.id), item("Quiz 3", Fixture.day(10, 22), course: calc.id)]
        var shuffled = HorizonSearch.Ranked()
        shuffled.items = [quizzes[2].id, quizzes[0].id, quizzes[1].id]
        #expect(HorizonSearch.run("quiz", items: quizzes, courses: [calc], policies: [], documents: [], spotlight: shuffled).items.map(\.title) == ["Quiz 1", "Quiz 2", "Quiz 3"])
        // A question of filler alone has no words of its own, and Spotlight's finds still stand.
        #expect(HorizonSearch.run("what is it", items: [], courses: [], policies: policies, documents: [], spotlight: spotlight).policies.map(\.id) == [calcLate.id, calcMakeup.id])
        #expect(HorizonSearch.run("what is it", items: [], courses: [], policies: policies, documents: []).isEmpty)
    }

    // MARK: The widgets' glance

    @Test func theGlanceRunsAWeekAheadAndTurnsAtEveryDueMoment() throws {
        let now = Fixture.day(10, 5, hour: 10, minute: 0)
        let items = [
            item("Problem Set", Fixture.day(10, 5, hour: 12, minute: 0), points: 2),
            item("Exam 1", Fixture.day(10, 7, hour: 9, minute: 0), points: 25),
            item("Exam 2", Fixture.day(10, 7, hour: 14, minute: 0), points: 20),
            item("Done", Fixture.day(10, 6), points: 40, done: true),
        ]
        let glance = Glance.build(items: items, now: now, calendar: cal)
        let first = try #require(glance.entries.first)
        #expect(first.date == now && first.next?.title == "Exam 1")
        #expect(first.week.count == 7 && first.week[0].count == 1 && first.week[2].count == 2 && first.week[1].count == 0)
        #expect(first.week[2].pileup && first.week[2].heaviest == "Exam 1" && first.week[2].heat > first.week[0].heat)
        #expect(first.week[1].heat == 0)
        // After Exam 1's moment the next is Exam 2; after midnight the week starts a day later.
        #expect(glance.entry(at: Fixture.day(10, 7, hour: 9, minute: 30))?.next?.title == "Exam 2")
        let tuesday = try #require(glance.entry(at: Fixture.day(10, 6, hour: 0, minute: 1)))
        #expect(cal.component(.day, from: tuesday.week[0].day) == 6)
        // Written and read back whole.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Glance.json")
        try glance.write(to: url)
        #expect(Glance.read(from: url) == glance)
    }
}
