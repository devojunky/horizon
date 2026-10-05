import Foundation

/// The shape shared by fixture ground truth and by what an ingest produced, so the two can be scored against each other.
public struct FixtureShape: Codable, Sendable, Equatable {
    public struct Course: Codable, Sendable, Equatable {
        public var code: String?
        public var title: String?
        public init(code: String? = nil, title: String? = nil) { self.code = code; self.title = title }
    }
    public struct Component: Codable, Sendable, Equatable {
        public var name: String
        /// Fraction 0…1.
        public var weight: Double
        public init(name: String, weight: Double) { self.name = name; self.weight = weight }
    }
    public struct Obligation: Codable, Sendable, Equatable {
        public var title: String
        /// YYYY-MM-DD in the document's local calendar, or nil for TBD.
        public var due: String?
        public var platform: Platform?
        public var component: String?
        /// Produced side only; ground truth leaves it nil.
        public var status: ObligationStatus?
        public init(title: String, due: String?, platform: Platform? = nil, component: String? = nil, status: ObligationStatus? = nil) {
            self.title = title; self.due = due; self.platform = platform; self.component = component; self.status = status
        }
    }
    public var course: Course?
    public var gradeComponents: [Component]
    public var obligations: [Obligation]

    public init(course: Course? = nil, gradeComponents: [Component] = [], obligations: [Obligation] = []) {
        self.course = course; self.gradeComponents = gradeComponents; self.obligations = obligations
    }
}

extension IngestResult {
    public func fixtureShape(calendar: Calendar = .current) -> FixtureShape {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        return FixtureShape(
            course: course.map { FixtureShape.Course(code: $0.code, title: $0.title) },
            gradeComponents: gradeComponents.compactMap { c in c.weight.map { FixtureShape.Component(name: c.name, weight: $0) } },
            obligations: obligations.map { FixtureShape.Obligation(title: $0.title, due: $0.due.map(f.string(from:)), platform: $0.platform, component: $0.componentName, status: $0.status) })
    }
}

public struct EvalScore: Codable, Sendable {
    public var expected: Int
    public var produced: Int
    public var matched: Int
    /// matched ÷ expected. The metric that matters most: a miss is the failure the app exists to prevent.
    public var recall: Double
    /// Among matched items with an expected date, fraction whose produced date is the same day.
    public var dateAccuracy: Double
    /// Among expected grade components, fraction found with weight within ±0.5 points.
    public var weightAccuracy: Double
    /// Among matched items with an expected platform, fraction attributed to it.
    public var platformAccuracy: Double
    /// Produced obligations that match nothing expected. Should be zero.
    public var falsePositives: Int
    public var falsePositiveRate: Double
    /// Items that would be written out wrong without review: spurious or wrong-dated, with `status == .ready`. Must be zero.
    public var readyErrors: Int
    public var courseFound: Bool
    public var notes: [String]
}

public enum Scoring {
    public static let minimumSimilarity = 0.5
    /// A weaker title match is accepted when the day agrees and the expected head word ("lab", "homework") is present.
    public static let sameDaySimilarity = 0.2

    public static func score(produced: FixtureShape, expected: FixtureShape) -> EvalScore {
        var notes: [String] = []
        var used = Set<Int>()
        var matched = 0, dated = 0, dateCorrect = 0, platformed = 0, platformCorrect = 0, readyErrors = 0

        for want in expected.obligations {
            var best: (index: Int, score: Double)?
            let head = Normalize.tokens(want.title).subtracting(Normalize.numbers(want.title))
            for (i, got) in produced.obligations.enumerated() where !used.contains(i) {
                var s = Normalize.similarity(want.title, got.title)
                let sameDay = want.due != nil && want.due == got.due
                let headPresent = !head.isEmpty && !head.isDisjoint(with: Normalize.tokens(got.title))
                guard s >= minimumSimilarity || (sameDay && headPresent && s >= sameDaySimilarity) else { continue }
                if sameDay { s += 0.5 }   // same day breaks ties between series items
                if best == nil || s > best!.score { best = (i, s) }
            }
            guard let best else { notes.append("missed: \(want.title) (\(want.due ?? "TBD"))"); continue }
            used.insert(best.index)
            matched += 1
            let got = produced.obligations[best.index]
            if Normalize.similarity(want.title, got.title) < minimumSimilarity { notes.append("title: \(want.title) got \(got.title)") }
            if let d = want.due {
                dated += 1
                if got.due == d { dateCorrect += 1 } else {
                    notes.append("date: \(want.title) expected \(d) got \(got.due ?? "nil") (\(got.status.map { "\($0)" } ?? "?"))")
                    if got.status == nil || got.status == .ready { readyErrors += 1 }
                }
            } else if let invented = got.due {
                // The document gives no date and the parser does: a date made up, and shipped unless it waits for review.
                notes.append("date: \(want.title) expected TBD got \(invented) (\(got.status.map { "\($0)" } ?? "?"))")
                if got.status == nil || got.status == .ready { readyErrors += 1 }
            }
            if let p = want.platform {
                platformed += 1
                if got.platform == p { platformCorrect += 1 } else { notes.append("platform: \(want.title) expected \(p) got \(got.platform.map { "\($0)" } ?? "nil")") }
            }
        }
        for (i, got) in produced.obligations.enumerated() where !used.contains(i) {
            notes.append("spurious: \(got.title) (\(got.due ?? "TBD"), \(got.status.map { "\($0)" } ?? "?"))")
            if got.status == nil || got.status == .ready { readyErrors += 1 }
        }
        let falsePositives = produced.obligations.count - used.count

        var weightHits = 0
        for want in expected.gradeComponents {
            let key = Normalize.key(want.name)
            if let got = produced.gradeComponents.first(where: { Normalize.key($0.name) == key || Normalize.similarity($0.name, want.name) >= 0.5 }) {
                if abs(got.weight - want.weight) <= 0.005 { weightHits += 1 } else { notes.append("weight: \(want.name) expected \(want.weight) got \(got.weight)") }
            } else { notes.append("component missing: \(want.name)") }
        }

        let courseFound = expected.course.map { want in
            guard let got = produced.course else { return false }
            let codeOK = want.code.map { w in got.code.map { Normalize.key($0) == Normalize.key(w) } ?? false } ?? true
            let titleOK = want.title.map { w in got.title.map { Normalize.similarity($0, w) >= 0.5 } ?? false } ?? true
            return codeOK && titleOK
        } ?? true

        return EvalScore(
            expected: expected.obligations.count, produced: produced.obligations.count, matched: matched,
            recall: expected.obligations.isEmpty ? 1 : Double(matched) / Double(expected.obligations.count),
            dateAccuracy: dated == 0 ? 1 : Double(dateCorrect) / Double(dated),
            weightAccuracy: expected.gradeComponents.isEmpty ? 1 : Double(weightHits) / Double(expected.gradeComponents.count),
            platformAccuracy: platformed == 0 ? 1 : Double(platformCorrect) / Double(platformed),
            falsePositives: falsePositives,
            falsePositiveRate: produced.obligations.isEmpty ? 0 : Double(falsePositives) / Double(produced.obligations.count),
            readyErrors: readyErrors,
            courseFound: courseFound, notes: notes)
    }
}
