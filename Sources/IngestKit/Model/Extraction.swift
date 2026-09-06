import FoundationModels

// Model-facing schema. Strings only for dates; resolution happens deterministically in DateResolver.
// The schema is sent with every chunk on a 4096-token context: every description here costs input tokens on every call.

// Property order is generation order, and it matters: with the items generated last (after policies and breaks) the
// model read the first date on a row again and lost rows of a screenshot, so the items stay right after the table.
// When a runaway series ("HW 1 … HW 36") cuts the output before the policies, the merger reads the rules from the
// document's own sentences instead.
@Generable(description: "Facts stated in one chunk of a course document. Null or empty for anything not stated in the chunk.")
struct ChunkExtraction {
    var course: CourseFacts?
    @Guide(description: "Rows of a grade breakdown table present in this chunk.", .maximumCount(12))   // a table, not "HW 1…HW 36"
    var gradeComponents: [GradeComponentFacts]
    @Guide(description: "Graded or required items in this chunk that have a specific date or an explicit TBD.", .maximumCount(24))
    var obligations: [ObligationFacts]
    @Guide(description: "Policies, one sentence each, quoted word for word.", .maximumCount(6))
    var policies: [PolicyFacts]
    @Guide(description: "Holidays, breaks, cancelled sessions.", .maximumCount(8))
    var noClassDates: [NoClassFacts]
}

@Generable
struct CourseFacts {
    @Guide(description: "Course code as printed")
    var code: String?
    var title: String?
    var instructor: String?
    @Guide(description: "Term as printed, with its year")
    var term: String?
    @Guide(description: "First class day, YYYY-MM-DD")
    var termStart: String?
    @Guide(description: "Last class day, YYYY-MM-DD")
    var termEnd: String?
    var room: String?
    @Guide(.maximumCount(7))   // a run of "meetings" is where the small model loops
    var meetings: [MeetingFacts]
}

@Generable
struct MeetingFacts {
    @Guide(.anyOf(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]))
    var weekday: String
    @Guide(description: "HH:mm")
    var start: String?
    @Guide(description: "HH:mm")
    var end: String?
}

@Generable
struct GradeComponentFacts {
    @Guide(description: "Row name as printed")
    var name: String
    @Guide(description: "Percent of final grade", .range(0...100))
    var weightPercent: Double?
    @Guide(description: "Number of items, if stated")
    var count: Int?
    @Guide(.anyOf(["weekly", "biweekly", "once", "other"]))
    var cadence: String
    @Guide(description: "Lowest scores dropped, if stated")
    var dropLowest: Int?
    @Guide(.anyOf(["lms", "webassign", "gradescope", "mylab", "not_stated"]))
    var platform: String
}

@Generable
struct ObligationFacts {
    @Guide(description: "The item's own name as printed")
    var title: String
    @Guide(.anyOf(["lms", "webassign", "gradescope", "mylab", "not_stated"]))
    var platform: String
    @Guide(description: "Grade breakdown row name")
    var component: String?
    @Guide(description: "Only the date words for this item, copied exactly as printed, including a time if printed next to them, or the TBD wording")
    var dateAsWritten: String
    @Guide(description: "YYYY-MM-DD, or null if no date")
    var dueDate: String?
    @Guide(.anyOf(["high", "medium", "low"]))
    var confidence: String
}

@Generable
struct PolicyFacts {
    @Guide(.anyOf(["late_work", "makeup_exam", "attendance", "drop_rule", "extra_credit", "other"]))
    var kind: String
    @Guide(description: "Exact wording")
    var text: String
}

@Generable
struct NoClassFacts {
    @Guide(description: "Date words copied exactly")
    var dateAsWritten: String
    @Guide(description: "YYYY-MM-DD")
    var startDate: String?
    @Guide(description: "YYYY-MM-DD, same as startDate for one day")
    var endDate: String?
}
