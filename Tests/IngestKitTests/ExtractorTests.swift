import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import IngestKit

/// The Claude read of one chunk against a scripted network: what is sent with the pictures, what a request too large
/// does, and that a call with nothing to keep is still counted.
struct ExtractorTests {
    typealias Script = ClaudeClientTests.Script

    static func extractor(_ script: Script) async throws -> Extractor {
        try await Extractor.make(route: .claude, claude: ClaudeConfiguration(apiKey: "sk-ant-test"), transport: script.transport, sampleText: "", log: { _ in })
    }

    /// A blank page as big as a scan, so the size it is sent at shows in the request.
    static func page(_ index: Int) -> NormalizedDocument.Picture {
        let ctx = CGContext(data: nil, width: 2000, height: 2600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 2600))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 100, y: 100 + index * 50, width: 1800, height: 40))
        return NormalizedDocument.Picture(page: index, image: ctx.makeImage()!, orientation: nil)
    }

    static let reply = ClaudeClientTests.whole(#"{"gradeComponents": [], "obligations": [{"title": "HW 1", "platform": "not_stated", "dateAsWritten": "Wed 9/9", "confidence": "high"}], "policies": [], "noClassDates": []}"#)
    static let tooLarge = ClaudeClientTests.Step.reply(status: 413, lines: [#"{"type": "error", "error": {"type": "request_too_large", "message": "Request exceeds the maximum size"}}"#])

    /// The pictures one request carried: each label, and the long edge of the picture after it.
    static func pictures(_ request: URLRequest) -> [(label: String, edge: Int)] {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody!)) as? [String: Any]
        let content = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        var out: [(String, Int)] = [], label = ""
        for block in content {
            if block["type"] as? String == "text" { label = block["text"] as? String ?? "" }
            guard block["type"] as? String == "image", let data = ((block["source"] as? [String: Any])?["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            out.append((label, max(image.width, image.height)))
        }
        return out
    }

    @Test func aRequestTooLargeTriesSmallerPicturesThenSplitsWithEachHalfsOwn() async throws {
        let script = Script([Self.tooLarge, Self.tooLarge, .reply(status: 200, lines: Self.reply), .reply(status: 200, lines: Self.reply)])
        let chunks = Chunker.chunks(pages: [(0, "Week 1: HW 1 due Wed 9/9."), (1, "Week 2: HW 2 due Wed 9/16.")], budgetTokens: 60_000, charsPerToken: 3.5)
        #expect(chunks.count == 1 && chunks[0].firstPage == 0 && chunks[0].lastPage == 1)
        let outcomes = try await Self.extractor(script).extract(chunks[0], pictures: [Self.page(0), Self.page(1)], context: RollingContext(), document: "calc.pdf", chunkCount: 1)
        #expect(outcomes.count == 2 && script.sent.count == 4)
        let sent = script.sent.map(Self.pictures)
        #expect(sent[0].map(\.label) == ["Page 1", "Page 2"] && sent[0].allSatisfy { $0.edge == Extractor.pictureEdge })   // every page, labelled by its number
        #expect(sent[1].map(\.label) == ["Page 1", "Page 2"] && sent[1].allSatisfy { $0.edge == Extractor.smallPictureEdge })   // the same pages, smaller
        #expect(sent[2].map(\.label) == ["Page 1"] && sent[3].map(\.label) == ["Page 2"])                                   // then each half its own page only
    }

    @Test func aCallWithNothingToKeepIsStillCounted() async throws {
        let refusal = [ClaudeClientTests.event("message_start", "\"message\": {\"usage\": {\"input_tokens\": 900}}"),
                       ClaudeClientTests.event("message_delta", "\"delta\": {\"stop_reason\": \"refusal\"}, \"usage\": {\"output_tokens\": 3}"), ClaudeClientTests.event("message_stop")]
        let script = Script([.reply(status: 200, lines: refusal)])
        let extractor = try await Self.extractor(script)
        let chunk = TextChunk(index: 0, text: "Week 1: HW 1 due Wed 9/9.", firstPage: 0, lastPage: 0)
        let outcomes = try await extractor.extract(chunk, context: RollingContext(), document: "calc.txt", chunkCount: 1)
        let unkept = await extractor.unkept
        #expect(outcomes.isEmpty && unkept.count == 1 && unkept[0].inputTokens == 900 && unkept[0].outputTokens == 3)
        #expect(await extractor.warnings.contains { $0.hasSuffix("the model declined") })
    }

    @Test func readingSendsNoThinking() async throws {
        let script = Script([.reply(status: 200, lines: Self.reply)])
        _ = try await Self.extractor(script).extract(TextChunk(index: 0, text: "HW 1 due Wed 9/9.", firstPage: 0, lastPage: 0), context: RollingContext(), document: "calc.txt", chunkCount: 1)
        #expect((script.body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }
}

/// What a read that stops keeps of itself.
struct CheckpointTests {
    @Test func aCheckpointKeepsFinishedPartsForTheSameRead() throws {
        var checkpoint = IngestCheckpoint(route: .onDevice, textChunks: 3, images: 1)
        #expect(!checkpoint.applies(route: .onDevice, textChunks: 3, images: 1))   // nothing finished yet: nothing to resume
        let facts = ChunkExtraction(course: nil, gradeComponents: [], obligations: [ObligationFacts(title: "HW 1", platform: "not_stated", component: nil, dateAsWritten: "Wed 9/9", dueDate: "2026-09-09", confidence: "high")], policies: [], noClassDates: [])
        let usage = UsageRecord(step: "text", chunk: 0, route: .onDevice, inputTokens: 10, cachedTokens: 0, outputTokens: 5, reasoningTokens: 0, durationMs: 100)
        checkpoint.record(index: 0, outcomes: [ExtractionOutcome(kind: .text, page: 0, extraction: facts, usage: usage)])
        checkpoint.record(index: 1, outcomes: [])                                   // a part the model had nothing for is finished too
        #expect(checkpoint.finishedParts == 2 && checkpoint.totalParts == 4)
        #expect(checkpoint.applies(route: .onDevice, textChunks: 3, images: 1))
        #expect(!checkpoint.applies(route: .claude, textChunks: 3, images: 1))     // another route chunks differently
        #expect(!checkpoint.applies(route: .onDevice, textChunks: 4, images: 1))   // so does another build
        let round = try IngestCheckpoint(data: checkpoint.encoded())
        #expect(round == checkpoint && round.entry(at: 0)?.outcomes.first?.extraction.obligations.first?.title == "HW 1" && round.entry(at: 1)?.outcomes.isEmpty == true && round.entry(at: 2) == nil)
    }
}
