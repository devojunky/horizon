import Foundation

struct TextChunk: Sendable {
    var index: Int
    var text: String
    var firstPage: Int
    var lastPage: Int
}

/// Packs page text into chunks that fit a token budget. Token cost is estimated from a
/// characters-per-token ratio calibrated against the real tokenizer; the extractor verifies each chunk.
enum Chunker {
    /// `pages` carries each text page with its index in the source document, so provenance survives image pages in between.
    static func chunks(pages: [(page: Int, text: String)], budgetTokens: Int, charsPerToken: Double) -> [TextChunk] {
        let budgetChars = Int(Double(budgetTokens) * charsPerToken)
        var out: [TextChunk] = []
        var current = "", first = 0, last = 0

        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(TextChunk(index: out.count, text: text, firstPage: first, lastPage: last)) }
            current = ""
        }

        for (pageIndex, page) in pages {
            for unit in units(page, maxChars: budgetChars) {
                if current.count + unit.count + 2 > budgetChars, !current.isEmpty { flush(); first = pageIndex }
                if current.isEmpty { first = pageIndex }
                current += (current.isEmpty ? "" : "\n\n") + unit
                last = pageIndex
            }
        }
        flush()
        return out
    }

    /// Split one chunk in two: at a paragraph boundary, else a line, else the whitespace nearest the middle.
    static func halve(_ chunk: TextChunk) -> [TextChunk]? {
        for separator in ["\n\n", "\n", " "] {
            let pieces = chunk.text.components(separatedBy: separator)
            guard pieces.count > 1 else { continue }
            let midpoint = pieces.count / 2
            let halves = [pieces[..<midpoint].joined(separator: separator), pieces[midpoint...].joined(separator: separator)]
            guard halves.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            return halves.map { TextChunk(index: chunk.index, text: $0, firstPage: chunk.firstPage, lastPage: chunk.lastPage) }
        }
        return nil
    }

    /// Paragraphs, with oversized paragraphs broken into line groups.
    private static func units(_ page: String, maxChars: Int) -> [String] {
        page.components(separatedBy: "\n\n").flatMap { paragraph -> [String] in
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return [] }
            guard p.count > maxChars else { return [p] }
            var groups: [String] = [], group = ""
            for line in p.components(separatedBy: "\n") {
                if group.count + line.count + 1 > maxChars, !group.isEmpty { groups.append(group); group = "" }
                group += (group.isEmpty ? "" : "\n") + line
            }
            if !group.isEmpty { groups.append(group) }
            return groups
        }
    }
}
