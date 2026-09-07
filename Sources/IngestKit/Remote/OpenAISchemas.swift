import Foundation

/// OpenAI's strict JSON Schemas for the two structures the models fill, written by hand to mirror the `@Generable`
/// types field for field (names, enumerations, and the same descriptions), so one decoder serves both routes.
/// Strict mode wants every property required and `additionalProperties: false` on every object; an optional field
/// is a nullable type. Counts and ranges are not allowed as keywords there, so they live in the descriptions.
enum OpenAISchemas {
    static let extraction: String = json(object([
        ("course", nullable(object([
            ("code", nullableString("Course code as printed")),
            ("title", nullableString(nil)),
            ("instructor", nullableString(nil)),
            ("term", nullableString("Term as printed, with its year")),
            ("termStart", nullableString("First class day, YYYY-MM-DD")),
            ("termEnd", nullableString("Last class day, YYYY-MM-DD")),
            ("room", nullableString(nil)),
            ("meetings", array(object([
                ("weekday", enumeration(["mon", "tue", "wed", "thu", "fri", "sat", "sun"])),
                ("start", nullableString("HH:mm")),
                ("end", nullableString("HH:mm")),
            ]), "At most 7")),
        ]))),
        ("gradeComponents", array(object([
            ("name", string("Row name as printed")),
            ("weightPercent", nullableNumber("Percent of final grade, 0 to 100")),
            ("count", nullableInteger("Number of items, if stated")),
            ("cadence", enumeration(["weekly", "biweekly", "once", "other"])),
            ("dropLowest", nullableInteger("Lowest scores dropped, if stated")),
            ("platform", enumeration(["lms", "webassign", "gradescope", "mylab", "not_stated"])),
        ]), "Rows of a grade breakdown table present in this chunk; at most 12")),
        ("obligations", array(object([
            ("title", string("The item's own name as printed")),
            ("platform", enumeration(["lms", "webassign", "gradescope", "mylab", "not_stated"])),
            ("component", nullableString("Grade breakdown row name")),
            ("dateAsWritten", string("Only the date words for this item, copied exactly as printed, including a time if printed next to them, or the TBD wording")),
            ("dueDate", nullableString("YYYY-MM-DD, or null if no date")),
            ("confidence", enumeration(["high", "medium", "low"])),
        ]), "Graded or required items in this chunk that have a specific date or an explicit TBD; at most 24")),
        ("policies", array(object([
            ("kind", enumeration(["late_work", "makeup_exam", "attendance", "drop_rule", "extra_credit", "other"])),
            ("text", string("Exact wording")),
        ]), "Policies, one sentence each, quoted word for word; at most 6")),
        ("noClassDates", array(object([
            ("dateAsWritten", string("Date words copied exactly")),
            ("startDate", nullableString("YYYY-MM-DD")),
            ("endDate", nullableString("YYYY-MM-DD, same as startDate for one day")),
        ]), "Holidays, breaks, cancelled sessions; at most 8")),
    ], description: "Facts stated in one chunk of a course document. Null or empty for anything not stated in the chunk."))

    static let plan: String = json(object([
        ("blocks", array(object([
            ("start", string("Start time, 24-hour HH:mm")),
            ("end", string("End time, 24-hour HH:mm")),
            ("title", string("The obligation's title as given, or what the block is for")),
            ("reason", string("One sentence: why this, why now")),
            ("kind", enumeration(["work", "meal", "rest"])),
        ]), "Ordered blocks for the free gaps only, 25 to 90 minutes each; at most 10")),
    ]))

    // MARK: Builders

    typealias Schema = [String: Any]

    static func object(_ properties: [(String, Schema)], description: String? = nil) -> Schema {
        var schema: Schema = ["type": "object", "additionalProperties": false,
                              "properties": Dictionary(uniqueKeysWithValues: properties), "required": properties.map(\.0)]
        if let description { schema["description"] = description }
        return schema
    }
    static func array(_ items: Schema, _ description: String? = nil) -> Schema {
        var schema: Schema = ["type": "array", "items": items]
        if let description { schema["description"] = description }
        return schema
    }
    static func string(_ description: String?) -> Schema { described(["type": "string"], description) }
    static func nullableString(_ description: String?) -> Schema { described(["type": ["string", "null"]], description) }
    static func nullableNumber(_ description: String?) -> Schema { described(["type": ["number", "null"]], description) }
    static func nullableInteger(_ description: String?) -> Schema { described(["type": ["integer", "null"]], description) }
    static func enumeration(_ values: [String]) -> Schema { ["type": "string", "enum": values] }
    static func nullable(_ schema: Schema) -> Schema {
        // A nullable object: OpenAI's strict form accepts a type list on the object itself.
        var s = schema
        s["type"] = ["object", "null"]
        return s
    }
    private static func described(_ schema: Schema, _ description: String?) -> Schema {
        var s = schema
        if let description { s["description"] = description }
        return s
    }
    static func json(_ schema: Schema) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    }
}
