import Foundation
import Testing
@testable import IngestKit

struct MergerTests {
    static let source = """
    MA-UY 1124 Calculus II — Fall 2026. First day of class: Wednesday, September 2, 2026. Last day of class: Monday, December 14, 2026.
    Homework (WebAssign, weekly) ...... 15%. Quizzes 12%. Midterm 1 20%. Midterm 2 20%. Final Exam 33%.
    HW 1 due Wed 9/9. Quiz 1 Thu 9/17. Midterm 1: Wednesday, October 7. Final Exam: date TBA by the registrar.
    Late work: Late homework is not accepted; WebAssign closes at the deadline. The lowest two quiz scores are dropped.
    No class: Monday, October 12 (Fall Recess); Wednesday, November 25 – Friday, November 27 (Thanksgiving).
    """
    static func outcome(_ chunk: Int, kind: ExtractionOutcome.Kind = .text, course: CourseFacts? = nil, components: [GradeComponentFacts] = [],
                        obligations: [ObligationFacts] = [], policies: [PolicyFacts] = [], noClass: [NoClassFacts] = []) -> ExtractionOutcome {
        ExtractionOutcome(kind: kind, page: chunk, extraction: ChunkExtraction(course: course, gradeComponents: components, obligations: obligations, policies: policies, noClassDates: noClass),
                          usage: UsageRecord(step: "text", chunk: chunk, route: .onDevice, inputTokens: 1, cachedTokens: 0, outputTokens: 1, reasoningTokens: 0, durationMs: 1))
    }
    static func ob(_ title: String, _ written: String, iso: String? = nil, platform: String = "not_stated", component: String? = nil, confidence: String = "high") -> ObligationFacts {
        ObligationFacts(title: title, platform: platform, component: component, dateAsWritten: written, dueDate: iso, confidence: confidence)
    }
    static func component(_ name: String, _ weight: Double?, count: Int? = nil, cadence: String = "other", platform: String = "not_stated") -> GradeComponentFacts {
        GradeComponentFacts(name: name, weightPercent: weight, count: count, cadence: cadence, dropLowest: nil, platform: platform)
    }
    static let course = CourseFacts(code: "MA-UY 1124", title: "Calculus II", instructor: nil, term: "Fall 2026", termStart: "2026-09-02", termEnd: "2026-12-14", room: nil, meetings: [])
    static var options: IngestOptions {
        var o = IngestOptions(); o.defaultYear = 2026
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; o.calendar = c
        return o
    }
    static func merge(_ outcomes: [ExtractionOutcome], text: String = source) -> IngestResult {
        Merger.merge(outcomes: outcomes, document: DocumentNormalizer.normalize(text: text, name: "calc.txt"), route: .onDevice, options: options, warnings: [])
    }
    static func day(_ date: Date?) -> Int? { date.map { options.calendar.component(.day, from: $0) } }

    @Test func componentsInferPlatformAndPoints() {
        let r = Self.merge([Self.outcome(0, course: Self.course,
                                         components: [Self.component("Homework", 15, count: 10, cadence: "weekly", platform: "webassign"), Self.component("Quizzes", 12), Self.component("Final Exam", 33)],
                                         obligations: [Self.ob("HW 1", "Wed 9/9", iso: "2026-09-09"), Self.ob("Quiz 1", "Thu 9/17", iso: "2026-09-17")])])
        let hw = r.obligations.first { $0.title == "HW 1" }!
        #expect(hw.componentName == "Homework")           // inferred from the title
        #expect(hw.platform == .webAssign)                 // inherited from the component
        #expect(hw.pointsAtStake == 1.5)                   // 15% ÷ 10
        #expect(hw.status == .ready && hw.confidence >= 0.9 && hw.sourcePage == 0)
        #expect(r.course?.code == "MA-UY 1124" && r.course?.termStart != nil)
        #expect(r.obligations.first { $0.title == "Quiz 1" }?.componentName == "Quizzes")   // plural-aware inference
    }

    @Test func inventedTitlesTakeTheDocumentsOwnLabel() {
        let text = """
        Exams
        Exam 1 Tuesday, October 6th, 2026
        Exam 2 Tuesday, November 10th, 2026
        Final Exam, TBD
        """
        let r = Self.merge([Self.outcome(0, obligations: [
            Self.ob("Midterm 1", "Tuesday, October 6th, 2026", iso: "2026-10-06", confidence: "high"),
            Self.ob("Midterm 2", "Tuesday, November 10th, 2026", iso: "2026-11-10", confidence: "high"),
            Self.ob("Final Exam", "TBD", iso: nil),
        ])], text: text)
        #expect(r.obligations.map(\.title) == ["Exam 1", "Exam 2", "Final Exam"])   // "Midterm" is the model's word, not the document's
        #expect(r.obligations.map(\.status) == [.ready, .ready, .awaitingDate])
        #expect(r.obligations.allSatisfy { $0.flags.isEmpty })
    }

    @Test func inventedTitleCutFromProseGoesToReview() {
        let text = "You must opt out of the program by September 17th. If you do not opt out by this date, you will be charged."
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 3", "September 17th", iso: "2026-09-17")])], text: text)
        let item = try! #require(r.obligations.first)
        #expect(item.title == "Opt out of the program" && item.flags == [.titleFromLine] && item.status == .needsReview)
    }

    @Test func inventedTitleWithNoLabelIsFlagged() {
        let text = "Sept 17: bring the signed form to class."
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 3", "Sept 17", iso: "2026-09-17")])], text: text)
        let item = try! #require(r.obligations.first)
        #expect(item.title == "HW 3" && item.flags == [.titleNotInSource] && item.status == .needsReview)
    }

    @Test func completeGradeTableDropsComponentsThatAreNotRows() {
        let text = """
        There will be WebAssign homework every week and written problem sets.
        Grading
        WebAssign 4%
        Problem Sets 4%
        Quizzes 12%
        Exam 1 25%
        Exam 2 25%
        Final Exam 30%
        Total 100%
        """
        let r = Self.merge([Self.outcome(0, components: [Self.component("Homework", 0, cadence: "weekly", platform: "webassign"), Self.component("Quizzes", nil), Self.component("Problem Sets", nil)])], text: text)
        #expect(r.gradeComponents.map(\.name) == ["Quizzes", "Problem Sets", "WebAssign", "Exam 1", "Exam 2", "Final Exam"])   // "Homework" is the WebAssign row under another name
        #expect(r.gradeComponents.map(\.weight) == [0.12, 0.04, 0.04, 0.25, 0.25, 0.30])
    }

    @Test func termDatesComeFromTheDocumentsOwnSentence() {
        let text = """
        MA-UY 2314 Discrete Mathematics, Fall 2026.
        Classes begin Wednesday, September 2, 2026 (Week 1) and end Monday, December 14, 2026 (Week 15).
        Week 2 Friday: Homework 1 due.
        """
        let course = CourseFacts(code: "MA-UY 2314", title: "Discrete Mathematics", instructor: nil, term: "Fall 2026", termStart: "2026-09-07", termEnd: "2026-12-11", room: nil, meetings: [])
        let r = Self.merge([Self.outcome(0, course: course, obligations: [Self.ob("Homework 1", "Week 2 Friday", iso: "2026-09-18")])], text: text)
        #expect(Self.day(r.course?.termStart) == 2 && Self.day(r.course?.termEnd) == 14)   // the model's dates were a week off
        #expect(Self.day(r.obligations.first?.due) == 11)                                  // Week 2 Friday counted from the real Week 1
    }

    @Test func modelTermDateTheDocumentNeverNamesIsDropped() {
        let text = "MA-UY 2314 Discrete Mathematics, Fall 2026. Homework is due on Fridays."
        let course = CourseFacts(code: "MA-UY 2314", title: "Discrete Mathematics", instructor: nil, term: "Fall 2026", termStart: "2026-09-07", termEnd: nil, room: nil, meetings: [])
        let r = Self.merge([Self.outcome(0, course: course)], text: text)
        #expect(r.course?.termStart == nil && r.warnings.contains { $0.hasPrefix("Ignored term date") })
    }

    @Test func titleThatIsAGradeRowNameTakesTheRowsOwnLabel() {
        let text = """
        MyLab Homework   20%  (eight assignments on MyLab Economics; lowest score dropped)
        Exams   80%
        HW 1  Feb 7
        HW 2  Feb 21
        """
        var options = Self.options; options.defaultYear = 2027
        let r = Merger.merge(outcomes: [Self.outcome(0, components: [Self.component("MyLab Homework", 20), Self.component("Exams", 80)], obligations: [
            Self.ob("MyLab Homework", "Feb 7", iso: "2027-02-07"), Self.ob("MyLab Homework", "Feb 21", iso: "2027-02-21"),
        ])], document: DocumentNormalizer.normalize(text: text, name: "econ.txt"), route: .onDevice, options: options, warnings: [])
        #expect(r.obligations.map(\.title) == ["HW 1", "HW 2"])
        #expect(r.obligations.allSatisfy { $0.status == .ready && $0.componentName == "MyLab Homework" })
    }

    @Test func titleNamedOnItsOwnRowStandsEvenWhenItIsAGradeRowName() {
        let text = """
        Midterm 1 20%. Midterm 2 20%. Final Exam 33%. Homework 27%.
        Week 5: Improper integrals. Midterm 1 Wed Oct 7.
        Final Exam: TBA.
        """
        let r = Self.merge([Self.outcome(0, components: [Self.component("Midterm 1", 20), Self.component("Midterm 2", 20), Self.component("Final Exam", 33), Self.component("Homework", 27)], obligations: [
            Self.ob("Midterm 1", "Wed Oct 7", iso: "2026-10-07"), Self.ob("Final Exam", "TBA", iso: nil),
        ])], text: text)
        #expect(r.obligations.map(\.title) == ["Midterm 1", "Final Exam"])
        #expect(r.obligations.map(\.status) == [.ready, .awaitingDate])
    }

    @Test func titleSpanningTableCellsKeepsItsOwnCell() {
        let text = """
        Lab 1   Data and R basics                due Thu Feb 4
        Lab 2   Graphics with ggplot             due Thu Feb 11
        Sep 9     Lab 1: Measurement and density        Sep 16
        """
        var options = Self.options; options.defaultYear = 2027
        let r = Merger.merge(outcomes: [Self.outcome(0, obligations: [
            Self.ob("Lab 1 Data and R basics", "Thu Feb 4", iso: "2027-02-04"), Self.ob("Lab 2 Graphics with ggplot", "Thu Feb 11", iso: "2027-02-11"),
        ])], document: DocumentNormalizer.normalize(text: text, name: "stats.txt"), route: .onDevice, options: options, warnings: [])
        #expect(r.obligations.map(\.title) == ["Lab 1", "Lab 2"])
    }

    @Test func aFrequencyStatementWithAModelDateNeedsReview() {
        let text = "Mastering Physics Homework 15% weekly, due Sundays 11:59 PM on Mastering Physics.\n3 Sep 14-18 Newton's laws MP HW 2 due Sun Sep 20"
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Mastering Physics Homework", "weekly, due Sundays", iso: "2026-09-14")])], text: text)
        let item = try! #require(r.obligations.first)
        #expect(item.status == .needsReview && item.flags.contains(.dateNotInSource))
    }

    @Test func nullWordingIsNoWording() {
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Weekly Labs", "null", iso: "2026-09-02")])])   // Sep 2 is in the document, as the first day of class
        let item = try! #require(r.obligations.first)
        #expect(item.status == .needsReview && item.flags.contains(.dateNotInSource))
    }


    @Test(arguments: [
        ("Week 3: Trig substitution. HW 3", "HW 3"), ("8 Oct 19-23 Rotation MP HW 6", "MP HW 6"), ("Angular momentum MP HW 7", "MP HW 7"),
        ("14 Nov 30-Dec 4 Exam 3 (Thu Dec 3) Lab 6 report", "Lab 6 report"), ("Lab 1: Measurement and density", "Lab 1"),
        ("Homework 1 (Sections 1.1-1.3)", "Homework 1"), ("Reading response 3 on Kant", "Reading response 3"),
        ("Project 1 Proposal", "Project 1 Proposal"), ("Final Exam", "Final Exam"), ("Essay on the French Revolution", "Essay on the French Revolution"),
        ("ELECTION 2026: POWER & POLITICS IN ACTION LIVE OB CASE STUDY", "ELECTION 2026: POWER & POLITICS IN ACTION LIVE OB CASE STUDY"),
        ("UNIT TEST 2 (MIDTERM)", "UNIT TEST 2 (MIDTERM)"), ("Week 9: Motivation cases. UNIT TEST 2 (MIDTERM)", "UNIT TEST 2 (MIDTERM)"),
    ]) func ownNameOutOfACopiedRow(title: String, expected: String) {
        #expect(Merger.ownName(title) == expected)
    }

    @Test func sectionNumbersAreNotComponents() {
        let r = Self.merge([Self.outcome(0, components: [Self.component("5.3-4", nil), Self.component("11.8-9", nil), Self.component("Quizzes", 12)])], text: "Week 1 Aug 31 - Sept 4 no classes 5.3-4 11.8-9. Quizzes 12%.")
        #expect(r.gradeComponents.map(\.name) == ["Quizzes"])
    }

    @Test func aSpanOfDaysIsNotADeadline() {
        let text = """
        Week Dates Monday Wednesday (Fri)
        3 Sept 14-18 7.1-2 PS0 due 7.3
        14 Nov 30 - Dec 4 11.10 PS5 due 11.11
        Quiz 1: Thu 9/17.
        """
        let r = Self.merge([Self.outcome(0, obligations: [
            Self.ob("PS0", "Sept 14-18", iso: "2026-09-18"), Self.ob("PS5", "30 - Dec 4", iso: "2026-12-04"), Self.ob("Quiz 1", "Thu 9/17", iso: "2026-09-17"),
        ])], text: text)
        let byTitle = Dictionary(uniqueKeysWithValues: r.obligations.map { ($0.title, $0) })
        #expect(byTitle["PS0"]?.status == .needsReview && byTitle["PS0"]?.flags.contains(.dateAmbiguous) == true)
        #expect(byTitle["PS5"]?.status == .needsReview && byTitle["PS5"]?.flags.contains(.dateAmbiguous) == true)
        #expect(byTitle["Quiz 1"]?.status == .ready)
    }

    @Test func topicListingsAndSessionsAreNotObligations() {
        let text = """
        Week 3: Monday, September 14 and Wednesday, September 16: Monday: Chapter 1. Wednesday: Chapter 2, Diversity, Equity & Inclusion in Organizations.
        Oct 7 UNIT TEST 1 Chapters 1–4
        Oct 21 SHARK TANK GROUP WORK SESSION #1 In-class planning
        Dec 14 Course synthesis and final examination preparation
        """
        let r = Self.merge([Self.outcome(0, obligations: [
            Self.ob("Chapter 2, Diversity, Equity & Inclusion in Organizations", "Wednesday, September 16", iso: "2026-09-16"),
            Self.ob("UNIT TEST 1", "Oct 7", iso: "2026-10-07"), Self.ob("SHARK TANK GROUP WORK SESSION #1", "Oct 21", iso: "2026-10-21"),
            Self.ob("Course synthesis and final examination preparation", "Dec 14", iso: "2026-12-14"),
        ])], text: text)
        #expect(r.obligations.map(\.title) == ["UNIT TEST 1"] && r.obligations[0].status == .ready)
        #expect(r.warnings.contains { $0.contains("topic, reading or session") })
    }

    @Test func aDateLiftedFromAnotherLineNeedsReview() {
        let text = """
        Students complete required MyLab work as directed before class.
        You must opt out of the program by September 17th.
        Exam 1 Tuesday, October 6th, 2026
        """
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("MyLab work", "September 17th", iso: "2026-09-17"), Self.ob("Exam 1", "Tuesday, October 6th, 2026", iso: "2026-10-06")])], text: text)
        let byTitle = Dictionary(uniqueKeysWithValues: r.obligations.map { ($0.title, $0) })
        #expect(byTitle["MyLab work"]?.status == .needsReview && byTitle["MyLab work"]?.flags.contains(.dateNotOnRow) == true)
        #expect(byTitle["Exam 1"]?.status == .ready)
    }

    @Test func aWeekNumberBeforeTheMonthIsNotADay() {
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Finals", "17 Dec 21-25", iso: "2026-12-17")])], text: "16 Dec 14-18 review Reading Day\n17 Dec 21-25- Finals Week")
        #expect(r.obligations.first?.status == .needsReview && r.obligations.first?.flags.contains(.dateAmbiguous) == true)
    }

    @Test func theGradeTablesFigureWinsOverTheModels() {
        let text = "WebAssign 4%\nProblem Sets 4%\nQuizzes 12%\nExam 1 25%\nExam 2 25%\nFinal Exam 30%\nTotal 100%"
        let r = Self.merge([Self.outcome(0, components: [Self.component("Problem sets (written)", 10)])], text: text)
        #expect(r.gradeComponents.first { $0.name.hasPrefix("Problem") }?.weight == 0.04)
    }

    @Test func sameDayTitlesNestedInEachOtherAreOneItem() {
        let text = "Election 2026: Power & Politics in Action — due Monday, November 9, 2026. The Election 2026 assignment is due Monday, November 9."
        let r = Self.merge([Self.outcome(0, obligations: [
            Self.ob("ELECTION 2026: POWER & POLITICS IN ACTION — DUE", "Monday, November 9, 2026", iso: "2026-11-09"),
            Self.ob("Election 2026 assignment", "Monday, November 9", iso: "2026-11-09"),
        ])], text: text)
        #expect(r.obligations.count == 1)
    }

    @Test func aKnownCourseSeedsAScheduleThatNamesNothing() {
        let text = """
        Week Dates Monday Wednesday
        3 Sept 14-18 7.1-2 PS0 due Wed Sept 16
        4 Sept 21-25 7.4 PS1 due Wed Sept 23
        6 Oct 5-9 review Midterm I Wed Oct 7
        """
        var options = Self.options
        let cal = options.calendar
        options.knownCourse = KnownCourse(code: "MA-UY 1124", title: "Calculus II", term: "Fall 2026",
                                          termStart: cal.date(from: DateComponents(year: 2026, month: 9, day: 2)), termEnd: cal.date(from: DateComponents(year: 2026, month: 12, day: 14)),
                                          components: [KnownComponent(name: "Problem Sets", weight: 0.04, expectedCount: 6, platform: .gradescope), KnownComponent(name: "Exam 1", weight: 0.25, cadence: .once)])
        let r = Merger.merge(outcomes: [Self.outcome(0, obligations: [
            Self.ob("PS0", "Wed Sept 16", iso: "2026-09-16"), Self.ob("PS1", "Wed Sept 23", iso: "2026-09-23"), Self.ob("Midterm I", "Wed Oct 7", iso: "2026-10-07"),
        ])], document: DocumentNormalizer.normalize(text: text, name: "schedule.txt"), route: .onDevice, options: options, warnings: [])
        #expect(r.course?.code == "MA-UY 1124" && Self.day(r.course?.termStart) == 2)                  // the document names no course; the known one stands
        #expect(r.gradeComponents.map(\.name) == ["Problem Sets", "Exam 1"])                          // known components are not "missing from the document"
        let ps = r.obligations.first { $0.title == "PS0" }!
        #expect(ps.componentName == "Problem Sets" && ps.platform == .gradescope && ps.pointsAtStake == 0.67)   // 4% ÷ 6, on the syllabus's platform
        #expect(r.obligations.first { $0.title == "Midterm I" }?.componentName == "Exam 1")
    }

    @Test func missingWeightIsRecoveredFromTheSourceLine() {
        let r = Self.merge([Self.outcome(0, components: [Self.component("Homework", nil), Self.component("Final Exam", nil), Self.component("Participation", nil)])])
        #expect(r.gradeComponents.map(\.weight) == [0.15, 0.33])   // Participation is not in the document → dropped, not kept weightless
    }

    @Test func platformComesFromTheDocumentBeforeTheModel() {
        let text = """
        Homework (WebAssign, weekly) ...... 15%
        Projects 20% two programming projects
        Quizzes 65% on Gradescope
        HW 1 due Wed 9/9 on Gradescope. Project 1 due Fri Oct 16, 11:59 PM, Brightspace. Quiz 1 Thu 9/17.
        Project 2      Nov 6       Fri Dec 4, 11:59 PM       Brightspace
        HW 2: TBA.
        """
        let r = Self.merge([Self.outcome(0, components: [Self.component("Homework", 15), Self.component("Projects", 20), Self.component("Quizzes", 65, platform: "webassign")], obligations: [
            Self.ob("HW 1", "Wed 9/9", iso: "2026-09-09", platform: "lms"),                       // its own sentence says Gradescope, beating the grading row and the model
            Self.ob("Project 1", "Fri Oct 16, 11:59 PM", iso: "2026-10-16", platform: "not_stated"),   // its own sentence says Brightspace
            Self.ob("Quiz 1", "Thu 9/17", iso: "2026-09-17", platform: "gradescope"),                   // grading row says Gradescope even though the model read it as WebAssign
            Self.ob("Project 2", "Fri Dec 4, 11:59 PM", iso: "2026-12-04", platform: "not_stated"),      // table row
            Self.ob("HW 2", "TBA", platform: "lms"),                                                     // grading row says WebAssign, beating the model
        ])], text: text)
        let platforms = Dictionary(uniqueKeysWithValues: r.obligations.map { ($0.title, $0.platform) })
        #expect(platforms == ["HW 1": .gradescope, "Project 1": .lms, "Quiz 1": .gradescope, "Project 2": .lms, "HW 2": .webAssign])
        let rows = Dictionary(uniqueKeysWithValues: r.gradeComponents.map { ($0.name, $0.platform) })
        #expect(rows == ["Homework": .webAssign, "Projects": nil, "Quizzes": .gradescope])   // the grading rows' own words carry through; a row that says nothing carries nothing
        // Neither the item's row nor its grading row names a platform: the model's "lms" guess is not evidence in a text document.
        let guess = Self.merge([Self.outcome(0, components: [Self.component("Quizzes", 12, platform: "lms")], obligations: [Self.ob("Quiz 1", "Thu 9/17", iso: "2026-09-17", platform: "lms")])])
        #expect(guess.obligations[0].platform == .syllabusOnly)
    }

    @Test func aSiteIsNamedOnlyByItsOwnName() {
        // Words that merely resemble a site: a publisher, a cloth, the board on the wall, a verb.
        #expect(Merger.Source.platforms(in: "Textbook: Calculus, 8th edition, Pearson.").isEmpty)
        #expect(Merger.Source.platforms(in: "Bring a stretched canvas; sketches go on the blackboard.").isEmpty)
        #expect(Merger.Source.platforms(in: "Homework 20%: mastering the material takes weekly practice").isEmpty)
        #expect(Merger.Source.platforms(in: "Web assignments are posted Fridays").isEmpty)
        // The products' own names, however set.
        #expect(Merger.Source.platforms(in: "Essays are submitted on Canvas by Friday") == [.lms])
        #expect(Merger.Source.platforms(in: "QUIZZES ON BLACKBOARD") == [.lms])
        #expect(Merger.Source.platforms(in: "posted on Blackboard Learn each week") == [.lms])
        #expect(Merger.Source.platforms(in: "MasteringPhysics closes Sundays 11:59 PM") == [.myLab])
        #expect(Merger.Source.platforms(in: "MYLAB ECONOMICS deadlines") == [.myLab])
        #expect(Merger.Source.platforms(in: "gradescope and WebAssign both") == [.webAssign, .gradescope])
        // And through the merger: a text document's rows name the sites, or nothing does.
        let text = """
        Textbook: Calculus, 8th edition, Pearson. Bring a stretched canvas to the studio; sketches go on the blackboard.
        Homework 20% mastering the material takes weekly practice
        Labs 30% on Mastering Physics
        Essays 25% submitted on Canvas
        Quizzes 25% on Blackboard Learn
        HW 1 due Wed 9/9. Lab 1 due Thu 9/17. Essay 1 due Wednesday, October 7. Quiz 1 due Mon 9/14.
        """
        let r = Self.merge([Self.outcome(0, components: [Self.component("Homework", 20, platform: "mylab"), Self.component("Labs", 30), Self.component("Essays", 25), Self.component("Quizzes", 25)],
                                         obligations: [Self.ob("HW 1", "Wed 9/9", iso: "2026-09-09", platform: "mylab"), Self.ob("Lab 1", "Thu 9/17", iso: "2026-09-17"),
                                                       Self.ob("Essay 1", "Wednesday, October 7", iso: "2026-10-07"), Self.ob("Quiz 1", "Mon 9/14", iso: "2026-09-14")])], text: text)
        let rows = Dictionary(uniqueKeysWithValues: r.gradeComponents.map { ($0.name, $0.platform) })
        #expect(rows == ["Homework": nil, "Labs": .myLab, "Essays": .lms, "Quizzes": .lms])   // the model's MyLab for homework is not the document's word
        let items = Dictionary(uniqueKeysWithValues: r.obligations.map { ($0.title, $0.platform) })
        #expect(items == ["HW 1": .syllabusOnly, "Lab 1": .myLab, "Essay 1": .lms, "Quiz 1": .lms])
    }

    @Test func gradingRowWeightBeatsTheModels() {
        let r = Self.merge([Self.outcome(0, components: [Self.component("Homework", 10), Self.component("Quizzes", 10)])])   // the model misread 15% and 12%
        #expect(r.gradeComponents.map(\.weight) == [0.15, 0.12])
    }

    @Test func modelDateOnAnotherRowIsNotHeldAgainstTheItem() {
        // The model's ISO date (9/30) is HW 4's date, not on HW 3's row: a stray misread, not an ambiguity.
        let text = "Week 3: HW 3 due 9/23.\nWeek 4: HW 4 due 9/30."
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 3", "9/23", iso: "2026-09-30")])], text: text)
        #expect(r.obligations[0].status == .ready && Self.day(r.obligations[0].due) == 23)
    }

    @Test func gradeTableRowsTheModelSkippedAreRecovered() {
        let text = """
        BIO-UA 11. Grading:
        Weekly Quizzes      20%   on Brightspace; lowest two quiz scores dropped
        Lab Reports         20%   four reports
        Exam 1              20%
        Exam 2              20%
        Final Exam          20%   cumulative
        Lab reports lose 10% per day late. Up to 2% extra credit is available.
        """
        let r = Self.merge([Self.outcome(0, components: [Self.component("Weekly Quizzes", 20)])], text: text)
        #expect(r.gradeComponents.map(\.name) == ["Weekly Quizzes", "Lab Reports", "Exam 1", "Exam 2", "Final Exam"])
        #expect(r.gradeComponents.allSatisfy { $0.weight == 0.2 })
        #expect(r.warnings.filter { $0.contains("read from the grade table") }.count == 4)
        // A table that does not sum to ~100% is not a grade table.
        let none = Self.merge([Self.outcome(0)], text: "Attendance 10%\nParticipation 5%")
        #expect(none.gradeComponents.isEmpty)
    }

    @Test func cadenceImpliedCountDrivesPoints() {
        let r = Self.merge([Self.outcome(0, course: Self.course, components: [Self.component("Quizzes", 12, cadence: "weekly")], obligations: [Self.ob("Quiz 1", "Thu 9/17", iso: "2026-09-17")])])
        #expect(r.obligations[0].pointsAtStake == 0.86)   // 12% ÷ 14 whole weeks (Sep 2 – Dec 14)
    }

    @Test func dropsGarbageAndKeepsSupportedTBD() {
        let r = Self.merge([Self.outcome(0, components: [Self.component("Final Exam", 33), Self.component("Quizzes", 12)], obligations: [
            Self.ob("Final Exam", "null, isTBD"),                 // wording absent from the source → dropped
            Self.ob("Quizzes", "roughly every 1–2 weeks"),         // names a component, no TBD wording → dropped
            Self.ob("Final Exam", "date TBA by the registrar"),    // supported TBD → kept
            Self.ob("Final Exam", "TBA", iso: "2026-12-14"),       // TBD wording with an invented ISO date → no date, deduped into the TBD item
            Self.ob("Homework 9", "Week 11: HW 9 due 11/18", iso: "2026-11-18"),   // neither wording nor date in the source → dropped
        ])])
        #expect(r.obligations.map(\.title) == ["Final Exam"])
        #expect(r.obligations[0].status == .awaitingDate && r.obligations[0].due == nil)
        #expect(r.warnings.contains { $0.contains("dropped") })
    }

    @Test func wordingIsSupportedWhenItsDatesAre() {
        // The model tightened "date TBA by the registrar (during finals week, December 16–22)" to a phrase that is not a substring.
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Final Exam", "TBA (December 16–22)")])],
                           text: Self.source + "\nFinal Exam: date TBA by the registrar (during finals week, December 16–22).")
        #expect(r.obligations.map(\.title) == ["Final Exam"] && r.obligations[0].status == .awaitingDate)
        let dated = Self.merge([Self.outcome(0, obligations: [Self.ob("Midterm 1", "Wed, October 7 in class", iso: "2026-10-07")])])
        #expect(dated.obligations.count == 1 && dated.obligations[0].status == .ready)
    }

    @Test func firstOfSeveralDatesOnTheRowNeedsReview() {
        let text = """
        Date      Lab                                   Report due
        Sep 9     Lab 1: Measurement and density        Sep 16
        Week 14 (May 4, 6): Review; project presentations in lab
        HW 1          Sep 4       Fri Sep 18, 11:59 PM      Gradescope
        14    Nov 30-Dec 4   Exam 3 (Thu Dec 3)           Lab 6 report due Fri Dec 4
        """
        let r = Self.merge([Self.outcome(0, obligations: [
            Self.ob("Lab 1: Measurement and density", "Sep 9", iso: "2026-09-09"),          // session date, report due later → review
            Self.ob("Project presentations in lab", "May 4", iso: "2026-05-04"),           // topic line with two meeting dates → review
            Self.ob("HW 1", "Sep 4", iso: "2026-09-04"),                                    // release date chosen over the due date → review
            Self.ob("Exam 3", "Thu Dec 3", iso: "2026-12-03"),                              // not the first date on its row → fine
            Self.ob("Lab 6 report", "Fri Dec 4", iso: "2026-12-04"),                        // due-anchored → fine
        ])], text: text)
        let byTitle = Dictionary(uniqueKeysWithValues: r.obligations.map { ($0.title, $0) })
        for title in ["Lab 1", "Project presentations in lab", "HW 1"] {   // "Lab 1: Measurement and density" keeps its own name
            #expect(byTitle[title]?.status == .needsReview && byTitle[title]?.flags.contains(.dateAmbiguous) == true, "\(title)")
        }
        #expect(byTitle["Exam 3"]?.status == .ready && byTitle["Lab 6 report"]?.status == .ready)
    }

    @Test func disagreementWithADateTheDocumentAlsoNamesNeedsReview() {
        let text = "Sep 9     Lab 1: Measurement and density        Sep 16\nLab reports are due one week after each lab."
        // Wording says Sep 9 (one span, in the document); the model's ISO says Sep 16, which the document also names → review.
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Lab 1", "Sep 9", iso: "2026-09-16")])], text: text)
        #expect(r.obligations[0].status == .needsReview && r.obligations[0].flags.contains(.dateDisagreement))
    }

    @Test func acronymTitlesFindTheirComponent() {
        let comps = [ParsedGradeComponent(name: "Mastering Physics Homework", weight: 0.15), ParsedGradeComponent(name: "Labs", weight: 0.15)]
        #expect(Merger.inferComponent(fromTitle: "MP HW 1", in: comps) == "Mastering Physics Homework")
        #expect(Merger.inferComponent(fromTitle: "Lab 3 report", in: comps) == "Labs")
    }

    @Test func screenshotsInheritThePagesOnlyPlatform() {
        let text = "Gradescope\nCS-UY 2413 Assignments\nHomework 1\nSep 16 at 11:59PM"
        let r = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("Homework 1", "Sep 16 at 11:59PM", iso: "2026-09-16", platform: "lms")])], text: text)
        #expect(r.obligations[0].platform == .gradescope)
        let prose = Self.merge([Self.outcome(0, kind: .text, obligations: [Self.ob("Quiz 1", "Thu 9/17", iso: "2026-09-17", platform: "not_stated")])])
        #expect(prose.obligations[0].platform == .syllabusOnly)   // a text document naming one platform does not tag in-class items with it
    }

    @Test func singleCorroboratedDateIsNotPenalizedByAModelMistake() {
        // Model wrote the wrong year; the wording names one date and the document contains it → ready, flag kept for information.
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 1", "Wed 9/9", iso: "2025-09-09")])])
        #expect(r.obligations[0].status == .ready && r.obligations[0].flags == [.dateDisagreement] && Self.day(r.obligations[0].due) == 9)
    }

    @Test func modelComputedDateNeedsReview() {
        // Wording is in the source but names no day; the model's date is not mentioned anywhere → review, never ready.
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Homework", "weekly", iso: "2026-09-24")])])
        #expect(r.obligations.count == 1 && r.obligations[0].status == .needsReview && r.obligations[0].flags.contains(.dateNotInSource))
    }

    @Test func imagePagesAreCheckedLeniently() {
        // OCR text may misread a date: an unsupported date from an image page is kept for review, not dropped.
        let r = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("Reaction Paper 1", "Oct 9, 2026 11:59 PM", iso: "2026-10-09")])])
        #expect(r.obligations.count == 1 && r.obligations[0].status == .needsReview && r.obligations[0].flags.contains(.dateNotInSource))
        let ok = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("HW 1", "Wed 9/9", iso: "2026-09-09")])])
        #expect(ok.obligations[0].status == .ready)
    }

    @Test func unreadableImageGoesToReview() {
        // Vision found no text: nothing can corroborate the model, so the item is kept but reviewed.
        let r = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("Reaction Paper 1", "Oct 9, 2026 11:59 PM", iso: "2026-10-09")])], text: "")
        #expect(r.obligations.count == 1 && r.obligations[0].status == .needsReview)
    }

    @Test func emptyWordingGoesToReview() {
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 1", "", iso: "2026-09-09")])])
        #expect(r.obligations.count == 1 && r.obligations[0].status == .needsReview && Self.day(r.obligations[0].due) == 9)
    }

    @Test func rowLookupFallsBackToHeadAndNumber() {
        // The row says "Lab 2: Calorimetry" while the title is "Lab 2 report"; the session date must still be caught.
        let text = "Date      Lab                      Report due\nSep 23    Lab 2: Calorimetry       Sep 30"
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Lab 2 report", "Sep 23", iso: "2026-09-23")])], text: text)
        #expect(r.obligations[0].status == .needsReview && r.obligations[0].flags.contains(.dateAmbiguous))
    }

    @Test func dateNotOnTheItemsRowNeedsReview() {
        let text = "8     Oct 19-23      Rotation                     MP HW 6 due Sun Oct 25\n6     Oct 5-9        Exam 1 (Thu Oct 8, in recitation slot)"
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("MP HW 6", "Oct 8", iso: "2026-10-08"), Self.ob("Exam 1", "Thu Oct 8", iso: "2026-10-08")])], text: text)
        let byTitle = Dictionary(uniqueKeysWithValues: r.obligations.map { ($0.title, $0) })
        #expect(byTitle["MP HW 6"]?.status == .needsReview && byTitle["MP HW 6"]?.flags.contains(.dateAmbiguous) == true)   // its row says Oct 25
        #expect(byTitle["Exam 1"]?.status == .ready)
    }

    @Test func rowLookupSkipsDatelessMentions() {
        // "Exam 2" appears first in the grading table; the dated schedule row further down is the one that counts.
        let text = "Exam 2                          15%\n10    Nov 2-6        Exam 2 (Thu Nov 5)\n9     Oct 26-30      Angular momentum             MP HW 7 due Sun Nov 1; Lab 4\nreport due Fri Oct 30"
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Exam 2", "Tue Nov 10", iso: "2026-11-10"), Self.ob("Lab 4 report", "Oct 9", iso: "2026-10-09")])], text: text)
        #expect(r.obligations.allSatisfy { $0.status == .needsReview && $0.flags.contains(.dateAmbiguous) })   // neither date is on its row
    }

    @Test func wrappedDateFragmentJoinsItsRow() {
        // The PDF broke the row after "due Fri"; the next line is only the date. A correct Oct 16 must not be flagged.
        let text = "7     Oct 13-16      Momentum MP HW 5 due Sun Oct 18; Lab 3 report due\nFri Oct 16\n8     Oct 19-23      Rotation"
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Lab 3 report", "Fri Oct 16", iso: "2026-10-16"), Self.ob("MP HW 5", "Sun Oct 18", iso: "2026-10-18")])], text: text)
        #expect(r.obligations.allSatisfy { $0.status == .ready && !$0.flags.contains(.dateAmbiguous) })
        #expect(Merger.Source.isDateFragment("Oct 30") && Merger.Source.isDateFragment("Fri Oct 16, 11:59 PM") && Merger.Source.isDateFragment("9/16."))
        #expect(!Merger.Source.isDateFragment("8     Oct 19-23      Rotation") && !Merger.Source.isDateFragment("Oct 30 is the deadline"))
    }

    @Test func inventedTitleOnATopicLineNeedsReview() {
        let text = "Week 13 (Apr 27, 29): Multiple regression preview; project work.\nProject report due Friday, May 7, 11:59 PM on Gradescope."
        var o = Self.options; o.defaultYear = 2027
        let r = Merger.merge(outcomes: [Self.outcome(0, obligations: [Self.ob("Project report", "Apr 27", iso: "2027-04-27"), Self.ob("Project report", "Friday, May 7, 11:59 PM", iso: "2027-05-07")])],
                             document: DocumentNormalizer.normalize(text: text, name: "t"), route: .onDevice, options: o, warnings: [])
        let april = r.obligations.first { o.calendar.component(.month, from: $0.due!) == 4 }!
        #expect(april.status == .needsReview && april.flags.contains(.dateAmbiguous))
        #expect(r.obligations.first { o.calendar.component(.month, from: $0.due!) == 5 }?.status == .ready)
    }

    @Test func screenshotWithAReleasedColumnIsReviewed() {
        // Cells OCR could not reassemble into a row: the page-wide Released column makes every dated item a review.
        let scattered = "Gradescope\nName\nReleased\nHomework 1\nSep 2 at 12:00PM\nDue\nSep 16 at 11:59PM"
        let r = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("Homework 1", "Sep 2 at 12:00PM", iso: "2026-09-02")])], text: scattered)
        #expect(r.obligations[0].status == .needsReview && r.obligations[0].flags.contains(.dateAmbiguous))
        // Reassembled rows: the precise rule decides, so a correctly read Due date ships and a Released date does not.
        let rows = "Gradescope\nName  Released  Due  Late Due\nHomework 1  Sep 2 at 12:00PM  Sep 16 at 11:59PM  Sep 18 at 11:59PM"
        let good = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("Homework 1", "Sep 16 at 11:59PM", iso: "2026-09-16")])], text: rows)
        #expect(good.obligations[0].status == .ready)
        let bad = Self.merge([Self.outcome(0, kind: .image, obligations: [Self.ob("Homework 1", "Sep 2 at 12:00PM", iso: "2026-09-02")])], text: rows)
        #expect(bad.obligations[0].status == .needsReview)
    }

    @Test func realSyllabusGradeTableWithTotalAndInterleavedScale() {
        // The PDF text layer interleaves the letter-grade scale with the weights and ends with "Total 100%".
        let text = """
        Grade Range Letter Grade
        [94,∞) A
        Item Weight
        [90,94) A−
        WebAssign 4%
        [87,90) B+
        Problem Sets 4%
        [83,87) B
        Quizzes 12%
        Exam 1 25%*
        Exam 2 25%*
        Final Exam 30%
        [70,73) C−
        Total 100%
        """
        let r = Self.merge([Self.outcome(0, components: [Self.component("Labs", 10)])], text: text)   // "Labs" is invented: not in the document
        #expect(r.gradeComponents.map(\.name) == ["WebAssign", "Problem Sets", "Quizzes", "Exam 1", "Exam 2", "Final Exam"])
        #expect(r.gradeComponents.map { Int(($0.weight ?? 0) * 100) } == [4, 4, 12, 25, 25, 30])
        #expect(r.warnings.contains { $0.contains("not in the document") })
    }

    @Test func gradeTableIsAContiguousRun() {
        let text = """
        Homework 40%
        Final Exam 60%
        Letter grades: A 93–100%, A- 90–92%, B+ 87–89%, B 83–86%
        """
        let r = Self.merge([Self.outcome(0)], text: text)
        #expect(r.gradeComponents.map(\.name) == ["Homework", "Final Exam"])
        let wrapped = Self.merge([Self.outcome(0)], text: "Weekly Quizzes 20% on Brightspace, every Friday by 5:00 PM; lowest two quiz scores\ndropped\nLab Reports 20% four reports\nExam 1 20%\nExam 2 20%\nFinal Exam 20% cumulative")
        #expect(wrapped.gradeComponents.count == 5)   // a wrapped row does not split the table
        let penalty = Self.merge([Self.outcome(0, components: [Self.component("Homework", nil)])], text: "Late homework loses 10% per day.\nHomework 40%\nFinal 60%")
        #expect(penalty.gradeComponents[0].weight == 0.4)   // the penalty line is skipped when recovering a weight
    }

    @Test func dedupesAcrossChunksAndDatedSupersedesTBD() {
        let r = Self.merge([
            Self.outcome(0, obligations: [Self.ob("Midterm 1", "TBA", confidence: "low"), Self.ob("HW 1", "Wed 9/9", iso: "2026-09-09", confidence: "medium")]),
            Self.outcome(1, obligations: [Self.ob("Midterm 1", "Wednesday, October 7", iso: "2026-10-07"), Self.ob("HW 1", "Wed 9/9", iso: "2026-09-09")]),
        ])
        #expect(r.obligations.map(\.title) == ["HW 1", "Midterm 1"])
        #expect(r.obligations[0].confidence > 0.9)   // the higher-confidence duplicate survived
        #expect(r.obligations[1].due != nil)
        #expect(r.warnings.contains { $0.contains("superseded") })
    }

    @Test func twoDatesForOneItemIsAConflict() {
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("Midterm 1", "Wednesday, October 7", iso: "2026-10-07"), Self.ob("Midterm 1", "Thu 9/17", iso: "2026-09-17", confidence: "medium")])])
        #expect(r.obligations.count == 2 && r.obligations.allSatisfy { $0.flags.contains(.conflictingDate) })
        #expect(r.obligations.first { Self.day($0.due) == 17 }?.status == .needsReview)
        #expect(r.obligations.first { Self.day($0.due) == 7 }?.status == .ready)
        // Three dates is a series, not a conflict.
        let series = Self.merge([Self.outcome(0, obligations: [Self.ob("Quiz", "Thu 9/17", iso: "2026-09-17"), Self.ob("Quiz", "Wed 9/9", iso: "2026-09-09"), Self.ob("Quiz", "Wednesday, October 7", iso: "2026-10-07")])])
        #expect(series.obligations.allSatisfy { !$0.flags.contains(.conflictingDate) })
    }

    @Test func weightsBeyondHundredPercentAreIgnored() {
        let text = "MA-UY 1124 Calculus II. Homework, quizzes, midterm 1, midterm 2 and a final exam. HW 1 due Wed 9/9."   // names but no grading table: the model's figures are all there is
        let r = Self.merge([
            Self.outcome(0, components: [Self.component("Homework", 15), Self.component("Quizzes", 12), Self.component("Midterm 1", 20), Self.component("Midterm 2", 20), Self.component("Final Exam", 33)]),
            Self.outcome(1, components: [Self.component("Midterm", 15), Self.component("Homework", 10)]),
        ], text: text)
        #expect(r.gradeComponents.map(\.name) == ["Homework", "Quizzes", "Midterm 1", "Midterm 2", "Final Exam"])
        #expect(r.gradeComponents[0].weight == 0.15)
        #expect(r.warnings.count == 2)
        let unweighted = Self.merge([Self.outcome(0, components: [Self.component("Homework", 67), Self.component("Final Exam", 33)]), Self.outcome(1, components: [Self.component("quiz", nil)])], text: text)
        #expect(unweighted.gradeComponents.map(\.name) == ["Homework", "Final Exam"])
    }

    @Test func ambiguousWordingWithDisagreementNeedsReview() {
        // "due" settles multi-date wording: the model's pick of Sep 2 loses to the due date and goes to review.
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 1", "Week 1 (Sep 2): HW 1 due Wed 9/9", iso: "2026-09-02")])],
                           text: Self.source + "\nWeek 1 (Sep 2): HW 1 due Wed 9/9.")
        let hw = r.obligations[0]
        #expect(hw.flags.contains(.dateDisagreement) && hw.status == .needsReview)
        #expect(Self.day(hw.due) == 9)
        // Without "due", several named dates let the model choose.
        let free = Self.merge([Self.outcome(0, obligations: [Self.ob("Exam 3", "Nov 30-Dec 4, Thu Dec 3", iso: "2026-12-03")])], text: "14  Nov 30-Dec 4  Exam 3 (Thu Dec 3)")
        #expect(free.obligations[0].flags.isEmpty && Self.day(free.obligations[0].due) == 3)
        let other = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 1", "Week 1 (Sep 2): HW 1 due Wed 9/9", iso: "2026-09-16")])],
                               text: Self.source + "\nWeek 1 (Sep 2): HW 1 due Wed 9/9.")
        #expect(other.obligations[0].status == .needsReview && Self.day(other.obligations[0].due) == 9)
    }

    @Test func policiesKeepTheDocumentsWording() {
        let r = Self.merge([Self.outcome(0, policies: [
            PolicyFacts(kind: "late_work", text: "Late homework is not accepted; WebAssign closes at the deadline."),   // verbatim
            PolicyFacts(kind: "drop_rule", text: "The two lowest quiz scores get dropped"),                           // paraphrase → replaced by the source sentence
            PolicyFacts(kind: "attendance", text: "Attendance is mandatory every day."),                               // not in the document at all: dropped
        ])])
        #expect(r.policies.map(\.text) == ["Late homework is not accepted; WebAssign closes at the deadline.", "The lowest two quiz scores are dropped."])
        #expect(r.policies.map(\.kind) == [.lateWork, .dropRule] && r.policies.allSatisfy(\.verbatim))
        #expect(r.warnings.contains { $0.hasPrefix("1 policy sentence(s) dropped") })
    }

    @Test func policiesAreFiledByTheirWordsAndRecoveredWhenTheModelSkipsThem() {
        let text = """
        MA-UY 1124 Calculus II, Fall 2026
        Students will be allowed a maximum of one make-up exam throughout the semester for an excused reason. \
        We will drop the lowest three quiz grades at the end of the semester. There will be no extensions on these assignments. \
        Your course score will be determined according to the first table. Exam 1 is on Wednesday, October 7.
        """
        let r = Self.merge([Self.outcome(0, policies: [
            PolicyFacts(kind: "late_work", text: "Students will be allowed a maximum of one make-up exam throughout the semester for an excused reason."),   // real, filed wrong
            PolicyFacts(kind: "late_work", text: "Your course score will be determined according to the first table."),                                 // real, about no rule
            PolicyFacts(kind: "extra_credit", text: "Extra credit opportunities will be announced during the course."),                                 // boilerplate
            PolicyFacts(kind: "attendance", text: "Attendance is mandatory and will be monitored throughout the course."),                             // boilerplate
        ])], text: text)
        #expect(r.policies.first { $0.kind == .makeupExam }?.text.hasPrefix("Students will be allowed a maximum of one make-up exam") == true)
        #expect(r.policies.first { $0.kind == .dropRule }?.text == "We will drop the lowest three quiz grades at the end of the semester.")   // read from the document
        #expect(r.policies.first { $0.kind == .lateWork }?.text == "There will be no extensions on these assignments.")                       // read from the document
        #expect(!r.policies.contains { $0.text.contains("first table") || $0.kind == .extraCredit || $0.kind == .attendance })
        #expect(r.policies.allSatisfy(\.verbatim) && r.policies.count == 3)
        #expect(r.warnings.contains { $0.hasPrefix("3 policy sentence(s) dropped") } && r.warnings.contains { $0.contains("dropped scores read from the document") })
    }

    @Test func sessionLinesAndBareVerbsNeverShipReady() {
        let text = """
        BI-UY 1002 Biology, Fall 2026
        First lecture: Wednesday, September 2. Last lecture: Friday, December 11.
        Respond to the discussion prompt by Wednesday, September 2. Quiz 1 is on Friday, September 11.
        """
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("First lecture", "Wednesday, September 2", iso: "2026-09-02"), Self.ob("Last lecture", "Friday, December 11", iso: "2026-12-11"),
                                                          Self.ob("Respond", "Wednesday, September 2", iso: "2026-09-02"), Self.ob("Quiz 1", "Friday, September 11", iso: "2026-09-11")])], text: text)
        #expect(r.obligations.map(\.title) == ["Respond", "Quiz 1"])                          // the lectures are sessions, skipped
        #expect(r.obligations[0].status == .needsReview && r.obligations[1].status == .ready)   // a bare verb is reviewed, never shipped
    }

    @Test func anInventedNumberedSeriesWithScheduleDatesIsDropped() {
        let text = """
        MA-UY 1124 Calculus II, Fall 2026
        For each class day there will be a WebAssign assignment, due on Fridays.
        Week 7: Tuesday, October 13, integration by parts. Week 8: Tuesday, October 20, trigonometric integrals.
        Quiz 3 is on Friday, October 16.
        """
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 1", "Tuesday, October 13", iso: "2026-10-13"), Self.ob("HW 2", "Tuesday, October 20", iso: "2026-10-20"),
                                                          Self.ob("Quiz 3", "Friday, October 16", iso: "2026-10-16")])], text: text)
        #expect(r.obligations.map(\.title) == ["Quiz 3"])   // the document numbers no homework: HW 1 and HW 2 are made up, dates and all
        // A misnamed item on a line that asks for something survives, under the line's own name.
        let asks = text + "\nHW 5 is due Friday, October 23."
        let kept = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 3", "Friday, October 23", iso: "2026-10-23")])], text: asks)
        #expect(kept.obligations.count == 1)
    }

    @Test func recoveredPoliciesAreWholeSentencesWithoutHeadings() {
        let text = """
        MA-UY 1124 Calculus II, Fall 2026
        Attendance
        Class participation and attendance are an important part of the course. Please come prepared.
        Exam Policies
        Students will be allowed a maximum of one make-up exam throughout the entire semester per course for an excused reason listed below. There will be no remote makeup exams.
        """
        let r = Self.merge([Self.outcome(0, policies: [PolicyFacts(kind: "makeup_exam", text: "for an excused reason listed below. There will be no remote makeup exams.")])], text: text)
        #expect(r.policies.first { $0.kind == .attendance }?.text == "Class participation and attendance are an important part of the course.")   // no "Attendance" heading glued on
        #expect(r.policies.first { $0.kind == .makeupExam }?.text.hasPrefix("Students will be allowed a maximum of one make-up exam") == true)   // the whole sentence, not the cut
    }

    @Test func aHyphenWrappedWordIsWholeInASentence() {
        let text = """
        MA-UY 1124 Calculus II, Fall 2026
        Students must email the Math De-
        partment in order to request a make-up exam within two days of the missed exam.
        """
        let r = Self.merge([Self.outcome(0, policies: [PolicyFacts(kind: "makeup_exam", text: "partment in order to request a make-up exam within two days of the missed exam.")])], text: text)
        #expect(r.policies.first?.text == "Students must email the Math Department in order to request a make-up exam within two days of the missed exam.")
    }

    @Test func anInventedSeriesOfTBDItemsIsDropped() {
        let text = """
        MA-UY 1124 Calculus II, Fall 2026
        For each class day there will be a WebAssign assignment, due on Fridays.
        Excused absence requests must be submitted within two days of the missed exam.
        Final Exam: TBD (when the registrar decides, you will see it in Albert).
        """
        let r = Self.merge([Self.outcome(0, obligations: [Self.ob("HW 1", "TBD", iso: nil), Self.ob("HW 2", "TBD", iso: nil),
                                                          Self.ob("Excused absence request", "TBD", iso: nil), Self.ob("Final Exam", "TBD", iso: nil)])], text: text)
        #expect(r.obligations.map(\.title) == ["Final Exam"] && r.obligations[0].status == .awaitingDate)   // the series and the sentence's name are gone
    }

    @Test func noClassDatesResolveRanges() {
        let r = Self.merge([Self.outcome(0, course: Self.course, noClass: [
            NoClassFacts(dateAsWritten: "Monday, October 12 (Fall Recess)", startDate: "2026-10-12", endDate: nil),
            NoClassFacts(dateAsWritten: "Wednesday, November 25 – Friday, November 27 (Thanksgiving)", startDate: "2026-11-25", endDate: nil),
            NoClassFacts(dateAsWritten: "Friday, December 25", startDate: "2026-12-25", endDate: nil),   // not in the source → dropped
        ])])
        #expect(r.noClassDates.count == 2)
        #expect(Self.day(r.noClassDates[1].start) == 25 && Self.day(r.noClassDates[1].end) == 27)
    }

    @Test func rollingContextCarriesCourseAndComponents() {
        var context = RollingContext()
        context.absorb(ChunkExtraction(course: Self.course, gradeComponents: [Self.component("Homework", 15, platform: "webassign"), Self.component("Quizzes", 12)], obligations: [], policies: [], noClassDates: []))
        context.absorb(ChunkExtraction(course: CourseFacts(code: "OTHER", title: nil, instructor: nil, term: nil, termStart: nil, termEnd: nil, room: nil, meetings: []),
                                       gradeComponents: [Self.component("Homework", 10)], obligations: [], policies: [], noClassDates: []))
        #expect(context.courseLine == "MA-UY 1124 Calculus II" && context.termLine == "Fall 2026 (2026-09-02 to 2026-12-14)")
        #expect(context.componentLines == ["Homework (webassign)", "Quizzes"])
    }

    @Test func inferComponentFromTitle() {
        let comps = [ParsedGradeComponent(name: "Weekly Labs", weight: 0.3), ParsedGradeComponent(name: "Problem Sets", weight: 0.2),
                     ParsedGradeComponent(name: "Exam 1", weight: 0.2), ParsedGradeComponent(name: "Final Exam", weight: 0.3),
                     ParsedGradeComponent(name: "Response Papers", weight: 0.25), ParsedGradeComponent(name: "Quizzes", weight: 0.1)]
        #expect(Merger.inferComponent(fromTitle: "Lab 3", in: comps) == "Weekly Labs")
        #expect(Merger.inferComponent(fromTitle: "Problem Set 2", in: comps) == "Problem Sets")
        #expect(Merger.inferComponent(fromTitle: "Exam 1", in: comps) == "Exam 1")
        #expect(Merger.inferComponent(fromTitle: "Final Exam", in: comps) == "Final Exam")
        #expect(Merger.inferComponent(fromTitle: "Response Paper 4", in: comps) == "Response Papers")
        #expect(Merger.inferComponent(fromTitle: "Quiz 7", in: comps) == "Quizzes")
        #expect(Merger.inferComponent(fromTitle: "Field trip", in: comps) == nil)
        #expect(Merger.matchComponent("quiz", in: comps) == "Quizzes")
    }
}
