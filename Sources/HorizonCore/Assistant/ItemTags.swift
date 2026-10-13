import Foundation
import IngestKit

/// An item's tags, as Siri's reminders schema carries them: the grade row it counts toward and the site it is handed
/// in on. The schema has no field for either, and Siri changes an item only through the schema's own fields, so
/// these two ride on its tags: "tag Calc's homework WebAssign" sets the site, "tag Quiz 3 Quizzes" the grade row. A tag
/// names a site by the site's own name, or a grade row by the course's words for it ("quiz" for Quizzes).
public enum ItemTags {
    /// The tags an item shows: its grade row and its site, when it has them.
    public static func tags(component: String?, platform: Platform) -> Set<String> {
        var tags: Set<String> = []
        if let component, !component.isEmpty { tags.insert(component) }
        if platform != .syllabusOnly { tags.insert(Coverage.platformName(platform)) }
        return tags
    }

    /// What a set of tags says: the grade row named among `rows`, the site named, and the tags that name neither.
    public struct Reading: Equatable, Sendable {
        public var component: String?
        public var platform: Platform?
        public var unknown: [String] = []
    }

    public static func read(_ tags: Set<String>, rows: [GradeComponent]) -> Reading {
        var reading = Reading()
        for tag in tags.sorted() {
            let words = tag.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#")))
            guard !words.isEmpty else { continue }
            if let platform = platform(named: words) { reading.platform = platform }
            else if let row = row(named: words, in: rows) { reading.component = row }
            else { reading.unknown.append(words) }
        }
        return reading
    }

    /// What an answer says of tags that name neither: "“urgent” is neither a grade row nor a site, so it was left off."
    public static func leftOff(_ unknown: [String]) -> String {
        let names = unknown.map { "“\($0)”" }
        let list = names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return unknown.count == 1 ? "\(list) is neither a grade row nor a site, so it was left off." : "\(list) are neither grade rows nor sites, so they were left off."
    }

    /// The grade row the words name: the row of that name, else the one its words fall under ("quiz" for Quizzes).
    public static func row(named words: String, in rows: [GradeComponent]) -> String? {
        rows.first { $0.name.caseInsensitiveCompare(words) == .orderedSame }?.name ?? ItemSeries.component(for: words, in: rows)
    }

    /// The site a name means: Horizon's own names for them, the systems a syllabus calls its LMS, Pearson's titles,
    /// and "none" (or "in class", "on paper") for no site at all.
    public static func platform(named name: String) -> Platform? {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "webassign": return .webAssign
        case "gradescope": return .gradescope
        case "mylab", "mylabs", "pearson", "pearsonmylab", "mastering", "mylabandmastering": return .myLab
        case "lms", "canvas", "blackboard", "blackboardlearn", "brightspace", "d2l", "moodle": return .lms
        case "none", "nosite", "inclass", "onpaper", "syllabus", "syllabusonly": return .syllabusOnly
        default: return nil
        }
    }
}
