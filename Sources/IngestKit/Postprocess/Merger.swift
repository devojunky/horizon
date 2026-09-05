import Foundation

/// Folds per-chunk extractions into one IngestResult: course facts, deduped components and
/// obligations, resolved dates, confidence, status, and points at stake. Deterministic guards live here.
enum Merger {
    static func merge(outcomes: [ExtractionOutcome], document: NormalizedDocument, route: ModelRoute,
                      options: IngestOptions, warnings: [String]) -> IngestResult {
        var warnings = warnings
        let extractions = outcomes.map(\.extraction)
        let source = Source(text: document.fullText)

        // Course: first stated value per field wins; meetings are unioned.
        var course: ParsedCourse?
        for facts in extractions.compactMap(\.course) {
            var c = course ?? ParsedCourse(meetings: [])
            c.code = c.code ?? facts.code
            c.title = c.title ?? facts.title
            c.instructor = c.instructor ?? facts.instructor
            c.term = c.term ?? facts.term
            c.room = c.room ?? facts.room
            for m in facts.meetings {
                let slot = MeetingSlot(weekday: weekdayNumber(m.weekday), start: m.start, end: m.end)
                if !c.meetings.contains(slot) { c.meetings.append(slot) }
            }
            course = c
        }
        let year = DateResolver.year(inTerm: course?.term, fallback: options.defaultYear ?? options.calendar.component(.year, from: Date()))
        var resolver = DateResolver(calendar: options.calendar, defaultYear: year)
        let termFacts = extractions.compactMap(\.course)
        course?.termStart = options.termStart ?? termFacts.lazy.compactMap { resolver.resolveDay(iso: $0.termStart, asWritten: "") }.first
        course?.termEnd = termFacts.lazy.compactMap { resolver.resolveDay(iso: $0.termEnd, asWritten: "") }.first
        resolver.termStart = course?.termStart ?? options.termStart
        resolver.termEnd = course?.termEnd

        // Grade components: dedupe by name; recover a missing weight from the source line; ignore rows once weights total 100%.
        var components: [ParsedGradeComponent] = []
        var componentPlatforms: [String: Platform] = [:]
        for facts in extractions.flatMap(\.gradeComponents) {
            let key = Normalize.key(facts.name)
            guard !key.isEmpty else { continue }
            let weight = (source.percentage(onLineMentioning: facts.name) ?? facts.weightPercent).map { $0 / 100 }   // the row's own figure first
            if let i = components.firstIndex(where: { Normalize.key($0.name) == key }) {
                if components[i].weight == nil { components[i].weight = weight }
                if components[i].expectedCount == nil { components[i].expectedCount = facts.count }
                if components[i].cadence == nil { components[i].cadence = Cadence(rawValue: facts.cadence) }
                if components[i].dropLowest == nil { components[i].dropLowest = facts.dropLowest }
                if let w = weight, let existing = components[i].weight, abs(existing - w) > 0.001 {
                    warnings.append("Component '\(facts.name)' has two weights: \(Int(existing * 100))% and \(Int(w * 100))%; kept the first")
                }
            } else {
                let total = components.compactMap(\.weight).reduce(0, +)
                if total >= 0.99 { warnings.append("Ignored component '\(facts.name)': weights already total 100%"); continue }
                components.append(ParsedGradeComponent(name: facts.name, weight: weight, expectedCount: facts.count,
                                                       cadence: Cadence(rawValue: facts.cadence), dropLowest: facts.dropLowest))
            }
            if facts.platform != "not_stated", componentPlatforms[key] == nil, !source.hasText { componentPlatforms[key] = platform(facts.platform) }
        }
        // Rows of the grade table the model skipped, read straight from the document.
        if components.compactMap(\.weight).reduce(0, +) < 0.99 {
            for row in source.gradeRows() {
                if let i = components.firstIndex(where: { Normalize.similarity($0.name, row.name) >= 0.5 || Normalize.key($0.name).contains(Normalize.key(row.name)) }) {
                    if components[i].weight == nil { components[i].weight = row.weight / 100 }
                } else {
                    components.append(ParsedGradeComponent(name: row.name, weight: row.weight / 100))
                    warnings.append("Component '\(row.name)' read from the grade table; the model skipped it")
                }
            }
        }
        for c in components {   // the grading row's own wording is the authority on where a component is submitted
            if let p = source.platform(onLineMentioning: c.name) { componentPlatforms[Normalize.key(c.name)] = p }
        }
        let componentKeys = Set(components.map { Normalize.key($0.name) })

        // Obligations.
        var obligations: [ParsedObligation] = []
        var merged = 0, dropped = 0
        for outcome in outcomes {
            // Text chunks are checked strictly against the document text. Image pages are checked against Vision OCR
            // text, which can misread a date, so failures there downgrade to review instead of dropping.
            let strict = outcome.kind == .text && source.hasText
            for facts in outcome.extraction.obligations {
                let title = Normalize.collapseWhitespace(facts.title)
                guard !title.isEmpty else { continue }
                let resolution = resolver.resolve(iso: facts.dueDate, asWritten: facts.dateAsWritten)
                var flags = resolution.flags
                let tbd = resolution.date == nil && (DateResolver.isTBD(facts.dateAsWritten) || facts.dueDate == nil)
                // The wording is supported when the document contains it, or every date it names, or (for TBD) any TBD wording.
                let spans = resolver.explicitSpans(in: facts.dateAsWritten)
                let writtenInSource = source.contains(facts.dateAsWritten)
                    || (!spans.isEmpty && spans.allSatisfy { source.contains($0.text) })
                    || (tbd && DateResolver.isTBD(facts.dateAsWritten) && source.mentionsTBD)
                let dateInSource = resolution.date.map { d in resolver.mentions(d).contains(where: source.contains) } ?? false
                var confidence: Double = switch facts.confidence { case "high": 0.85; case "medium": 0.65; default: 0.4 }
                if facts.confidence == "low" { flags.append(.modelLowConfidence) }

                if source.hasText {
                    if resolution.date != nil {
                        if writtenInSource { confidence += 0.1 }
                        else if dateInSource { confidence += 0.05 }
                        else if strict { dropped += 1; continue }            // nothing in the document supports this date
                        else { flags.append(.dateNotInSource); confidence -= 0.3 }
                        if !resolution.resolvedFromText, !dateInSource {         // the model computed a date the document never states
                            flags.append(.dateNotInSource); confidence = min(confidence, options.reviewThreshold - 0.05)
                        }
                    } else if strict {
                        // A dateless item must be a supported TBD, and not merely a grade-table row restated.
                        let namesComponent = componentKeys.contains(Normalize.key(title)) && !DateResolver.isTBD(facts.dateAsWritten)
                        if !writtenInSource || !tbd || namesComponent { dropped += 1; continue }
                    } else if !tbd {
                        dropped += 1; continue
                    }
                }
                let componentName = matchComponent(facts.component, in: components) ?? inferComponent(fromTitle: title, in: components)
                if let requested = facts.component, !requested.isEmpty {
                    if componentName != nil { confidence += 0.05 } else { flags.append(.unknownComponent) }
                }
                // The item's own row lists several dates and the chosen one is the first: a session, release, or
                // week date rather than the deadline. Never ship that without review.
                if let date = resolution.date {
                    let item = options.calendar.dateComponents([.month, .day], from: date)
                    func same(_ c: DateComponents) -> Bool { c.month == item.month && c.day == item.day }
                    var ambiguous = false
                    var rowFound = false
                    if let row = source.segment(mentioning: title) ?? source.line(mentioning: title, on: resolver.mentions(date)) {
                        rowFound = true
                        let rowSpans = Source.cells(of: row).flatMap { resolver.explicitSpans(in: $0) }   // per cell: "HW 1   Sep 4" is not "1 Sep"
                        let days = Set(rowSpans.flatMap { [$0.start, $0.end] }.map { "\($0.month ?? 0)-\($0.day ?? 0)" })
                        let firstOfSeveral = days.count >= 2 && rowSpans.first.map { same($0.start) } == true && rowSpans.last.map { !same($0.end) } == true
                        let noneOnRow = !rowSpans.isEmpty && !rowSpans.contains { same($0.start) || same($0.end) }   // the item's own row names other dates
                        let topicLine = row.range(of: #"(?i)^\s*week\s*\d+"#, options: .regularExpression) != nil && !row.localizedCaseInsensitiveContains("due")
                        ambiguous = firstOfSeveral || noneOnRow || topicLine
                    }
                    // A screenshot with a Released/Opens column whose row OCR could not reassemble: the wrong column is easy to pick.
                    if outcome.kind == .image, !rowFound, source.hasReleaseColumn { ambiguous = true }
                    if ambiguous { flags.append(.dateAmbiguous); confidence = min(confidence, options.reviewThreshold - 0.05) }
                }
                // A model/wording disagreement is ignored when it is a year slip or the model's date appears nowhere in the
                // document and the wording names one corroborated date; otherwise it means review.
                if flags.contains(.dateDisagreement) {
                    let model = facts.dueDate.flatMap { resolver.ymd(iso: $0) }
                    let item = resolution.date.map { options.calendar.dateComponents([.month, .day], from: $0) }
                    let yearSlip = model != nil && item != nil && model?.month == item?.month && model?.day == item?.day
                    let modelMentions = model.flatMap { options.calendar.date(from: $0) }.map(resolver.mentions) ?? []
                    let modelOnRow: Bool = if let row = source.segment(mentioning: title) {
                        modelMentions.contains { (" " + Source.normalize(row) + " ").contains(" \($0) ") }
                    } else {
                        modelMentions.contains(where: source.contains)
                    }
                    if !yearSlip, modelOnRow || !(writtenInSource && spans.count == 1) { confidence -= 0.3 }
                }
                if flags.contains(.dateOutsideTerm) { confidence -= 0.15 }
                // No wording to check, or an image Vision could not read: the model is on its own, so review.
                if facts.dateAsWritten.trimmingCharacters(in: .whitespaces).isEmpty || (outcome.kind == .image && !source.hasText) {
                    if !flags.contains(.dateNotInSource) { flags.append(.dateNotInSource) }
                    confidence = min(confidence, options.reviewThreshold - 0.05)
                }
                confidence = min(1, max(0, confidence))
                // Platform: the item's own row, then its grading row. A screenshot may add the one platform the page
                // names, then the model's reading of the picture; for text the model's guess is not evidence ("lms" is its default).
                let platform = source.platform(onLineMentioning: title)
                    ?? componentName.flatMap { componentPlatforms[Normalize.key($0)] }
                    ?? (outcome.kind == .image ? (source.uniquePlatform ?? platform(facts.platform)) : (source.hasText ? .syllabusOnly : platform(facts.platform)))
                let status: ObligationStatus = resolution.date == nil ? (tbd ? .awaitingDate : .needsReview)
                    : (confidence < options.reviewThreshold ? .needsReview : .ready)
                let item = ParsedObligation(id: UUID(), title: title, platform: platform,
                                            componentName: componentName ?? facts.component.flatMap { $0.isEmpty ? nil : $0 },
                                            dateAsWritten: facts.dateAsWritten, due: resolution.date, dueHasTime: resolution.hasTime,
                                            status: status, confidence: confidence, flags: flags, pointsAtStake: nil, sourcePage: outcome.page)
                if let i = obligations.firstIndex(where: { isDuplicate($0, item, calendar: options.calendar) }) {
                    merged += 1
                    if item.confidence > obligations[i].confidence { obligations[i] = item }
                } else {
                    obligations.append(item)
                }
            }
        }
        // A dated item supersedes a dateless one with the same title.
        let datedKeys = Set(obligations.filter { $0.due != nil }.map { Normalize.key($0.title) })
        let before = obligations.count
        obligations.removeAll { $0.due == nil && datedKeys.contains(Normalize.key($0.title)) }
        let superseded = before - obligations.count
        // The same title on exactly two different days is a conflict, not a series: emit both, flag both, review the weaker.
        for key in Set(obligations.map { Normalize.key($0.title) }) {
            let indices = obligations.indices.filter { Normalize.key(obligations[$0].title) == key && obligations[$0].due != nil }
            guard indices.count == 2 else { continue }
            for i in indices { obligations[i].flags.append(.conflictingDate) }
            let weaker = indices.min { obligations[$0].confidence < obligations[$1].confidence }!
            obligations[weaker].status = .needsReview
        }
        if merged > 0 { warnings.append("\(merged) duplicate obligation(s) merged across chunks") }
        if superseded > 0 { warnings.append("\(superseded) undated obligation(s) superseded by a dated copy") }
        if dropped > 0 { warnings.append("\(dropped) obligation(s) dropped as unsupported by the document text") }

        // Points at stake: component weight ÷ expected item count (stated count, else cadence-implied, else items on file).
        for (i, ob) in obligations.enumerated() {
            guard let name = ob.componentName, let component = components.first(where: { Normalize.key($0.name) == Normalize.key(name) }),
                  let weight = component.weight else { continue }
            let onFile = obligations.filter { $0.componentName.map(Normalize.key) == Normalize.key(name) }.count
            let expected = component.expectedCount ?? impliedCount(component.cadence, termStart: resolver.termStart, termEnd: resolver.termEnd) ?? onFile
            guard expected > 0 else { continue }
            obligations[i].pointsAtStake = (weight * 100 / Double(expected) * 100).rounded() / 100
        }

        // Policies: exact wording only. A paraphrase is replaced by the best-matching source sentences or marked non-verbatim.
        var policies: [ParsedPolicy] = []
        for facts in extractions.flatMap(\.policies) where !Normalize.key(facts.text).isEmpty {
            let (text, verbatim) = source.verbatim(facts.text)
            let key = Normalize.key(text)
            if !policies.contains(where: { Normalize.key($0.text) == key }) {
                policies.append(ParsedPolicy(kind: policyKind(facts.kind), text: text, verbatim: verbatim))
            }
        }

        // No-class dates: the wording must appear in the source.
        var noClass: [ParsedNoClass] = []
        for facts in extractions.flatMap(\.noClassDates) where !source.hasText || source.contains(facts.dateAsWritten) {
            let range = resolver.dayRange(in: facts.dateAsWritten)
            let start = range?.first ?? resolver.resolveDay(iso: facts.startDate, asWritten: "")
            let end = range?.last ?? resolver.resolveDay(iso: facts.endDate, asWritten: "") ?? start
            guard let start else { continue }
            if !noClass.contains(where: { $0.start == start && $0.end == end }) {
                noClass.append(ParsedNoClass(dateAsWritten: facts.dateAsWritten, start: start, end: end))
            }
        }

        obligations.sort { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
        return IngestResult(document: document.info, route: route, course: course, gradeComponents: components,
                            obligations: obligations, policies: policies, noClassDates: noClass,
                            usage: UsageReport(calls: outcomes.map(\.usage)), warnings: warnings)
    }

    /// The document text prepared for "does the document say this" checks.
    struct Source {
        let key: String
        let lines: [String]
        let sentences: [String]
        var hasText: Bool { !key.isEmpty }

        init(text: String) {
            key = Source.normalize(text)
            lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            sentences = text.replacingOccurrences(of: "\n", with: " ").components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 8 }
        }

        static func normalize(_ s: String) -> String {
            Normalize.key(s.replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression))
        }

        func contains(_ s: String) -> Bool {
            let k = Source.normalize(s)
            return !k.isEmpty && key.contains(k)
        }

        var mentionsTBD: Bool { DateResolver.isTBD(" " + key + " ") }

        /// The first percentage following `name` on the same line, e.g. "Homework (WebAssign) ...... 15%".
        func percentage(onLineMentioning name: String) -> Double? {
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { return nil }
            let pattern = #"(?i)\b"# + words.joined(separator: #"\W+"#) + #"\b[^%\n]{0,80}?(\d{1,3}(?:\.\d+)?)\s*%"#
            for line in lines where !Source.isPenaltyLine(line) {
                guard let match = line.firstMatch(of: try! Regex(pattern)), let text = match.output[1].substring, let value = Double(text), value <= 100 else { continue }
                return value
            }
            return nil
        }

        static func isPenaltyLine(_ line: String) -> Bool {
            line.range(of: #"(?i)\b(late|penalty|per day|lose|loses|lower|lowers|deduct|deducted|extra|bonus|credit|curve|curved|off|each|up to)\b"#, options: .regularExpression) != nil
        }

        static let platformKeywords: [(String, Platform)] = [
            ("webassign", .webAssign), ("gradescope", .gradescope), ("mylab", .myLab), ("mastering", .myLab), ("pearson", .myLab),
            ("brightspace", .lms), ("canvas", .lms), ("blackboard", .lms), ("moodle", .lms), ("nyu classes", .lms),
        ]

        /// The platform named in the first sentence (or table row) that mentions `phrase` as whole words,
        /// e.g. "Project 1 … Brightspace". Sentences are split so a neighbour's platform does not leak.
        func platform(onLineMentioning phrase: String) -> Platform? {
            let needle = " " + Normalize.key(phrase) + " "
            guard needle.count > 2 else { return nil }
            for line in lines {
                for segment in line.split(separator: Source.segmentSeparator).map(String.init) {
                    let k = " " + Normalize.key(segment) + " "
                    guard k.contains(needle) else { continue }
                    if let hit = Source.platformKeywords.first(where: { k.contains($0.0) }) { return hit.1 }
                }
            }
            return nil
        }
        private static var segmentSeparator: Regex<Substring> { try! Regex(#"(?:\.\s+|;\s*|\|)"#) }

        /// The sentence or table row that names `phrase` ("Lab 2 report", else its head and number "Lab 2") and carries a
        /// date. A grading-table row or a wrapped fragment that names the item without a date is skipped in favour of a
        /// later dated line; the whole line is used when the sentence itself has no date.
        func segment(mentioning phrase: String) -> String? {
            let key = Normalize.key(phrase)
            var needles = [" " + key + " "]
            let words = key.split(separator: " ")
            if words.count > 2, let number = words.dropFirst().first(where: { $0.allSatisfy(\.isNumber) }) { needles.append(" \(words[0]) \(number) ") }
            for needle in needles where needle.count > 2 {
                for (i, raw) in lines.enumerated() where (" " + Normalize.key(raw) + " ").contains(needle) {
                    // PDF text wraps long rows; a following line that is only a date belongs to this row.
                    var line = raw
                    if i + 1 < lines.count, Source.isDateFragment(lines[i + 1]) { line += " " + lines[i + 1].trimmingCharacters(in: .whitespaces) }
                    let sentences = line.split(separator: Source.segmentSeparator).map(String.init)
                    if let sentence = sentences.first(where: { (" " + Normalize.key($0) + " ").contains(needle) && Source.hasDate($0) }) { return sentence }
                    if Source.hasDate(line) { return line }
                }
            }
            return nil
        }

        /// A wrapped line holding nothing but a date, e.g. "Oct 30", "Fri Oct 30, 11:59 PM", "9/16.".
        static func isDateFragment(_ line: String) -> Bool {
            line.range(of: #"(?i)^\s*(?:(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\.?,?\s*)?(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}/\d{1,2})(?:,?\s*\d{4})?(?:,?\s*(?:at\s*)?\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?)?[.;]?\s*$"#, options: .regularExpression) != nil
        }

        /// A month-and-day or numeric M/D somewhere in the text.
        static func hasDate(_ text: String) -> Bool {
            text.range(of: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b|\b\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b|\b\d{1,2}/\d{1,2}\b"#, options: .regularExpression) != nil
        }

        /// A line that names the item's head word together with one of the given date forms — for titles the model
        /// invented from a topic line ("Project report" for "… project work" on "Week 13 (Apr 27, 29): …").
        func line(mentioning phrase: String, on dateForms: [String]) -> String? {
            guard let head = Normalize.key(phrase).split(separator: " ").first, head.count >= 4 else { return nil }
            return lines.first { line in
                let k = " " + Normalize.key(line) + " "
                return k.contains(" \(head) ") && dateForms.contains { k.contains(" \($0) ") }
            }
        }

        /// True when the document has a "Released", "Opens", "Posted", or "Available" column heading.
        var hasReleaseColumn: Bool {
            key.range(of: #"\b(released|release date|opens|opened|posted|available from)\b"#, options: .regularExpression) != nil
        }

        /// Table cells of a row: runs of two or more spaces or tabs separate columns. Prose comes back as one cell.
        static func cells(of row: String) -> [String] {
            row.split(separator: try! Regex(#"\s{2,}|\t"#)).map(String.init).filter { !$0.isEmpty }
        }

        /// The only platform the document names, if it names exactly one.
        var uniquePlatform: Platform? {
            let named = Set(Source.platformKeywords.filter { key.contains($0.0) }.map(\.1))
            return named.count == 1 ? named.first : nil
        }

        struct GradeRow { var name: String; var weight: Double }
        private static var rowPattern: Regex<(Substring, Substring, Substring)> { try! Regex(#"^\s*([^%\n]{2,70}?)[\s.:_\-–—]*(\d{1,3}(?:\.\d+)?)\s*%"#) }
        /// Adjacent lines shaped like "Name …… 15%" whose weights add up to roughly 100%: the grade table.
        /// A letter-grade scale elsewhere in the document is a different run and does not spoil it.
        func gradeRows() -> [GradeRow] {
            var runs: [[GradeRow]] = [], current: [GradeRow] = []
            for line in lines {
                if let m = line.firstMatch(of: Source.rowPattern), let weight = Double(m.output.2), weight > 0, weight <= 100 {
                    var name = String(m.output.1).replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                    name = Normalize.collapseWhitespace(name.trimmingCharacters(in: CharacterSet(charactersIn: " .:-–—_\t")))
                    let letterScale = name.range(of: #"\b[A-F][+\-−]?\s*\d{2,3}$"#, options: .regularExpression) != nil   // "A 93–100%" is a grading scale, not a row
                    if name.contains(where: \.isLetter), name.split(separator: " ").count <= 6, !Source.isPenaltyLine(name), !letterScale {
                        current.append(GradeRow(name: name, weight: weight)); continue
                    }
                }
                // A wrapped continuation line (no "%") does not end the table; any other percentage line does.
                if line.contains("%"), !current.isEmpty { runs.append(current); current = [] }
            }
            if !current.isEmpty { runs.append(current) }
            return runs.filter { $0.count >= 2 && (90...110).contains($0.reduce(0) { $0 + $1.weight }) }.max { $0.count < $1.count } ?? []
        }

        /// The source's own wording for a model-quoted policy, sentence by sentence; `verbatim == false` when a sentence has no close match.
        func verbatim(_ quoted: String) -> (String, Bool) {
            let cleaned = Normalize.collapseWhitespace(quoted)
            if contains(cleaned) { return (cleaned, true) }
            var rebuilt: [String] = [], allMatched = true
            for piece in cleaned.components(separatedBy: ". ").map({ $0.trimmingCharacters(in: .whitespaces) }) where !piece.isEmpty {
                if contains(piece) { rebuilt.append(piece); continue }
                if let best = sentences.map({ ($0, Normalize.similarity($0, piece)) }).max(by: { $0.1 < $1.1 }), best.1 >= 0.5 {
                    rebuilt.append(best.0.hasSuffix(".") ? String(best.0.dropLast()) : best.0)
                } else {
                    rebuilt.append(piece); allMatched = false
                }
            }
            let text = rebuilt.joined(separator: ". ")
            return (text.last.map { ".!?".contains($0) } == true ? text : text + ".", allMatched)
        }
    }

    static func isDuplicate(_ a: ParsedObligation, _ b: ParsedObligation, calendar: Calendar) -> Bool {
        guard Normalize.key(a.title) == Normalize.key(b.title) else { return false }
        switch (a.due, b.due) {
        case (nil, nil): return true
        case (let x?, let y?): return calendar.isDate(x, inSameDayAs: y)
        default: return false
        }
    }

    /// "quizzes" → "quiz", "classes" → "class", "labs" → "lab".
    static func stem(_ word: String) -> String {
        if word.hasSuffix("zzes") { return String(word.dropLast(3)) }
        if word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("sses") || word.hasSuffix("xes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    static func matchComponent(_ name: String?, in components: [ParsedGradeComponent]) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let key = Normalize.key(name)
        if let exact = components.first(where: { Normalize.key($0.name) == key }) { return exact.name }
        let stemmed = key.split(separator: " ").map { stem(String($0)) }.joined(separator: " ")
        return components.first { c in
            let ck = Normalize.key(c.name).split(separator: " ").map { stem(String($0)) }.joined(separator: " ")
            return ck == stemmed || ck.contains(stemmed) || stemmed.contains(ck)
        }?.name
    }

    static let synonyms: [String: [String]] = [
        "hw": ["homework"], "homework": ["homework", "hw", "assignment"], "ps": ["problem set"], "pset": ["problem set"], "problem": ["problem set"],
        "quiz": ["quiz"], "lab": ["lab"], "midterm": ["midterm", "exam"], "exam": ["exam", "midterm", "test"], "test": ["test", "exam"],
        "final": ["final"], "project": ["project"], "paper": ["paper", "essay"], "essay": ["essay", "paper"], "presentation": ["presentation"],
        "reading": ["reading"], "discussion": ["discussion", "participation"], "report": ["report", "lab"], "assignment": ["assignment", "homework"],
        "composition": ["composition"], "response": ["response paper"],
    ]

    /// "HW 3" → "Homework", "Quiz 2" → "Quizzes", "Midterm 1" → "Midterm 1" or "Exams". Nil when nothing fits.
    static func inferComponent(fromTitle title: String, in components: [ParsedGradeComponent]) -> String? {
        if let exact = components.first(where: { Normalize.key($0.name) == Normalize.key(title) }) { return exact.name }
        guard let head = Normalize.key(title).split(separator: " ").first.map({ stem(String($0)) }) else { return nil }
        let candidates = [head] + (synonyms[head] ?? [])
        for candidate in candidates {
            let match = components.first { c in
                let words = Normalize.key(c.name).split(separator: " ").map { stem(String($0)) }
                return words.contains(candidate) || words.joined(separator: " ").contains(candidate)
            }
            if let match { return match.name }
        }
        // "MP HW 1" → the component whose initials start with "mp" (Mastering Physics Homework).
        if (2...4).contains(head.count), head.allSatisfy(\.isLetter) {
            return components.first { c in
                let initials = Normalize.key(c.name).split(separator: " ").compactMap(\.first).map(String.init).joined()
                return initials.hasPrefix(head)
            }?.name
        }
        return nil
    }

    static func impliedCount(_ cadence: Cadence?, termStart: Date?, termEnd: Date?) -> Int? {
        guard let cadence else { return nil }
        if cadence == .once { return 1 }
        guard let termStart, let termEnd, termEnd > termStart else { return nil }
        let weeks = max(1, Int(termEnd.timeIntervalSince(termStart) / (7 * 86400)))
        return cadence == .weekly ? weeks : max(1, weeks / 2)
    }

    static func platform(_ raw: String) -> Platform {
        switch raw {
        case "lms": .lms
        case "webassign": .webAssign
        case "gradescope": .gradescope
        case "mylab": .myLab
        default: .syllabusOnly
        }
    }

    static func policyKind(_ raw: String) -> PolicyKind {
        switch raw {
        case "late_work": .lateWork
        case "makeup_exam": .makeupExam
        case "attendance": .attendance
        case "drop_rule": .dropRule
        case "extra_credit": .extraCredit
        default: .other
        }
    }

    static func weekdayNumber(_ name: String) -> Int {
        ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7][String(name.lowercased().prefix(3))] ?? 2
    }
}
