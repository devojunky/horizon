import Foundation
import CryptoKit

public enum Normalize {
    /// Lowercased, punctuation stripped, whitespace collapsed. Used for fuzzy keys.
    public static func key(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastSpace = true
        for ch in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch); lastSpace = false
            } else if !lastSpace {
                out.append(" "); lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Abbreviations that documents and ground truth use interchangeably.
    static let canonical: [String: [String]] = [
        "hw": ["homework"], "hwk": ["homework"], "hmwk": ["homework"], "ps": ["problem", "set"], "pset": ["problem", "set"],
        "asgn": ["assignment"], "assn": ["assignment"], "proj": ["project"], "mt": ["midterm"], "rp": ["response", "paper"],
    ]

    public static func tokens(_ s: String) -> Set<String> {
        Set(key(s).split(separator: " ").flatMap { canonical[String($0)] ?? [String($0)] })
    }

    static func numbers(_ s: String) -> Set<String> {
        Set(key(s).split(separator: " ").filter { $0.allSatisfy(\.isNumber) }.map(String.init))
    }

    /// Token Jaccard similarity; 0 when numbers are present on both sides and disjoint ("Homework 3" vs "Homework 4").
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let na = numbers(a), nb = numbers(b)
        if !na.isEmpty, !nb.isEmpty, na.isDisjoint(with: nb) { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
