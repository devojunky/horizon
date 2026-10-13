import Foundation
import IngestKit

/// How well what someone said or typed names a course: "Calc" and "calculus 2" name Calculus II, "MA 1124" names
/// MA-UY 1124, "OB" names Organizational Behavior. Siri and Shortcuts hand the App Intents' course lookups a phrase,
/// never an id; the semantic index does the rest of the work for Siri.
public enum CourseMatch {
    /// 0 when the phrase does not name the course; 1 for its exact name or code.
    public static func score(_ phrase: String, name: String, code: String) -> Double {
        let query = words(phrase)
        guard !query.isEmpty else { return 0 }
        let title = words(name), number = words(code)
        if query == title || (!number.isEmpty && query == number) { return 1 }
        let squeezed = query.joined()
        if !number.isEmpty, squeezed == number.joined() { return 0.95 }   // "ma1124", "MA 1124" for "MA-UY 1124" once its school's letters are dropped
        if !number.isEmpty, number.filter({ $0.contains(where: \.isNumber) }).joined() == squeezed.filter(\.isNumber), squeezed.contains(where: \.isNumber),
           query.allSatisfy({ word in number.contains { $0.hasPrefix(word) || word.allSatisfy(\.isNumber) } }) { return 0.9 }
        if let prefix = prefixes(query, of: title) { return 0.7 + 0.2 * prefix }   // "calc 2", "org behav"
        if !title.isEmpty, title.count > 1, query.count == 1, query[0].count == title.count, zip(query[0], title).allSatisfy({ $0 == $1.first }) { return 0.6 }   // initials
        if title.contains(where: { word in query.contains(word) }) { return 0.3 }   // a word of it, anywhere
        return 0
    }

    /// The courses the phrase names, best first.
    public static func ranked(_ phrase: String, in courses: [CourseSnapshot]) -> [CourseSnapshot] {
        courses.map { ($0, score(phrase, name: $0.title, code: $0.code)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The phrase's words, lowercased, with a course's roman numerals as figures ("II" and "2" are the same course).
    static func words(_ s: String) -> [String] {
        Normalize.key(s).split(separator: " ").map { word in numerals[String(word)] ?? String(word) }
    }

    private static let numerals = ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "one": "1", "two": "2", "three": "3", "four": "4"]

    /// Each query word the start of a different title word, in order: the share of the title's words they cover, or
    /// nil when some word fits none.
    private static func prefixes(_ query: [String], of title: [String]) -> Double? {
        var at = 0
        for word in query {
            guard let found = title[at...].firstIndex(where: { $0.hasPrefix(word) }) else { return nil }
            at = found + 1
        }
        return Double(query.count) / Double(max(title.count, 1))
    }
}
