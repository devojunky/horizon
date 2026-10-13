import Foundation
import IngestKit

/// Finding the policy a question is about ("what's the policy on test makeups?", "can I hand in late?"): the kind its
/// words name, and the policies whose own words share the most with it. Deterministic: the answer is quoted, never
/// written, so it has to be found, not guessed.
public enum PolicyLookup {
    /// The kind a phrase names, when it names one ("test makeups" is a makeup exam, "extensions" late work).
    public static func kind(of phrase: String) -> PolicyKind? {
        let key = " " + Normalize.key(phrase) + " "
        for (kind, cues) in cues where cues.contains(where: { key.contains(" \($0)") }) { return kind }
        return nil
    }

    /// Ordered: a phrase naming a makeup exam also says "exam", and a late-work one may say "missed".
    private static let cues: [(PolicyKind, [String])] = [
        (.makeupExam, ["makeup", "make up", "make-up", "missed exam", "missed test", "missed quiz", "missed midterm", "miss an exam", "miss a test", "miss the exam", "miss the final", "reschedul", "conflict exam", "exam conflict", "retake"]),
        (.extraCredit, ["extra credit", "bonus"]),
        (.dropRule, ["drop", "lowest", "dropped"]),
        (.lateWork, ["late", "extension", "turn in after", "hand in after", "submit after", "past the deadline", "after the deadline", "penalt", "grace"]),
        (.attendance, ["attendance", "absence", "absent", "attend", "skip class", "missing class", "miss class", "tardi", "tardy"]),
    ]

    /// The course's policies that answer the phrase, best first: those of the kind it names, then those sharing its
    /// words. Empty when nothing does; all of the course's when the phrase says nothing to go on.
    public static func answers(_ phrase: String?, kind wanted: PolicyKind? = nil, in policies: [PolicySnapshot]) -> [PolicySnapshot] {
        let kind = wanted ?? phrase.flatMap(kind(of:))
        let words = phrase.map { Normalize.tokens($0).subtracting(stopWords) } ?? []
        if kind == nil && words.isEmpty { return policies }
        let scored = policies.map { policy -> (PolicySnapshot, Double) in
            var score = 0.0
            if let kind, policy.kind == kind { score += 2 }
            if !words.isEmpty {
                let text = Normalize.tokens(policy.text)
                score += Double(words.filter { word in text.contains { $0.hasPrefix(word) } }.count) / Double(words.count)
            }
            return (policy, score)
        }
        let best = scored.filter { $0.1 > 0.34 }.sorted { $0.1 > $1.1 }
        return best.map(\.0)
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "on", "for", "of", "in", "to", "is", "what", "whats", "s", "policy", "policies", "rule", "rules",
                                                 "about", "my", "class", "course", "say", "says", "does", "do", "can", "i", "it", "and", "or", "if", "with", "there"]

    /// What the kind is called aloud and on the page.
    public static func name(_ kind: PolicyKind) -> String {
        switch kind {
        case .lateWork: "Late work"
        case .makeupExam: "Makeup exams"
        case .attendance: "Attendance"
        case .dropRule: "Dropped scores"
        case .extraCredit: "Extra credit"
        case .other: "Other policies"
        }
    }
}
