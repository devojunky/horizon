import AppIntents
import Foundation
import HorizonCore
import IngestKit

// Questions Horizon answers from what it holds, nothing sent anywhere: about items (what's due, what matters most,
// where work piles up, what waits for review, what's done), about a course (what its documents say), and where the app
// is probably blind. One intent per kind of question, its variants parameters: Apple's guidance is that each intent
// does one thing and a variation is a parameter, never a second intent. Each answers aloud on its own (HIG: the spoken
// reply stands alone, a few items and then "and N more"), returns what it found for a shortcut's next step, and shows it
// in a snippet. Siri's own model acts only through schema intents (WWDC26); these reach Siri through the App
// Shortcuts' phrases, and Shortcuts, Spotlight and Shortcuts' Use Model action through their titles and parameters.

/// The stretches people ask about, and two more: what has gone by undone, and any time at all.
enum DueWindowChoice: String, AppEnum {
    case today, tomorrow, thisWeek, nextSevenDays, nextTwoWeeks, thisMonth, overdue, anyTime
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "When"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "Today", .tomorrow: "Tomorrow", .thisWeek: "This Week", .nextSevenDays: "In the Next 7 Days",
        .nextTwoWeeks: "In the Next Two Weeks", .thisMonth: "This Month",
        .overdue: DisplayRepresentation(title: "Overdue", synonyms: ["late", "behind", "past due"]),
        .anyTime: DisplayRepresentation(title: "Any Time", synonyms: ["at all", "ever", "whenever"]),
    ]

    var period: DuePeriod? {
        switch self {
        case .today: .today
        case .tomorrow: .tomorrow
        case .thisWeek: .thisWeek
        case .nextSevenDays: .nextSevenDays
        case .nextTwoWeeks: .nextTwoWeeks
        case .thisMonth: .thisMonth
        case .overdue, .anyTime: nil
        }
    }

    /// How an answer names a stretch: "this week", "in the next two weeks". Nil for overdue and any time, which each
    /// answer words its own way.
    var span: String? {
        switch self {
        case .today: "today"
        case .tomorrow: "tomorrow"
        case .thisWeek: "this week"
        case .nextSevenDays: "in the next seven days"
        case .nextTwoWeeks: "in the next two weeks"
        case .thisMonth: "this month"
        case .overdue, .anyTime: nil
        }
    }

    /// Whether a date falls in the stretch: its period's days (the start held, the end not), before now when overdue,
    /// anything at all (no date too) any time.
    func holds(_ date: Date?, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .anyTime: true
        case .overdue: date.map { $0 < now } ?? false
        default: date.map { period!.interval(at: now, calendar: calendar).holds($0) } ?? false
        }
    }
}

/// Which items a question is about.
enum ItemSelection: String, AppEnum {
    case due, mostImportant, pileups, toReview, done
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Items"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .due: DisplayRepresentation(title: "Due", synonyms: ["due soon", "coming up", "deadlines", "homework"]),
        .mostImportant: DisplayRepresentation(title: "Most Important", synonyms: ["matters most", "matters most next", "the most important", "heaviest",
                                                                                  "my biggest deadline", "worth the most"]),
        .pileups: DisplayRepresentation(title: "Piling Up", synonyms: ["pileups", "a pileup", "my next pileup", "crunch", "busiest"]),
        .toReview: DisplayRepresentation(title: "Waiting for Review", synonyms: ["to review", "needs review", "to check"]),
        .done: DisplayRepresentation(title: "Done", synonyms: ["finished", "completed", "checked off"]),
    ]

    /// The stretch a question means when it names none: this week; the two weeks "next" looks at (`DueQuery.nextWindow`);
    /// for pileups and review, whatever is on file.
    var usualWindow: DueWindowChoice {
        switch self {
        case .due, .done: .thisWeek
        case .mostImportant: .nextTwoWeeks
        case .pileups, .toReview: .anyTime
        }
    }
}

/// SPEC §7's `WhatsDueIntent`, and every other question about items: what's due when, what matters most next (SPEC
/// §7's Lock Screen item, asked aloud), where heavy work piles up (SPEC §6.2's collisions), what waits for review, what's
/// done. For one course or all.
struct GetItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Items"
    static let description = IntentDescription("Says which items are due in a stretch of time, for one course or all: what's due, what matters most (the heaviest first), where heavy work piles up, what waits for your review, or what's done. Says the first few aloud and returns them all.",
                                               categoryName: "Items", searchKeywords: ["due", "deadlines", "homework", "next", "most important", "priority", "pileup", "busy", "review", "done"],
                                               resultValueName: "Items")
    @Parameter(title: "Show", default: .due) var show: ItemSelection
    @Parameter(title: "When", description: "The stretch they're due in. By default this week; for what matters most, the next two weeks; for pileups and review, any time.")
    var when: DueWindowChoice?
    @Parameter(title: "Course") var course: CourseEntity?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Get what's \(\.$show) \(\.$when) for \(\.$course)") }

    @MainActor func perform() async throws -> some ReturnsValue<[ItemEntity]> & ProvidesDialog & ShowsSnippetView {
        let (all, courses) = try await model.intentItems()
        let courseID = course.flatMap { $0.isUnfiled ? nil : $0.id }
        let window = when ?? show.usualWindow
        let now = Date(), calendar = Calendar.current
        let whose = course.map { $0.isUnfiled ? "" : " for \($0.name)" } ?? ""
        let mine = all.filter { $0.deletedAt == nil && (courseID == nil || $0.courseID == courseID) }
        let named = course == nil   // across courses, each item says its course
        func entities(_ items: [ObligationSnapshot]) -> [ItemEntity] { items.map { ItemEntity($0, course: $0.courseID.flatMap { courses[$0] }) } }
        func spoken(_ items: some Collection<ObligationSnapshot>, max: Int = 3, say: (ObligationSnapshot) -> String = { Spoken.item($0, course: true) }) -> String {
            Spoken.list(items.prefix(max).map(say) + (items.count > max ? ["\(items.count - max) more"] : []))
        }
        func title(_ o: ObligationSnapshot) -> String { o.title + (named ? o.courseName.map { " for \($0)" } ?? "" : "") }

        switch show {
        case .due:
            let found: [ObligationSnapshot] = switch window {
            case .overdue: DueQuery.overdue(all, now: now, course: courseID)
            case .anyTime: mine.filter { $0.completedAt == nil }.sorted(by: Self.byDate)
            default: DueQuery.items(all, in: window.period!.interval(at: now, calendar: calendar), course: courseID)
            }
            let phrase = window == .overdue ? "overdue" : window.span.map { "due \($0)" } ?? "on your list"
            guard !found.isEmpty else {
                return .result(value: [], dialog: "Nothing is \(phrase)\(whose).", view: ItemsSnippet(kicker: phrase.uppercased(), items: [], empty: "Nothing \(phrase)."))
            }
            let lead = found.count == 1 ? "One thing is \(phrase)\(whose)" : "\(found.count) things are \(phrase)\(whose)"
            let items = spoken(found) { Spoken.item($0, course: named) }
            return .result(value: entities(found), dialog: IntentDialog(full: "\(lead): \(items).", supporting: "\(lead)."),
                           view: ItemsSnippet(kicker: phrase.uppercased(), items: entities(found)))

        case .mostImportant:
            let found: [ObligationSnapshot] = switch window {
            case .overdue: DueQuery.overdue(all, now: now, course: courseID).sorted { ($0.pointsAtStake ?? 0) > ($1.pointsAtStake ?? 0) }
            case .anyTime: DueQuery.byWeight(all, in: DateInterval(start: now, end: .distantFuture), now: now, course: courseID)
            default: DueQuery.byWeight(all, in: window.period!.interval(at: now, calendar: calendar), now: now, course: courseID)
            }
            let stretch = window == .overdue ? "of what's overdue" : window.span ?? "of everything ahead"
            guard let first = found.first else {
                let none = window == .overdue ? "Nothing is overdue\(whose)." : window.span.map { "Nothing is due \($0)\(whose)." } ?? "Nothing is ahead\(whose)."
                return .result(value: [], dialog: "\(none)", view: ItemsSnippet(kicker: "MOST IMPORTANT", items: [], empty: none))
            }
            let why = (first.pointsAtStake ?? 0) > 0 ? "It's the heaviest \(stretch)." : "Nothing \(stretch) carries a weight, so it's the soonest."
            let then = found.count > 1 ? " Then " + spoken(found.dropFirst(), max: 2) { Spoken.item($0, course: named) } + "." : ""
            let lead = Spoken.item(first, course: named).sentenceStart
            return .result(value: entities(found), dialog: IntentDialog(full: "\(lead). \(why)\(then)", supporting: "\(lead)."),
                           view: ItemsSnippet(kicker: "MOST IMPORTANT · \((window.span ?? (window == .overdue ? "overdue" : "ahead")).uppercased())", items: entities(found)))

        case .pileups:
            let today = calendar.startOfDay(for: now)
            let strip = mine.compactMap { o -> StripItem? in
                guard let due = o.due, o.completedAt == nil, due >= today else { return nil }
                return StripItem(id: o.id, title: o.title, courseID: o.courseID, courseCode: o.courseCode ?? "", courseName: o.courseName, due: due, dueHasTime: o.dueHasTime,
                                 points: o.pointsAtStake, state: o.state)
            }
            let pileups = Strip.collisions(strip, calendar: calendar).filter { window.holds($0.day, now: now, calendar: calendar) }
            let where_ = window.span ?? (window == .overdue ? "overdue" : "ahead")
            guard let next = pileups.first else {
                return .result(value: [], dialog: "No pileups \(where_)\(whose): no two heavy items fall within a day of each other.",
                                view: ItemsSnippet(kicker: "PILEUPS", items: [], empty: "No pileups \(where_)."))
            }
            let byID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<UUID>()
            let found = pileups.flatMap(\.items).compactMap { seen.insert($0.id).inserted ? byID[$0.id] : nil }
            let first = next.items.compactMap { byID[$0.id] }
            let later = pileups.count > 1 ? " \(Spoken.count(pileups.count - 1, "more pileup")) after that." : ""
            return .result(value: entities(found), dialog: "The next pileup\(whose) starts \(Spoken.due(next.day, hasTime: false)): \(Spoken.list(first.map(title))).\(later)",
                           view: ItemsSnippet(kicker: "PILEUP · \(next.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())", items: entities(first)))

        case .toReview:
            try model.requireLibrary()
            let queue = try await model.store.reviewQueue().filter { (courseID == nil || $0.courseID == courseID) && window.holds($0.due, now: now, calendar: calendar) }
            guard !queue.isEmpty else {
                return .result(value: [], dialog: "Nothing waits for review\(whose).", view: ItemsSnippet(kicker: "REVIEW", items: [], empty: "Nothing to review."))
            }
            let lead = "\(Spoken.count(queue.count, "item").sentenceStart) \(queue.count == 1 ? "waits" : "wait") for review\(whose)"
            return .result(value: entities(queue), dialog: IntentDialog(full: "\(lead): \(spoken(queue, say: title)).", supporting: "\(lead)."),
                           view: ItemsSnippet(kicker: "REVIEW", items: entities(queue)))

        case .done:
            let found = mine.filter { $0.isDone && window.holds($0.due, now: now, calendar: calendar) }.sorted(by: Self.byDate)   // done, not skipped
            let which = window == .overdue ? " past their date" : window.span.map { " due \($0)" } ?? ""
            guard !found.isEmpty else {
                return .result(value: [], dialog: "No item\(which)\(whose) is done yet.", view: ItemsSnippet(kicker: "DONE", items: [], empty: "Nothing done yet."))
            }
            let lead = found.count == 1 ? "One item\(which)\(whose) is done" : "\(found.count) items\(which)\(whose) are done"
            return .result(value: entities(found), dialog: IntentDialog(full: "\(lead): \(spoken(found, say: title)).", supporting: "\(lead)."),
                           view: ItemsSnippet(kicker: "DONE", items: entities(found)))
        }
    }

    /// Dated first, by date, the heavier first on the same moment; then the undated.
    static func byDate(_ a: ObligationSnapshot, _ b: ObligationSnapshot) -> Bool {
        (a.due ?? .distantFuture, -(a.pointsAtStake ?? 0), a.title) < (b.due ?? .distantFuture, -(b.pointsAtStake ?? 0), b.title)
    }
}

/// What a question about a course can name: how it's graded, or one of the policies documents state.
enum CourseTopic: String, AppEnum {
    case grading, lateWork, makeupExams, attendance, droppedScores, extraCredit
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .grading: DisplayRepresentation(title: "Grading", synonyms: ["grade breakdown", "grade", "weights", "how it's graded"]),
        .lateWork: DisplayRepresentation(title: "Late Work", synonyms: ["late", "extensions", "late penalty"]),
        .makeupExams: DisplayRepresentation(title: "Makeup Exams", synonyms: ["makeups", "test makeups", "missed exams", "makeup tests", "makeup exam"]),
        .attendance: DisplayRepresentation(title: "Attendance", synonyms: ["absences"]),
        .droppedScores: DisplayRepresentation(title: "Dropped Scores", synonyms: ["drops", "lowest score dropped"]),
        .extraCredit: DisplayRepresentation(title: "Extra Credit", synonyms: ["bonus"]),
    ]
    var question: CourseQuestion {
        switch self {
        case .grading: .grading
        case .lateWork: .policy(.lateWork)
        case .makeupExams: .policy(.makeupExam)
        case .attendance: .policy(.attendance)
        case .droppedScores: .policy(.dropRule)
        case .extraCredit: .policy(.extraCredit)
        }
    }
}

/// "What's the policy on test makeups for Calc?", "How is Bio graded?", "Who teaches Calc?": answered from the course's
/// own documents. A policy is quoted whole in their words, never summarised (SPEC §5).
struct GetCourseInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Course Info"
    static let description = IntentDescription("Answers from a course's own documents: a policy (late work, makeup exams, attendance, dropped scores, extra credit, or anything else they state) in their own words, or how the grade is made up. Asked nothing in particular, it says who teaches the course, the term, where it meets, how it's graded and which policies it states.",
                                               categoryName: "Courses", searchKeywords: ["policy", "makeup", "late", "attendance", "extra credit", "syllabus", "grading", "weights", "instructor"],
                                               resultValueName: "Answer")
    @Parameter(title: "Course", requestValueDialog: "Which course?") var course: CourseEntity
    @Parameter(title: "Topic") var topic: CourseTopic?
    @Parameter(title: "About", description: "Words the question is about, when it's none of the topics (say, calculators).") var about: String?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$course)'s \(\.$topic)") { \.$about } }

    @MainActor func perform() async throws -> some ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        guard !course.isUnfiled, let c = try await model.intentCourse(course.id) else { throw IntentFailure.message("That course is no longer in Horizon.") }
        let policies = try await model.intentPolicies().filter { $0.courseID == c.id }
        let words = about.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let asked = topic?.question ?? words.flatMap(CourseQuestion.topic(of:))
        let answer: CourseAnswer = switch asked {
        case .grading?: .said(Self.grading(c, subject: "\(c.displayName)'s grade"))
        case .policy(let kind)?: .quoted(policies, kind: kind, words: words, course: c.displayName)
        case nil where words != nil: .quoted(policies, kind: nil, words: words, course: c.displayName)   // words naming no topic: the policies they're about
        case .overview?, nil: .overview(c, policies: policies)
        }
        return .result(value: answer.value, dialog: answer.dialog, view: CourseInfoSnippet(course: c.displayName, lines: answer.lines, policies: answer.policies))
    }

    /// "Calculus II's grade is Homework 20%, Quizzes 10% and Final 30%."; the grade table is the course's own.
    static func grading(_ c: CourseSnapshot, subject: String) -> String {
        let rows = c.gradeComponents.filter { $0.weight != nil }
        guard !rows.isEmpty else { return "Horizon has no grade table on file for \(c.displayName)." }
        return "\(subject) is " + Spoken.list(rows.map { "\($0.name) \(($0.weight! * 100).formatted(.number.precision(.fractionLength(0...1))))%" }) + "."
    }
}

/// An answer about a course: what is said and returned, and what its snippet shows (lines, or the policies quoted).
struct CourseAnswer {
    var value: String
    var dialog: IntentDialog
    var lines: [String] = []
    var policies: [PolicySnapshot] = []

    static func said(_ line: String) -> CourseAnswer { CourseAnswer(value: line, dialog: "\(line)", lines: [line]) }

    /// The policy that answers, in the documents' own words, with how many others may apply.
    static func quoted(_ policies: [PolicySnapshot], kind: PolicyKind?, words: String?, course name: String) -> CourseAnswer {
        let found = PolicyLookup.answers(words, kind: kind == .other ? nil : kind, in: policies)
        guard let best = found.first, !policies.isEmpty else {
            return .said(policies.isEmpty ? "Horizon has no policies on file for \(name). Share its syllabus to read them."
                         : kind.map { "\(name)'s documents don't state a \(PolicyLookup.name($0).lowercased()) policy." }
                         ?? "\(name)'s documents don't say anything about “\(words ?? "")”.")
        }
        let source = best.verbatim ? "\(name)'s syllabus says" : "\(name)'s documents say"
        let others = found.count > 1 ? " \(Spoken.count(found.count - 1, "other passage")) may apply too." : ""
        return CourseAnswer(value: best.text, dialog: IntentDialog(full: "\(source): “\(best.text)”\(others)", supporting: "\(source):"), policies: Array(found.prefix(4)))
    }

    /// The course itself: its name, code and term, who teaches it, where it meets, how it's graded, what it states.
    static func overview(_ c: CourseSnapshot, policies: [PolicySnapshot]) -> CourseAnswer {
        var parts: [String] = []
        let who = [c.code == c.displayName || c.code.isEmpty ? nil : c.code, c.term].compactMap { $0 }.joined(separator: ", ")
        parts.append((who.isEmpty ? c.displayName : "\(c.displayName), \(who)") + (c.instructor.flatMap { $0.isEmpty ? nil : ", taught by \($0)" } ?? "") + ".")
        if let room = c.room, !room.isEmpty { parts.append("It meets in \(room).") }
        parts.append(GetCourseInfoIntent.grading(c, subject: "Its grade"))
        let kinds = Set(policies.map(\.kind)).filter { $0 != .other }.map { PolicyLookup.name($0).lowercased() }.sorted()
        if !kinds.isEmpty { parts.append("Its documents state policies on \(Spoken.list(kinds)).") }
        let line = parts.joined(separator: " ")
        return CourseAnswer(value: line, dialog: "\(line)", lines: parts)
    }
}

/// SPEC §6.1, aloud: where the app is probably blind. "Bio has been silent for 9 days and its syllabus implies weekly
/// quizzes" is the sentence the product exists to say.
struct CheckCoverageIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Coverage"
    static let description = IntentDescription("Says where Horizon is probably missing work: a course gone silent, a weekly rhythm with nothing on file, a site never read.",
                                               categoryName: "Courses", searchKeywords: ["blind", "missing", "silent", "coverage"])
    @Parameter(title: "Course") var course: CourseEntity?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Check coverage for \(\.$course)") }

    @MainActor func perform() async throws -> some ProvidesDialog & ShowsSnippetView {
        try model.requireLibrary()
        let all = try await model.store.coverage()
        let stories = course.map { wanted in all.filter { $0.id == wanted.id } } ?? all
        let blind = stories.filter { !$0.findings.isEmpty }
        guard !blind.isEmpty else {
            let line = course.map { "\($0.name) looks covered." } ?? (stories.isEmpty ? "Horizon has no courses yet." : "Every course looks covered.")
            return .result(dialog: "\(line)", view: CoverageSnippet(stories: stories))
        }
        let spoken = blind.prefix(2).map(\.headline)
        let more = blind.count > 2 ? " \(Spoken.count(blind.count - 2, "other course")) \(blind.count - 2 == 1 ? "has" : "have") gaps too." : ""
        return .result(dialog: "\(spoken.joined(separator: " "))\(more)", view: CoverageSnippet(stories: Array(blind.prefix(4))))
    }
}
