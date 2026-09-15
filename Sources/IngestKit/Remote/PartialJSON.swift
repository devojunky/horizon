import Foundation

/// What can be read from a JSON object that is still being written: every complete element of its top-level
/// arrays and every complete top-level value, in order. The streaming route shows items as they arrive and
/// salvages a reply cut by the output budget the same way the on-device route reads its partial snapshots.
enum PartialJSON {
    struct Snapshot: Equatable {
        /// Complete elements of each top-level array, as JSON text.
        var arrays: [String: [String]] = [:]
        /// Complete top-level values that are not arrays, as JSON text ("null" included).
        var values: [String: String] = [:]
        /// The key whose value was being written when the text ended; nil once the object has closed, or before its first key.
        var writing: String?
        /// The text of that value so far, when it is an object still open (nil for arrays: their elements are in `arrays`).
        var open: String?
    }

    static func snapshot(_ text: String) -> Snapshot {
        let chars = Array(text.utf8)
        var snapshot = Snapshot()
        guard let open = chars.firstIndex(of: UInt8(ascii: "{")) else { return snapshot }
        var i = open + 1
        func skipSpace() { while i < chars.count, isSpace(chars[i]) { i += 1 } }
        while true {
            skipSpace()
            guard i < chars.count, chars[i] == UInt8(ascii: "\"") else { return snapshot }
            guard let keyEnd = scanString(chars, from: i) else { return snapshot }
            let key = String(decoding: chars[(i + 1)..<(keyEnd - 1)], as: UTF8.self)
            snapshot.writing = key
            i = keyEnd
            skipSpace()
            guard i < chars.count, chars[i] == UInt8(ascii: ":") else { return snapshot }
            i += 1
            skipSpace()
            guard i < chars.count else { return snapshot }
            if chars[i] == UInt8(ascii: "[") {
                var elements: [String] = []
                i += 1
                while true {
                    skipSpace()
                    guard i < chars.count else { snapshot.arrays[key] = elements; return snapshot }
                    if chars[i] == UInt8(ascii: "]") { i += 1; break }
                    guard let end = scanValue(chars, from: i) else { snapshot.arrays[key] = elements; return snapshot }
                    elements.append(String(decoding: chars[i..<end], as: UTF8.self))
                    i = end
                    skipSpace()
                    if i < chars.count, chars[i] == UInt8(ascii: ",") { i += 1 }
                }
                snapshot.arrays[key] = elements
            } else {
                guard let end = scanValue(chars, from: i) else { snapshot.open = String(decoding: chars[i...], as: UTF8.self); return snapshot }
                snapshot.values[key] = String(decoding: chars[i..<end], as: UTF8.self)
                i = end
            }
            skipSpace()
            guard i < chars.count else { return snapshot }
            if chars[i] == UInt8(ascii: ",") { i += 1; continue }
            if chars[i] == UInt8(ascii: "}") { snapshot.writing = nil }   // the object closed: nothing is being written
            return snapshot
        }
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

    /// The index just past a complete JSON value starting at `start`, or nil when the text ends first.
    static func scanValue(_ chars: [UInt8], from start: Int) -> Int? {
        guard start < chars.count else { return nil }
        switch chars[start] {
        case UInt8(ascii: "\""): return scanString(chars, from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0, i = start
            while i < chars.count {
                let c = chars[i]
                if c == UInt8(ascii: "\"") {
                    guard let end = scanString(chars, from: i) else { return nil }
                    i = end; continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return nil
        default:
            // A number or a literal: complete once a delimiter follows it.
            var i = start
            while i < chars.count, !isSpace(chars[i]), chars[i] != UInt8(ascii: ","), chars[i] != UInt8(ascii: "}"), chars[i] != UInt8(ascii: "]") { i += 1 }
            return i < chars.count ? i : nil
        }
    }

    /// The index just past the closing quote of the string starting at `start`, or nil when it is unterminated.
    static func scanString(_ chars: [UInt8], from start: Int) -> Int? {
        var i = start + 1
        while i < chars.count {
            if chars[i] == UInt8(ascii: "\\") { i += 2; continue }
            if chars[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    static func parse(_ json: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) }
}

/// The model's JSON, from either route's text, as the facts the merger reads. Null and absent are the same thing.
enum ExtractionJSON {
    /// A whole reply. Throws when it is not the object the schema describes.
    static func decode(_ text: String) throws -> ChunkExtraction {
        guard let object = PartialJSON.parse(text) as? [String: Any] else { throw ClaudeError.malformed("the reply is not a JSON object") }
        return extraction(from: object)
    }

    /// What is complete in a reply cut short: the finished elements of every list, and the course if it was finished.
    static func salvage(_ text: String) -> ChunkExtraction? {
        let snapshot = PartialJSON.snapshot(text)
        var object: [String: Any] = [:]
        if let course = snapshot.values["course"], let value = PartialJSON.parse(course) { object["course"] = value }
        for (key, elements) in snapshot.arrays { object[key] = elements.compactMap { PartialJSON.parse($0) } }
        let result = extraction(from: object)
        guard result.course != nil || !result.obligations.isEmpty || !result.gradeComponents.isEmpty || !result.policies.isEmpty else { return nil }
        return result
    }

    /// The rows the UI can show while the reply streams: the outline's names first, as placeholders with no date, each
    /// replaced by the item once it is written (the same id, so the row carries over).
    static func provisional(_ text: String, call: Int) -> [ProvisionalObligation] {
        let snapshot = PartialJSON.snapshot(text)
        var rows = snapshot.arrays["obligations", default: []].enumerated().compactMap { index, element -> ProvisionalObligation? in
            guard let item = PartialJSON.parse(element) as? [String: Any], let title = item["title"] as? String, !title.isEmpty else { return nil }
            return ProvisionalObligation(id: "\(call)-\(index)", title: title, dateAsWritten: item["dateAsWritten"] as? String, component: item["component"] as? String)
        }
        if let outline = outline(snapshot), outline.titles.count > rows.count {
            let from = rows.count
            rows += outline.titles[from...].enumerated().map { offset, title in ProvisionalObligation(id: "\(call)-\(from + offset)", title: title) }
        }
        return rows
    }

    /// The outline, once it has arrived whole.
    static func outline(_ snapshot: PartialJSON.Snapshot) -> ReadProgress.Outline? {
        guard let text = snapshot.values["outline"], let object = PartialJSON.parse(text) as? [String: Any] else { return nil }
        let titles = (object["obligationTitles"] as? [Any] ?? []).compactMap { $0 as? String }
        return ReadProgress.Outline(titles: titles, gradeRows: integer(object["gradeRows"]) ?? 0, policies: integer(object["policies"]) ?? 0, breaks: integer(object["breaks"]) ?? 0)
    }

    /// Where the reply stands: the key being written names the stage, the finished elements the count, the outline the total.
    static func progress(_ text: String) -> ReadProgress { progress(PartialJSON.snapshot(text)) }

    /// The names the outline has listed so far while it is still being written: the strings inside its titles array.
    static func namesSoFar(_ snapshot: PartialJSON.Snapshot) -> Int {
        guard let open = snapshot.open, let start = open.range(of: "\"obligationTitles\"") else { return 0 }
        let rest = open[start.upperBound...]
        guard let bracket = rest.firstIndex(of: "["), let closeAt = rest.firstIndex(of: "]") ?? Optional(rest.endIndex) else { return 0 }
        let inside = rest[rest.index(after: bracket)..<closeAt]
        return inside.matches(of: /"(?:[^"\\]|\\.)*"/).count
    }

    static func progress(_ snapshot: PartialJSON.Snapshot) -> ReadProgress {
        let outline = outline(snapshot)
        func count(_ key: String) -> Int { snapshot.arrays[key]?.count ?? 0 }
        switch snapshot.writing {
        case "outline"?: return ReadProgress(stage: .sizing, done: outline?.titles.count ?? namesSoFar(snapshot), outline: outline)
        case "course"?: return ReadProgress(stage: .course, outline: outline)
        case "gradeComponents"?: return ReadProgress(stage: .grading, done: count("gradeComponents"), total: outline?.gradeRows, outline: outline)
        case "obligations"?:
            let done = count("obligations")
            return ReadProgress(stage: .obligations, done: done, total: outline.map { max($0.titles.count, done) },
                                current: outline.flatMap { done < $0.titles.count ? $0.titles[done] : nil }, outline: outline)
        case "policies"?: return ReadProgress(stage: .policies, done: count("policies"), total: outline?.policies, outline: outline)
        case "noClassDates"?: return ReadProgress(stage: .breaks, done: count("noClassDates"), total: outline?.breaks, outline: outline)
        case nil where snapshot.values.isEmpty && snapshot.arrays.isEmpty: return ReadProgress(stage: .sizing)
        default:   // closed, or a key the schema does not name: every list is done
            return ReadProgress(stage: .breaks, done: count("noClassDates"), total: outline.map { max($0.breaks, count("noClassDates")) }, outline: outline)
        }
    }

    static func extraction(from object: [String: Any]) -> ChunkExtraction {
        let course = (object["course"] as? [String: Any]).map { c in
            CourseFacts(code: c["code"] as? String, title: c["title"] as? String, instructor: c["instructor"] as? String, term: c["term"] as? String,
                        termStart: c["termStart"] as? String, termEnd: c["termEnd"] as? String, room: c["room"] as? String,
                        meetings: (c["meetings"] as? [[String: Any]] ?? []).compactMap { m in
                            (m["weekday"] as? String).map { MeetingFacts(weekday: $0, start: m["start"] as? String, end: m["end"] as? String) }
                        })
        }
        let components = (object["gradeComponents"] as? [[String: Any]] ?? []).compactMap { c -> GradeComponentFacts? in
            guard let name = c["name"] as? String else { return nil }
            return GradeComponentFacts(name: name, weightPercent: number(c["weightPercent"]), count: integer(c["count"]),
                                       cadence: c["cadence"] as? String ?? "other", dropLowest: integer(c["dropLowest"]), platform: c["platform"] as? String ?? "not_stated")
        }
        let obligations = (object["obligations"] as? [[String: Any]] ?? []).compactMap { o -> ObligationFacts? in
            guard let title = o["title"] as? String else { return nil }
            return ObligationFacts(title: title, platform: o["platform"] as? String ?? "not_stated", component: o["component"] as? String,
                                   dateAsWritten: o["dateAsWritten"] as? String ?? "", dueDate: o["dueDate"] as? String, confidence: o["confidence"] as? String ?? "medium")
        }
        let policies = (object["policies"] as? [[String: Any]] ?? []).compactMap { p -> PolicyFacts? in
            guard let text = p["text"] as? String else { return nil }
            return PolicyFacts(kind: p["kind"] as? String ?? "other", text: text)
        }
        let noClass = (object["noClassDates"] as? [[String: Any]] ?? []).compactMap { n -> NoClassFacts? in
            guard let written = n["dateAsWritten"] as? String else { return nil }
            return NoClassFacts(dateAsWritten: written, startDate: n["startDate"] as? String, endDate: n["endDate"] as? String)
        }
        return ChunkExtraction(course: course, gradeComponents: components, obligations: obligations, policies: policies, noClassDates: noClass)
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
    static func integer(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d == d.rounded() { return Int(d) }
        return nil
    }
}

/// The plan's JSON as the draft the planner validates.
/// What Claude returns for a picture: the page transcribed, then the facts (`PageReading`'s JSON). The facts are a
/// nested object, so the partial-reply helpers run on the text after its key.
enum PageReadingJSON {
    static func decode(_ text: String) throws -> (transcript: String, facts: ChunkExtraction) {
        guard let object = PartialJSON.parse(text) as? [String: Any] else { throw ClaudeError.malformed("the reply is not a JSON object") }
        return (object["transcript"] as? String ?? "", ExtractionJSON.extraction(from: object["facts"] as? [String: Any] ?? [:]))
    }
    /// Complete items of a reply cut short: the transcript if it closed, and whatever facts have closed.
    static func salvage(_ text: String) -> (transcript: String, facts: ChunkExtraction)? {
        guard let facts = ExtractionJSON.salvage(factsText(text)) else { return nil }
        let transcript = PartialJSON.snapshot(text).values["transcript"].flatMap { PartialJSON.parse($0) as? String } ?? ""
        return (transcript, facts)
    }
    static func provisional(_ text: String, call: Int) -> [ProvisionalObligation] { ExtractionJSON.provisional(factsText(text), call: call) }

    /// Where the reply stands: the transcript first, then the facts' own stages.
    static func progress(_ text: String) -> ReadProgress {
        let facts = factsText(text)
        return facts.isEmpty ? ReadProgress(stage: .transcribing) : ExtractionJSON.progress(facts)
    }

    /// The facts object as written so far: everything after its key.
    static func factsText(_ text: String) -> String {
        guard let key = text.range(of: "\"facts\""), let brace = text[key.upperBound...].firstIndex(of: "{") else { return "" }
        return String(text[brace...])
    }
}

enum PlanJSON {
    static func decode(_ text: String) throws -> PlanDraft {
        guard let object = PartialJSON.parse(text) as? [String: Any] else { throw ClaudeError.malformed("the plan is not a JSON object") }
        return PlanDraft(blocks: (object["blocks"] as? [[String: Any]] ?? []).compactMap(block))
    }

    /// The blocks complete in a reply still being written.
    static func provisional(_ text: String) -> PlanDraft {
        PlanDraft(blocks: PartialJSON.snapshot(text).arrays["blocks", default: []].compactMap { PartialJSON.parse($0) as? [String: Any] }.compactMap(block))
    }

    private static func block(_ b: [String: Any]) -> PlanDraftBlock? {
        guard let start = b["start"] as? String, let end = b["end"] as? String, let title = b["title"] as? String else { return nil }
        return PlanDraftBlock(start: start, end: end, title: title, reason: b["reason"] as? String ?? "", kind: b["kind"] as? String ?? "work")
    }
}
