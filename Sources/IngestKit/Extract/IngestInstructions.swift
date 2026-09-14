import Foundation

/// The ingest prompt (SPEC §5). Static across a document; per-chunk context goes in the prompt, not here.
enum IngestInstructions {
    static let text = """
    You extract facts from university course documents: syllabi, schedules, assignment lists, and screenshots of course platforms. \
    Report only what the document states.

    Rules:
    1. Never invent a date. If an item's date is TBD, TBA, or missing, set dueDate to null and copy the wording into dateAsWritten.
    2. dateAsWritten holds only the date words copied exactly as printed; include a time only when it is printed next to that date. dueDate is that date as YYYY-MM-DD in the term's year.
    3. One obligation per graded or required item that has its own date or explicit TBD: homework, problem sets, quizzes, labs, projects, papers, presentations, midterms, finals. \
    A line or table row that names several items yields several obligations. Administrative deadlines with a date also count: opting out of a purchase, registering, dropping, or submitting a form by a date. \
    Not obligations: grade breakdown rows, and statements of frequency such as "weekly quizzes" or "due on Fridays". A lecture or lab topic is not an obligation, but a dated item printed beside it is: the schedule line "Week 3: Trig substitution. HW 3 due 9/23" yields HW 3. \
    Do not merge or expand a series: list each dated item as printed, every one of them.
    3a. title is the item's own short name as printed (for example HW 3, Lab 2 report, Midterm 1), never its week, its topic, or the grade breakdown row it belongs to.
    3b. When a row or line has several dates, the deadline is the one under a Due or Report due heading or after the word due. Released, assigned, posted, opens, and lab-session dates are not deadlines.
    4. platform is where the item is submitted or hosted: lms for Canvas, Brightspace, Blackboard, Moodle, NYU Classes; webassign; gradescope; mylab for MyLab, Mastering, Pearson; not_stated when the document does not say.
    5. component is the grade breakdown row the item counts toward, using that row's name.
    6. gradeComponents lists rows of a grade breakdown table that appears in this chunk, never rows you already know; weightPercent is the number before % on that row.
    7. policies quote the one sentence that states each rule, exactly as printed, for late work, makeup exams, attendance, drop rules (lowest scores dropped), and extra credit only; at most six.
    8. noClassDates lists holidays, breaks, and cancelled sessions.
    9. confidence is high when the item, its date, and its course are explicit; medium when read from a table or schedule; low when ambiguous.
    A chunk with no course content yields empty lists.
    """

    /// `pictures`: how many of the chunk's pages are attached as images (Claude), labelled "page N" by their number.
    static func prompt(chunk: String, chunkIndex: Int, chunkCount: Int, document: String, context: RollingContext, pictures: Int = 0) -> String {
        var lines = ["Document: \(document). Chunk \(chunkIndex + 1) of \(chunkCount)."]
        if let course = context.courseLine { lines.append("Course: \(course).") }
        if let term = context.termLine { lines.append("Term: \(term).") }
        if !context.componentLines.isEmpty { lines.append("Known grade components, do not re-list: \(context.componentLines.joined(separator: "; ")).") }
        if pictures > 0 {
            lines.append("The chunk's \(pictures == 1 ? "page is" : "\(pictures) pages are") attached as pictures, labelled by page number. The text layer below can garble a table or a column: where it does, read the table from the picture, and copy dates exactly as the picture prints them.")
        }
        lines.append("Extract every fact from this chunk:\n\n\(chunk)")
        if pictures > 0 { lines.append(Self.answerShape) }
        return lines.joined(separator: "\n")
    }

    /// Claude is told the answer's keys in their order. The API makes the model write properties in the schema's
    /// order; a model that skips optional keys and then wants one back out of order is forced into garbage and an empty
    /// result (one run in two on a one-page syllabus without this line, none with it).
    static let answerShape = "Answer with one JSON object in the required schema and nothing else, its keys in this order: course (code, title, instructor, term, termStart, termEnd, room, meetings), gradeComponents, obligations (one per dated item), policies, noClassDates. Empty lists where the chunk states nothing."

    /// `withOCRTool`: the device model may call the system's text tool on the picture; Claude reads it directly and transcribes it.
    static func imagePrompt(imageIndex: Int, imageCount: Int, document: String, context: RollingContext, withOCRTool: Bool) -> String {
        var lines = ["Document: \(document). Image \(imageIndex + 1) of \(imageCount), attached with label \"\(Extractor.imageLabel)\"." + (withOCRTool ? " Call getText on it if the text is dense or tabular." : "")]
        if let course = context.courseLine { lines.append("Course: \(course).") }
        if let term = context.termLine { lines.append("Term: \(term).") }
        lines.append("Extract every fact shown in the attached image, including the course code and title if a header shows them. In an assignment table the deadline is the Due column; Released and Late Due columns are not deadlines.")
        if !withOCRTool { lines.append("Answer with one JSON object in the required schema and nothing else: transcript first, then facts with its keys in this order: course (code, title, instructor, term, termStart, termEnd, room, meetings), gradeComponents, obligations (one per dated item), policies, noClassDates.") }
        return lines.joined(separator: "\n")
    }
}

/// What later chunks need to know from earlier ones. Deliberately tiny: the context window is small.
struct RollingContext: Sendable {
    var courseLine: String?
    var termLine: String?
    /// "Homework (webassign)" — name plus platform when known.
    var componentLines: [String] = []

    /// What the caller already knows about the course, before the first chunk.
    mutating func seed(_ known: KnownCourse) {
        let name = [known.code, known.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { courseLine = name }
        if let term = known.term { termLine = term }
        for c in known.components where !componentLines.contains(where: { $0.hasPrefix(c.name) }) {
            componentLines.append(c.platform.map { "\(c.name) (\($0.rawValue))" } ?? c.name)
        }
    }

    mutating func absorb(_ extraction: ChunkExtraction) {
        if courseLine == nil, let c = extraction.course, c.code != nil || c.title != nil {
            courseLine = [c.code, c.title].compactMap { $0 }.joined(separator: " ")
        }
        if termLine == nil, let c = extraction.course, let term = c.term {
            var line = term
            if let s = c.termStart, let e = c.termEnd { line += " (\(s) to \(e))" }
            termLine = line
        }
        for component in extraction.gradeComponents where !componentLines.contains(where: { $0.hasPrefix(component.name) }) {
            componentLines.append(component.platform == "not_stated" ? component.name : "\(component.name) (\(component.platform))")
        }
    }
}
