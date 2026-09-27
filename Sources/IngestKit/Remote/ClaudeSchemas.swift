import Foundation

/// The JSON Schemas for the structures Claude fills, written by hand to mirror the `@Generable` types field for field
/// (names, enumerations, the same descriptions), so one decoder serves both routes. Property order is kept as written,
/// because the API makes the model write properties in the schema's order: a model that skips optional keys and then
/// wants one back out of order is forced into garbage (see DECISIONS 2026-09-14). Optional fields are simply not
/// required (the API allows that); counts and ranges are not allowed as keywords, so they live in the descriptions.
enum ClaudeSchemas {
    static let extractionObject: Node = .object([
        // The outline comes first: the model takes the measure of the whole document and commits to every item's
        // name before writing any of them, which is both a plan for it and an exact total for the reading bar.
        ("outline", .object([
            ("obligationTitles", .array(.string("The item's own short name as printed"), "The name of every graded or required item in this chunk that has its own date or an explicit TBD, in document order; the obligations below follow this list one for one")),
            ("gradeRows", .integer("How many rows of a grade breakdown table this chunk has; 0 if none")),
            ("policies", .integer("How many policy sentences this chunk states, for late work, makeup exams, attendance, drop rules and extra credit; 0 if none")),
            ("breaks", .integer("How many holidays, breaks and cancelled sessions this chunk lists; 0 if none")),
        ], required: ["obligationTitles", "gradeRows", "policies", "breaks"], description: "The measure of the chunk, taken first")),
        ("course", .object([
            ("code", .string("Course code as printed")),
            ("title", .string(nil)),
            ("instructor", .string(nil)),
            ("term", .string("Term as printed, with its year")),
            ("termStart", .string("First class day, YYYY-MM-DD")),
            ("termEnd", .string("Last class day, YYYY-MM-DD")),
            ("room", .string(nil)),
            ("meetings", .array(.object([
                ("weekday", .enumeration(["mon", "tue", "wed", "thu", "fri", "sat", "sun"])),
                ("start", .string("HH:mm")),
                ("end", .string("HH:mm")),
            ], required: ["weekday"]), "At most 7")),
        ], required: ["meetings"], description: "The course, when this chunk names it")),
        ("gradeComponents", .array(.object([
            ("name", .string("Row name as printed")),
            ("weightPercent", .number("Percent of final grade, 0 to 100")),
            ("count", .integer("Number of items, if stated")),
            ("cadence", .enumeration(["weekly", "biweekly", "once", "other"])),
            ("dropLowest", .integer("Lowest scores dropped, if stated")),
            ("platform", .enumeration(["lms", "webassign", "gradescope", "mylab", "not_stated"])),
        ], required: ["name", "cadence", "platform"]), "Rows of a grade breakdown table present in this chunk")),
        ("obligations", .array(.object([
            ("title", .string("The item's own name as printed")),
            ("platform", .enumeration(["lms", "webassign", "gradescope", "mylab", "not_stated"])),
            ("component", .string("Grade breakdown row name")),
            ("dateAsWritten", .string("Only the date words for this item, copied exactly as printed, including a time if printed next to them, or the TBD wording")),
            ("dueDate", .string("YYYY-MM-DD; omitted if no date")),
            ("confidence", .enumeration(["high", "medium", "low"])),
        ], required: ["title", "platform", "dateAsWritten", "confidence"]), "Graded or required items in this chunk that have a specific date or an explicit TBD, one per item, in document order")),
        ("policies", .array(.object([
            ("kind", .enumeration(["late_work", "makeup_exam", "attendance", "drop_rule", "extra_credit", "other"])),
            ("text", .string("Exact wording")),
        ], required: ["kind", "text"]), "Policies, one sentence each, quoted word for word; at most 6")),
        ("noClassDates", .array(.object([
            ("dateAsWritten", .string("Date words copied exactly")),
            ("startDate", .string("YYYY-MM-DD")),
            ("endDate", .string("YYYY-MM-DD, same as startDate for one day")),
        ], required: ["dateAsWritten"]), "Holidays, breaks, cancelled sessions")),
    ], required: ["outline", "gradeComponents", "obligations", "policies", "noClassDates"], description: "Facts stated in one chunk of a course document. Omitted or empty for anything not stated in the chunk.")

    static let extraction: String = render(ProcessInfo.processInfo.environment["HORIZON_NO_OUTLINE"] != nil ? withoutOutline(extractionObject) : extractionObject)   // the toggle is for the eval comparison only

    /// The same schema with the outline left out, to measure what the outline buys.
    static func withoutOutline(_ node: Node) -> Node {
        guard case .object(let properties, let required, let description) = node else { return node }
        return .object(properties.filter { $0.0 != "outline" }, required: required.filter { $0 != "outline" }, description: description)
    }

    /// A picture: its text transcribed first, then the facts read off it.
    static let pageReading: String = render(.object([
        ("transcript", .string("Every line of text visible in the picture, top to bottom, in reading order; a table row is one line with its cells separated by two spaces")),
        ("facts", extractionObject),
    ], required: ["transcript", "facts"], description: "A picture of a course document, transcribed, and the facts stated in it."))

    /// The calendar read before the plan: each event's use, in order, its title said back.
    static let calendar: String = render(.object([
        ("events", .array(.object([
            ("title", .string("The event's title as given")),
            ("use", .enumeration(["coursework", "fixed"])),
            ("course", .string("For coursework time, the course it is for, as named in the list, or any; for a fixed event, any")),
        ], required: ["title", "use", "course"]), "One entry per calendar event, in the order given")),
    ], required: ["events"]))

    static let plan: String = render(.object([
        ("blocks", .array(.object([
            ("start", .string("Start time, 24-hour HH:mm")),
            ("end", .string("End time, 24-hour HH:mm")),
            ("title", .string("The obligation's title as given, or what the block is for; never an event's name")),
            ("reason", .string("One sentence: why this, why now")),
            ("kind", .enumeration(["work", "study", "meal", "rest"])),
        ], required: ["start", "end", "title", "reason", "kind"]), "Ordered blocks for the free gaps and the coursework time only, 25 to 90 minutes each; at most 14")),
    ], required: ["blocks"]))

    // MARK: An ordered schema, rendered as it is written

    indirect enum Node: Sendable {
        case object([(String, Node)], required: [String], description: String? = nil)
        case array(Node, String? = nil)
        case string(String?)
        case number(String?)
        case integer(String?)
        case enumeration([String])
    }

    static func render(_ node: Node) -> String {
        switch node {
        case .object(let properties, let required, let description):
            var fields = ["\"type\": \"object\""]
            if let description { fields.append("\"description\": \(quote(description))") }
            fields.append("\"properties\": {" + properties.map { "\(quote($0.0)): \(render($0.1))" }.joined(separator: ", ") + "}")
            fields.append("\"required\": [" + required.map(quote).joined(separator: ", ") + "]")
            fields.append("\"additionalProperties\": false")
            return "{" + fields.joined(separator: ", ") + "}"
        case .array(let items, let description):
            return "{\"type\": \"array\"" + (description.map { ", \"description\": \(quote($0))" } ?? "") + ", \"items\": \(render(items))}"
        case .string(let description): return leaf("string", description)
        case .number(let description): return leaf("number", description)
        case .integer(let description): return leaf("integer", description)
        case .enumeration(let values): return "{\"type\": \"string\", \"enum\": [" + values.map(quote).joined(separator: ", ") + "]}"
        }
    }

    private static func leaf(_ type: String, _ description: String?) -> String {
        "{\"type\": \"\(type)\"" + (description.map { ", \"description\": \(quote($0))" } ?? "") + "}"
    }

    static func quote(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), as: UTF8.self).dropFirst().dropLast().description
    }
}
