import Foundation
import IngestKit

/// What a question about a course is after ("how is Calc graded?", "who teaches Bio?", "can I hand in late?"): how its
/// grade is made up, the course itself (who teaches it, the term, where it meets), or one of its policies
/// (`PolicyLookup`, which is asked first: "late" names a policy before anything else).
public enum CourseQuestion: Equatable, Sendable {
    case grading
    case overview
    case policy(PolicyKind)

    public static func topic(of phrase: String) -> CourseQuestion? {
        if let kind = PolicyLookup.kind(of: phrase) { return .policy(kind) }
        let key = " " + Normalize.key(phrase) + " "
        if gradingCues.contains(where: { key.contains(" \($0)") }) { return .grading }
        if overviewCues.contains(where: { key.contains(" \($0)") }) { return .overview }
        return nil
    }

    private static let gradingCues = ["grade", "grading", "graded", "weight", "worth", "breakdown", "percent", "how much"]
    private static let overviewCues = ["teach", "instructor", "professor", "prof ", "teacher", "lecturer", "office hour", "email", "room", "meet",
                                       "where is", "when is", "term", "semester", "about the course", "overview", "details"]
}
