import Testing
@testable import IngestKit

struct ChunkerTests {
    @Test func packsParagraphsWithinBudget() {
        let pages = [(1...6).map { "Paragraph \($0) " + String(repeating: "x", count: 90) }.joined(separator: "\n\n"), "Second page paragraph"]
        let chunks = Chunker.chunks(pages: [(0, pages[0]), (2, pages[1])], budgetTokens: 100, charsPerToken: 2.5)   // 250 chars per chunk; page 1 is an image
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.text.count <= 250 })
        #expect(chunks.map(\.index) == [0, 1, 2])
        #expect(chunks.last!.text.hasSuffix("Second page paragraph") && chunks.last?.firstPage == 0 && chunks.last?.lastPage == 2)   // real document page index
        #expect(chunks.first!.text.hasPrefix("Paragraph 1") && chunks.first!.text.contains("Paragraph 2"))
    }

    @Test func splitsOversizedParagraphByLine() {
        let page = (1...10).map { "line \($0) " + String(repeating: "y", count: 40) }.joined(separator: "\n")
        let chunks = Chunker.chunks(pages: [(0, page)], budgetTokens: 40, charsPerToken: 2.5)   // 100 chars
        #expect(chunks.count >= 5)
        #expect(chunks.allSatisfy { $0.text.count <= 100 })
    }

    @Test func halveSplitsAtParagraphs() {
        let chunk = TextChunk(index: 3, text: "a\n\nb\n\nc\n\nd", firstPage: 0, lastPage: 0)
        let halves = Chunker.halve(chunk)!
        #expect(halves.map(\.text) == ["a\n\nb", "c\n\nd"] && halves.allSatisfy { $0.index == 3 })
        #expect(Chunker.halve(TextChunk(index: 0, text: "single", firstPage: 0, lastPage: 0)) == nil)
        #expect(Chunker.halve(TextChunk(index: 0, text: "one long line with spaces only", firstPage: 0, lastPage: 0))?.map(\.text) == ["one long line", "with spaces only"])
    }
}
