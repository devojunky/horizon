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
        // A document that names no course belongs to the one the caller knows.
        if let known = options.knownCourse, course == nil, known.code != nil || known.title != nil {
            course = ParsedCourse(code: known.code ?? "", title: known.title ?? "", instructor: nil, term: known.term, termStart: nil, termEnd: nil, room: nil, meetings: [])
        }
        let year = DateResolver.year(inTerm: course?.term ?? options.knownCourse?.term, fallback: options.defaultYear ?? options.calendar.component(.year, from: Date()))
        var resolver = DateResolver(calendar: options.calendar, defaultYear: year)
        // Term boundaries: the document's own "classes begin … and end …" sentence first, then a model date the document
        // actually names (the model has put a term start a week off, which shifts every week-relative deadline); an
        // image page keeps the model's reading.
        let termFacts = extractions.compactMap(\.course)
        func termDay(_ stated: Date?, _ iso: (CourseFacts) -> String?) -> Date? {
            if let stated { return stated }
            for facts in termFacts {
                guard let raw = iso(facts), let day = resolver.resolveDay(iso: raw, asWritten: "") else { continue }
                if !source.hasText || resolver.mentions(day).contains(where: source.contains) { return day }
                warnings.append("Ignored term date \(raw): the document never names it")
            }
            return nil
        }
        course?.termStart = options.termStart ?? termDay(source.termBoundary(.start, resolver), \.termStart) ?? options.knownCourse?.termStart
        course?.termEnd = termDay(source.termBoundary(.end, resolver), \.termEnd) ?? options.knownCourse?.termEnd
        resolver.termStart = course?.termStart ?? options.termStart ?? options.knownCourse?.termStart
        resolver.termEnd = course?.termEnd ?? options.knownCourse?.termEnd

        // Grade components: dedupe by name; recover a missing weight from the source line; ignore rows once weights total 100%.
        var components: [ParsedGradeComponent] = []
        var componentPlatforms: [String: Platform] = [:]
        // Components the caller already knows (a syllabus read earlier) come first; a schedule need not repeat them.
        let knownKeys = Set((options.knownCourse?.components ?? []).map { Normalize.key($0.name) })
        for known in options.knownCourse?.components ?? [] {
            components.append(ParsedGradeComponent(name: known.name, weight: known.weight, expectedCount: known.expectedCount, cadence: known.cadence, dropLowest: nil))
            if let p = known.platform { componentPlatforms[Normalize.key(known.name)] = p }
        }
        for facts in extractions.flatMap(\.gradeComponents) {
            let key = Normalize.key(facts.name)
            guard key.filter(\.isLetter).count >= 3 else { continue }   // "5.3-4": a section number from a schedule, not a component
            if source.hasText, !knownKeys.contains(key), !source.contains(facts.name) { warnings.append("Ignored component '\(facts.name)': not in the document"); continue }
            let weight = (source.percentage(onLineMentioning: facts.name) ?? facts.weightPercent.flatMap { $0 > 0 ? $0 : nil }).map { $0 / 100 }   // the row's own figure first; 0% is no figure
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
            for row in source.gradeRows(preferring: components.map(\.name)) {
                if let i = components.firstIndex(where: { Source.sameComponent($0.name, row.name) }) {
                    if let w = components[i].weight, abs(w - row.weight / 100) > 0.001 {
                        warnings.append("Component '\(components[i].name)': the grade table says \(Int(row.weight))%, not \(Int(w * 100))%")
                    }
                    components[i].weight = row.weight / 100
                } else {
                    components.append(ParsedGradeComponent(name: row.name, weight: row.weight / 100))
                    warnings.append("Component '\(row.name)' read from the grade table; the model skipped it")
                }
            }
        }
        // A grade table that totals 100% is the whole story: a component the model named that is not one of its rows
        // (a duplicate under another name, or a heading) is dropped rather than carried weightless.
        let tableRows = source.gradeRows(preferring: components.map(\.name))
        if tableRows.count >= 3, (99...101).contains(tableRows.map(\.weight).reduce(0, +)),
           components.contains(where: { c in tableRows.contains { Source.sameComponent(c.name, $0.name) } }) {
            components.removeAll { c in
                if knownKeys.contains(Normalize.key(c.name)) { return false }   // what the caller knows stands
                let inTable = tableRows.contains { Source.sameComponent(c.name, $0.name) }
                if !inTable { warnings.append("Ignored component '\(c.name)': not a row of the grade table") }
                return !inTable
            }
        }
        for c in components {   // the grading row's own wording is the authority on where a component is submitted
            if let p = source.platform(onLineMentioning: c.name) { componentPlatforms[Normalize.key(c.name)] = p }
        }
        let componentKeys = Set(components.map { Normalize.key($0.name) })

        // Obligations.
        var obligations: [ParsedObligation] = []
        var merged = 0, dropped = 0, skippedTopics = 0
        for outcome in outcomes {
            // Text chunks are checked strictly against the document text. Image pages are checked against Vision OCR
            // text, which can misread a date, so failures there downgrade to review instead of dropping.
            let strict = outcome.kind == .text && source.hasText
            let siblingTitles = Set(outcome.extraction.obligations.map { Normalize.key($0.title) })
            for facts in outcome.extraction.obligations {
                var title = Self.ownName(Normalize.collapseWhitespace(facts.title))
                guard !title.isEmpty else { continue }
                if strict, Self.isTopicOrSession(title) { skippedTopics += 1; continue }   // a lecture topic, a reading, a class session
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
                        // The model computed a date the document never states, or supplied one for wording that names no
                        // day at all ("weekly, due Sundays" with the third week's Sunday): review either way.
                        if !resolution.resolvedFromText, !dateInSource || (strict && spans.isEmpty && !DateResolver.isTBD(facts.dateAsWritten)) {
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
                // "Lab 1   Data and R basics   due Thu Feb 4": the item's name is its own cell, not the cell and its topic.
                if strict, let row = source.segment(mentioning: title) {
                    let cells = Source.cells(of: row)
                    if cells.count >= 2, cells[0].contains(where: \.isNumber), Normalize.key(title).hasPrefix(Normalize.key(cells[0]) + " "),
                       Normalize.key(title).contains(Normalize.key(cells[1])) {
                        title = Normalize.collapseWhitespace(cells[0])
                    }
                }
                // The title must be the document's own wording. A name the document never prints ("Midterm 1" for
                // "Exam 1", or one carried over from another item) is replaced by the label of the line that carries
                // the item's date; a label cut from prose, or no label at all, means review.
                if strict, !source.contains(title) || componentKeys.contains(Normalize.key(title)) {
                    let found = resolution.date.flatMap { source.label(on: resolver.mentions($0), title: title, otherTitles: siblingTitles.subtracting([Normalize.key(title)])) }
                        .map { (text: Self.ownName($0.text), prose: $0.prose) }
                    if let label = found, Normalize.key(label.text).contains(Normalize.key(title)) {
                        // The row names the item as the model did ("… Midterm 1 Wed Oct 7"): the title stands.
                    } else if let label = found {
                        warnings.append("Renamed '\(title)' to '\(label.text)': the document's own wording")
                        title = label.text
                        if label.prose { flags.append(.titleFromLine); confidence = min(confidence, options.reviewThreshold - 0.05) }
                    } else if componentKeys.contains(Normalize.key(title)), source.contains(title) {
                        // A grade-row name the document also uses as the item's name ("Final Exam"): nothing to rename.
                    } else {
                        flags.append(.titleNotInSource); confidence = min(confidence, options.reviewThreshold - 0.05)
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
                    // The wording is a span of days ("Sept 14-18", "30 - Dec 4"): the deadline is somewhere inside it, not at its end.
                    if !facts.dateAsWritten.localizedCaseInsensitiveContains("due") {
                        if let rest = Source.withoutDaySpan(facts.dateAsWritten), !Source.hasDate(rest) { ambiguous = true }
                        else if spans.contains(where: { $0.start != $0.end }), !spans.contains(where: { $0.start == $0.end }) { ambiguous = true }
                    }
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
                // The document names the item and the date, but never together: the date was lifted from another line.
                if strict, !spans.isEmpty, let date = resolution.date, source.titleShares(title, dateForms: resolver.mentions(date)) == false {
                    flags.append(.dateNotOnRow); confidence = min(confidence, options.reviewThreshold - 0.05)
                }
                // No wording to check, or an image Vision could not read: the model is on its own, so review.
                if Self.isNoWording(facts.dateAsWritten) || (outcome.kind == .image && !source.hasText) {
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
        if skippedTopics > 0 { warnings.append("\(skippedTopics) lecture topic, reading or session line(s) skipped") }

        // Points at stake: component weight ÷ expected item count (stated count, else cadence-implied, else items on file).
        for (i, ob) in obligations.enumerated() {
            guard let name = ob.componentName, let component = components.first(where: { Normalize.key($0.name) == Normalize.key(name) }),
                  let weight = component.weight else { continue }
            let onFile = obligations.filter { $0.componentName.map(Normalize.key) == Normalize.key(name) }.count
            obligations[i].pointsAtStake = PointsAtStake.perItem(weight: weight, expectedCount: component.expectedCount, cadence: component.cadence,
                                                                  termStart: resolver.termStart, termEnd: resolver.termEnd, onFile: onFile)
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
        let sourcePlatform = outcomes.contains { $0.kind == .image } && !outcomes.contains { $0.kind == .text } ? source.uniquePlatform : nil
        return IngestResult(document: document.info, sourcePlatform: sourcePlatform, route: route, course: course, gradeComponents: components,
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

        /// The wording with its span of days removed ("Sept 14-18" → "Sept ", "Nov 30-Dec 4, Thu Dec 3" → "Nov , Thu Dec 3"), or nil
        /// when it holds no span. A time range like "2:00–3:50" is not a span of days.
        static func withoutDaySpan(_ wording: String) -> String? {
            // "17 Dec 21-25": a schedule's week number in front of the month.
            let wording = wording.replacingOccurrences(of: #"(?i)^\s*\d{1,2}\s+(?=(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\s*[-–—])"#, with: "", options: .regularExpression)
            guard wording.range(of: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#, options: .regularExpression) != nil,
                  let span = wording.range(of: #"(?i)(?<![:\d/])\d{1,2}\s*[-–—]\s*(?:[a-z]{3,9}\.?\s+)?\d{1,2}(?![:\d/])"#, options: .regularExpression) else { return nil }
            return wording.replacingCharacters(in: span, with: " ")
        }

        /// A wrapped line holding nothing but a date, e.g. "Oct 30", "Fri Oct 30, 11:59 PM", "9/16.".
        static func isDateFragment(_ line: String) -> Bool {
            line.range(of: #"(?i)^\s*(?:(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\.?,?\s*)?(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}/\d{1,2})(?:,?\s*\d{4})?(?:,?\s*(?:at\s*)?\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?)?[.;]?\s*$"#, options: .regularExpression) != nil
        }

        /// A month-and-day or numeric M/D somewhere in the text.
        static func hasDate(_ text: String) -> Bool {
            text.range(of: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?\b|\b\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b|\b\d{1,2}/\d{1,2}\b"#, options: .regularExpression) != nil
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

        /// The label of the line that carries the item's date: the words before that date, when they read as a name
        /// ("Exam 1" from "Exam 1 Tuesday, October 6th, 2026"). The line must share a word with the model's title, or be
        /// the only line naming the date; a label that is another item's title is refused. `prose` marks a label cut
        /// from a sentence ("opt out of the program" from "… opt out of the program by September 17th").
        func label(on dateForms: [String], title: String, otherTitles: Set<String>) -> (text: String, prose: Bool)? {
            let patterns = dateForms.compactMap(Source.regex(forDateForm:))
            let titleWords = Set(Normalize.tokens(title).filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }.map(Merger.stem))
            let carrying = lines.filter { line in patterns.contains { line.range(of: $0, options: .regularExpression) != nil } }
            let related = carrying.filter { line in !Set(Normalize.tokens(line).map(Merger.stem)).isDisjoint(with: titleWords) }
            let candidates = related.isEmpty ? (carrying.count == 1 ? carrying : []) : related
            for raw in candidates {
                guard let match = patterns.compactMap({ raw.range(of: $0, options: .regularExpression) }).min(by: { $0.lowerBound < $1.lowerBound }) else { continue }
                var head = String(raw[..<match.lowerBound])
                // "Week 3 (Sep 14, Sep 16): Quiz 1 due Sep 18" → the clause after a dated preamble.
                if let colon = head.range(of: ":", options: .backwards), Source.hasDate(String(head[..<colon.lowerBound])) { head = String(head[colon.upperBound...]) }
                // A weekday printed before the date belongs to the date.
                head = head.replacingOccurrences(of: #"(?i)[\s,\-–—(]*(?:(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\.?)?[\s,\-–—(:]*$"#, with: "", options: .regularExpression)
                var prose = false
                if let m = head.range(of: #"(?i)[\s:,\-–—(]*\b(by|on|is|at|before|until|of|due|through|dated?)\b[\s:,\-–—(]*$"#, options: .regularExpression) {
                    prose = !head[m].localizedCaseInsensitiveContains("due")
                    head = String(head[..<m.lowerBound])
                }
                // "You must opt out of the program" → "opt out of the program".
                head = head.replacingOccurrences(of: #"(?i)^\W*(?:(?:you|students|all students|everyone)\s+)?(?:must|should|need to|have to|are required to|are expected to|please)\s+"#, with: "", options: .regularExpression)
                head = head.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                let words = head.split(separator: " ")
                guard (1...6).contains(words.count), !head.contains("%"), head.first?.isLetter == true, !otherTitles.contains(Normalize.key(head)),
                      !["due", "date", "due date", "deadline", "by", "on", "submit", "submission"].contains(Normalize.key(head)) else { continue }   // "DUE DATE: Monday, November 9" labels nothing
                if words.count > 3, head.first?.isLowercase == true { prose = true }
                return (head.prefix(1).uppercased() + head.dropFirst(), prose)
            }
            return nil
        }
        /// A date form from `DateResolver.mentions` ("october 6", "10 6") as a pattern over printed text: "October 6th", "10/6".
        static func regex(forDateForm form: String) -> String? {
            let parts = form.split(separator: " ").map(String.init)
            guard !parts.isEmpty else { return nil }
            let pieces = parts.map { part -> String in
                let escaped = NSRegularExpression.escapedPattern(for: part)
                return part.allSatisfy(\.isNumber) ? escaped + #"(?:st|nd|rd|th)?"# : escaped + #"\.?"#
            }
            return #"(?i)\b"# + pieces.joined(separator: #"[\s./,\-]+"#) + #"\b"#
        }
        /// Whether a line naming the item also names one of the date forms (a date on the following line counts, as a
        /// wrapped row); nil when no line names the item.
        func titleShares(_ title: String, dateForms: [String]) -> Bool? {
            let needle = " " + Normalize.key(title) + " "
            var found = false
            for (i, raw) in lines.enumerated() where (" " + Normalize.key(raw) + " ").contains(needle) {
                found = true
                var text = Source.normalize(raw)
                if i + 1 < lines.count, Source.isDateFragment(lines[i + 1]) { text += " " + Source.normalize(lines[i + 1]) }
                if i > 0, Source.isDateFragment(lines[i - 1]) { text = Source.normalize(lines[i - 1]) + " " + text }
                let k = " " + text + " "
                if dateForms.contains(where: { k.contains(" \($0) ") }) { return true }
            }
            return found ? false : nil
        }

        /// Two names for the same grade component: similar wording, or one contained in the other.
        static func sameComponent(_ a: String, _ b: String) -> Bool {
            Normalize.similarity(a, b) >= 0.5 || Normalize.key(a).contains(Normalize.key(b)) || Normalize.key(b).contains(Normalize.key(a))
        }
        /// A row wrapped inside a parenthesis ("Homework (WebAssign, lowest two" / "dropped) …… 15%") reads as one line.
        static func joiningWrappedRows(_ lines: [String]) -> [String] {
            var out: [String] = []
            var i = 0
            while i < lines.count {
                var line = lines[i], joins = 0
                while i + 1 < lines.count, joins < 2, !line.contains("%"), line.filter({ $0 == "(" }).count > line.filter({ $0 == ")" }).count {
                    line += " " + lines[i + 1].trimmingCharacters(in: .whitespaces); i += 1; joins += 1
                }
                out.append(line); i += 1
            }
            return out
        }

        /// Where a date begins on a line: an optional weekday, then "Sep 9", "9 Sep", "9/9".
        static let dateStart = #"(?i)\b(?:(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\.?,?\s+)?(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?\b|\d{1,2}/\d{1,2}\b|\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b)"#

        enum TermBoundary { case start, end }
        /// The date the document itself gives for the start or end of classes: the first date after "begin(s)", "start(s)"
        /// or "first day of classes" (or "end(s)", "last day of classes") in a sentence about classes, the semester or the term.
        func termBoundary(_ which: TermBoundary, _ resolver: DateResolver) -> Date? {
            let keyword = switch which {
            case .start: #"(?i)\b(?:begins?|starts?|commences?|first\s+(?:day|week)\s+of\s+(?:classes|class|the\s+semester|the\s+term|instruction))\b"#
            case .end: #"(?i)\b(?:ends?|concludes?|last\s+(?:day|week)\s+of\s+(?:classes|class|the\s+semester|the\s+term|instruction))\b"#
            }
            for line in lines {
                for sentence in line.split(separator: Source.segmentSeparator).map(String.init) {
                    guard sentence.range(of: #"(?i)\b(?:classes|class|semester|term|instruction|lectures?|course)\b"#, options: .regularExpression) != nil,
                          let m = sentence.range(of: keyword, options: .regularExpression),
                          let span = resolver.explicitSpans(in: String(sentence[m.upperBound...])).first else { continue }
                    var day = span.start
                    day.hour = 0; day.minute = 0; day.second = 0
                    return resolver.calendar.date(from: day)
                }
            }
            return nil
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
        func gradeRows(preferring names: [String] = []) -> [GradeRow] {
            var runs: [[GradeRow]] = [], current: [GradeRow] = []
            for line in Source.joiningWrappedRows(lines) {
                if let m = line.firstMatch(of: Source.rowPattern), let weight = Double(m.output.2), weight > 0, weight <= 100 {
                    var name = String(m.output.1).replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"[()\[\]]"#, with: "")   // a stray bracket from a wrapped row
                    name = Normalize.collapseWhitespace(name.trimmingCharacters(in: CharacterSet(charactersIn: " .:-–—_\t")))
                    let letterScale = name.range(of: #"\b[A-F][+\-−]?\s*\d{2,3}$"#, options: .regularExpression) != nil   // "A 93–100%" is a grading scale, not a row
                    let total = name.range(of: #"(?i)^\s*(total|sum)\b"#, options: .regularExpression) != nil               // "Total 100%" closes the table
                    if total { if !current.isEmpty { runs.append(current); current = [] }; continue }
                    if name.contains(where: \.isLetter), name.split(separator: " ").count <= 6, !Source.isPenaltyLine(name), !letterScale {
                        current.append(GradeRow(name: name, weight: weight)); continue
                    }
                }
                // A wrapped continuation line (no "%") does not end the table; any other percentage line does.
                if line.contains("%"), !current.isEmpty { runs.append(current); current = [] }
            }
            if !current.isEmpty { runs.append(current) }
            let tables = runs.filter { $0.count >= 2 && (90...110).contains($0.reduce(0) { $0 + $1.weight }) }
            // Several tables that total 100% (a grade breakdown and a rubric): the one naming the model's components, else the first.
            func matches(_ table: [GradeRow]) -> Int { names.filter { name in table.contains { Source.sameComponent($0.name, name) } }.count }
            return tables.enumerated().max { a, b in (matches(a.element), -a.offset) < (matches(b.element), -b.offset) }?.element ?? []
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

    /// The item's own name out of a schedule row the model copied whole: "Week 3: Trig substitution. HW 3" → "HW 3",
    /// "8 Oct 19-23 Rotation MP HW 6" → "MP HW 6", "Lab 1: Measurement and density" → "Lab 1". A name of up to three
    /// words, or one without a component word next to its number, is left alone.
    static func ownName(_ title: String) -> String {
        var name = title
        // A week preamble, then the last sentence of what follows.
        if let m = name.range(of: #"(?i)^\s*week\s*\d+\b[^.:]*[.:]\s*"#, options: .regularExpression) {
            let rest = String(name[m.upperBound...])
            let sentences = rest.split(separator: ". ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let last = sentences.last, last.split(separator: " ").count <= 4 { name = String(last) } else { name = rest }
        }
        // A schedule row's week number and date range.
        name = name.replacingOccurrences(of: #"(?i)^\s*\d{1,2}\s+[a-z]{3,9}\.?\s+\d{1,2}(?:\s*[-–]\s*(?:[a-z]{3,9}\.?\s+)?\d{1,2})?\s+"#, with: "", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        let words = name.split(separator: " ").map(String.init)
        func isNumber(_ w: String) -> Bool { let digits = w.trimmingCharacters(in: .punctuationCharacters); return !digits.isEmpty && digits.allSatisfy(\.isNumber) }   // "&" and "—" are not numbers
        guard words.count > 3, let numberAt = words.lastIndex(where: isNumber) else { return name }
        func componentWord(_ w: String) -> Bool {
            let key = stem(Normalize.key(w))
            return synonyms[key] != nil || synonyms.values.contains { $0.contains(key) } || ["report", "set", "sheet"].contains(key)
                || (w.count <= 5 && w == w.uppercased() && w.allSatisfy(\.isLetter))   // "MP", "PS", "UNIT"
        }
        var start = numberAt, end = numberAt
        while start > 0, componentWord(words[start - 1]) { start -= 1 }
        while end + 1 < words.count, componentWord(words[end + 1]) { end += 1 }
        guard start < numberAt else { return name }   // no component word next to the number: not a name we can shorten safely
        var own = words[start...end].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-–—"))
        if own.filter({ $0 == "(" }).count > own.filter({ $0 == ")" }).count { own += ")" }   // "UNIT TEST 2 (MIDTERM)" keeps its bracket
        return own
    }

    /// A lecture topic, a reading, or a class session the model listed as an obligation: "Chapter 2, Diversity…",
    /// "Read Chapter 4", "SHARK TANK GROUP WORK SESSION #1", "Course synthesis and final examination preparation".
    /// A title naming a deliverable (quiz, exam, homework, paper…) is kept.
    static func isTopicOrSession(_ title: String) -> Bool {
        let key = " " + Normalize.key(title) + " "
        if key.range(of: #"\b(work session|review session|planning time|in class|in person|online session|class meeting|group work|office hours|no class|no classes|holiday|reading day|finals week|exam preparation|examination preparation|exam review|review for the|review for)\b"#, options: .regularExpression) != nil { return true }
        let deliverable = #"\b(quiz|quizzes|test|tests|exam|exams|midterm|midterms|final|finals|homework|hw|assignment|assignments|project|paper|essay|lab|labs|report|presentation|presentations|problem set|problem sets|pset|ps\d+|due|submit|submission|worksheet|discussion post|response|proposal|draft|portfolio|deadline)\b"#
        guard key.range(of: deliverable, options: .regularExpression) == nil else { return false }
        return key.range(of: #"^ (chapter|chapters|ch|lecture|lectures|topic|topics|module|modules|reading|readings|read|review|introduction|course synthesis|syllabus|welcome|overview)\b"#, options: .regularExpression) != nil
    }

    /// "", "null", "none", "n/a": the model had no wording to copy, whatever date it then chose.
    static func isNoWording(_ s: String) -> Bool { ["", "null", "none", "nil", "n a", "na", "tbd null"].contains(Normalize.key(s)) }

    static func isDuplicate(_ a: ParsedObligation, _ b: ParsedObligation, calendar: Calendar) -> Bool {
        let sameDay: Bool = switch (a.due, b.due) {
        case (nil, nil): true
        case (let x?, let y?): calendar.isDate(x, inSameDayAs: y)
        default: false
        }
        guard sameDay else { return false }
        if Normalize.similarity(a.title, b.title) >= 0.5 { return true }
        // "Election 2026 assignment" and "ELECTION 2026: POWER & POLITICS IN ACTION — DUE" on one day are one item.
        let filler: Set<String> = ["assignment", "due", "the", "of", "and", "a", "an", "deadline", "in"]
        let ta = Normalize.tokens(a.title).subtracting(filler), tb = Normalize.tokens(b.title).subtracting(filler)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        return ta.isSubset(of: tb) || tb.isSubset(of: ta)
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
        guard let first = Normalize.key(title).split(separator: " ").first else { return nil }
        let letters = first.prefix(while: \.isLetter)   // "PS0" → "ps"
        let head = stem(letters.isEmpty ? String(first) : String(letters))
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
        PointsAtStake.impliedCount(cadence, termStart: termStart, termEnd: termEnd)
    }

    /// The store's way to name a component for an item it files under a course later ("PS 3" → "Problem Sets").
    static func componentName(forTitle title: String, among names: [String]) -> String? {
        inferComponent(fromTitle: title, in: names.map { ParsedGradeComponent(name: $0, weight: nil) })
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
