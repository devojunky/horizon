import Foundation
import IngestKit

/// Search across what the app holds (the Search tab, the Mac's sidebar field, Siri's "search Horizon for…"): items,
/// courses, policies and documents. Two passes, merged (`merge`): the words' own matching here, and what Spotlight's
/// own search found over the index Horizon writes (`Ranked`, by meaning where the device has the models: the app asks
/// Core Spotlight), which brings what the words miss and is simply absent wherever Spotlight has nothing to say (the
/// simulator, a device without the models, the moment before the index has the latest change).
///
/// The words' matching reads a question as well as a word: Siri hands the in-app search the whole sentence ("the
/// makeup exam policy for Calc"), so the words a question carries around its subject are dropped (`filler`), "policy"
/// names the policies, and a result needs most of what is left, not all of it: one or two words must all be there, three
/// or more at least three in five. Each word has to start a word of the result; one in its name counts for more.
public enum HorizonSearch {
    public struct Results: Sendable, Equatable {
        public var items: [ObligationSnapshot] = []
        public var courses: [CourseSnapshot] = []
        public var policies: [PolicySnapshot] = []
        public var documents: [DocumentSnapshot] = []
        public var isEmpty: Bool { items.isEmpty && courses.isEmpty && policies.isEmpty && documents.isEmpty }
        public init() {}
    }

    /// What Spotlight found for the query, best first, by id: it leads the results of its kind.
    public struct Ranked: Sendable, Equatable {
        public var items: [UUID] = []
        public var courses: [UUID] = []
        public var policies: [UUID] = []
        public var documents: [UUID] = []
        public var isEmpty: Bool { items.isEmpty && courses.isEmpty && policies.isEmpty && documents.isEmpty }
        public init() {}
    }

    /// At most this many of each kind: a search narrows, it does not list the library.
    public static let limit = 25

    /// The words a question or a command carries around what it is about, the app's own name among them.
    static let filler: Set<String> = [
        "a", "an", "the", "and", "or", "of", "for", "to", "in", "on", "at", "by", "with", "about", "from", "into", "s",
        "my", "me", "i", "is", "are", "was", "were", "be", "it", "its", "this", "that", "there", "any", "all",
        "what", "whats", "which", "who", "when", "where", "how", "do", "does", "did", "can", "could", "should", "would", "will",
        "show", "find", "search", "look", "up", "tell", "give", "list", "get", "horizon",
    ]

    public static func run(_ query: String, items: [ObligationSnapshot], courses: [CourseSnapshot], policies: [PolicySnapshot],
                           documents: [DocumentSnapshot], spotlight: Ranked = Ranked()) -> Results {
        let words = terms(query)
        var results = Results()
        guard !words.isEmpty || !spotlight.isEmpty else { return results }
        let liveItems = items.filter { $0.deletedAt == nil }
        let liveDocuments = documents.filter { $0.deletedAt == nil }
        let names = Dictionary(courses.map { ($0.id, $0.displayName + " " + $0.code) }, uniquingKeysWith: { a, _ in a })
        results.courses = merge(spotlight.courses, courses, ranked(courses, words) { [$0.title, $0.code, $0.term ?? ""] })
        results.items = merge(spotlight.items, liveItems, ranked(liveItems, words) {
            [$0.title, $0.courseID.flatMap { names[$0] } ?? $0.courseName ?? "", $0.componentName ?? "", $0.notes ?? ""]
        })
        results.policies = merge(spotlight.policies, policies, ranked(policies, words) {
            [PolicyLookup.name($0.kind) + " policy", $0.courseName ?? "", $0.text]
        })
        results.documents = merge(spotlight.documents, liveDocuments, ranked(liveDocuments, words) {
            [$0.displayName, $0.courseID.flatMap { names[$0] } ?? "", $0.filename]
        })
        return results
    }

    /// The words that say what a query is about: folded (case and accents), punctuation gone, filler dropped.
    public static func terms(_ s: String) -> [String] {
        Normalize.key(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).split(separator: " ").map(String.init)
            .filter { !filler.contains($0) }
    }

    /// Words a student uses for one another ("test makeups" asks about the "make-up exam").
    static let alike: [String: [String]] = [
        "test": ["exam", "midterm"], "tests": ["exam", "midterm"], "exam": ["test", "midterm"], "exams": ["test", "midterm"],
        "midterm": ["exam", "test"], "homework": ["assignment"], "hw": ["homework", "assignment"], "assignment": ["homework"],
    ]

    /// How many of a query's words a result must carry: all of one or two, three in five of more.
    static func needed(_ count: Int) -> Int { count <= 2 ? count : Int((Double(count) * 0.6).rounded(.up)) }

    /// Those whose fields carry enough of the words, best first, each marked whether it carries them all: the more
    /// words, then the more of them in the name (a word starting the first field 2 points, a later field 1); ties keep
    /// the given order. A field's words are read as printed and joined too, so "makeup" finds "make-up".
    static func ranked<T>(_ candidates: [T], _ words: [String], fields: (T) -> [String]) -> [(match: T, full: Bool)] {
        guard !words.isEmpty else { return [] }
        let enough = needed(words.count)
        let scored = candidates.enumerated().compactMap { index, candidate -> (T, Int, Int, Int)? in
            let fieldWords = fields(candidate).map { terms($0) + terms($0.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")) }
            var matched = 0, score = 0
            for word in words {
                let stem = word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word   // "makeups" finds "makeup"
                let forms = [word, stem] + (alike[word] ?? [])
                guard let field = fieldWords.firstIndex(where: { $0.contains { w in forms.contains { w.hasPrefix($0) } } }) else { continue }
                matched += 1
                score += field == 0 ? 2 : 1
            }
            return matched >= enough ? (candidate, matched, score, index) : nil
        }
        return scored.sorted { ($0.1, $0.2, -$0.3) > ($1.1, $1.2, -$1.3) }.prefix(limit).map { ($0.0, $0.1 == words.count) }
    }

    /// What carries every word first, in the words' own order (Spotlight's ranking of plain matches is no order a
    /// person would choose: "calc" listed a course's items any which way); then Spotlight's finds, which is where the
    /// meaning brings what the words miss; then what carries only most of the words. Each once, only what is on file.
    static func merge<T: Identifiable>(_ found: [UUID], _ all: [T], _ matched: [(match: T, full: Bool)]) -> [T] where T.ID == UUID {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        let full = matched.filter(\.full).map(\.match).filter { seen.insert($0.id).inserted }
        let spotlit = found.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        let partial = matched.filter { !$0.full }.map(\.match).filter { seen.insert($0.id).inserted }
        return Array((full + spotlit + partial).prefix(limit))
    }
}
