import Foundation
import CoreGraphics
import CoreText
import Testing
@testable import IngestKit

struct NormalizerTests {
    static let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("IngestKitTests-\(UUID().uuidString)", isDirectory: true)

    /// A one-page PDF with a real text layer, or an image-only page when `scanned`.
    static func makePDF(_ text: String, scanned: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent(UUID().uuidString + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
        let attributed = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(), CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil), nil)
        ctx.beginPDFPage(nil)
        if scanned {
            let bmp = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bmp.setFillColor(.white); bmp.fill(box); CTFrameDraw(frame, bmp)
            ctx.draw(bmp.makeImage()!, in: box)
        } else {
            CTFrameDraw(frame, ctx)
        }
        ctx.endPDFPage(); ctx.closePDF()
        return url
    }

    @Test func pdfWithTextLayerYieldsText() throws {
        let doc = try DocumentNormalizer.normalize(fileURL: Self.makePDF("MA-UY 1124 Calculus II. Homework 1 due Wednesday, September 9, 2026 on WebAssign.", scanned: false))
        #expect(doc.info.kind == .pdf && doc.info.pageCount == 1 && doc.info.sha256.count == 64)
        #expect(doc.textPages.count == 1 && doc.fullText.contains("September 9, 2026"))
    }

    @Test func scannedPDFYieldsImageWithOCRText() throws {
        let doc = try DocumentNormalizer.normalize(fileURL: Self.makePDF("Scanned syllabus page. Midterm 1 on Wednesday, October 7, 2026.", scanned: true))
        #expect(doc.textPages.isEmpty && doc.pages.count == 1 && doc.imagePages.count == 1)
        if case .image(let image, _, let ocr) = doc.pages[0] {
            #expect(image.width == 1224)
            #expect(ocr.contains("October 7") && doc.fullText.contains("Midterm 1"))   // Vision OCR feeds the source-text guards
        } else { Issue.record("expected an image page") }
    }

    @Test func plainTextSplitsIntoPagesAndHashesStably() throws {
        let a = DocumentNormalizer.normalize(text: (1...130).map { "line \($0)" }.joined(separator: "\n"), name: "a.txt")
        #expect(a.pages.count == 3 && a.info.kind == .text)
        let b = DocumentNormalizer.normalize(text: "same", name: "x"), c = DocumentNormalizer.normalize(text: "same", name: "y")
        #expect(b.info.sha256 == c.info.sha256)
    }

    @Test func unsupportedAndMissingFiles() throws {
        #expect(throws: IngestError.self) { try DocumentNormalizer.normalize(fileURL: URL(fileURLWithPath: "/nonexistent/file.pdf")) }
        try FileManager.default.createDirectory(at: Self.tmp, withIntermediateDirectories: true)
        let movie = Self.tmp.appendingPathComponent("clip.mp4")
        try Data([0, 1, 2, 3]).write(to: movie)
        #expect(throws: IngestError.self) { try DocumentNormalizer.normalize(fileURL: movie) }
        let binary = Self.tmp.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: binary)
        #expect(throws: IngestError.self) { try DocumentNormalizer.normalize(fileURL: binary) }   // not UTF-8, not silently Latin-1
    }

    @Test func docxYieldsText() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals/Fixtures/06-writing-essay-docx/source.docx")
        let doc = try DocumentNormalizer.normalize(fileURL: url)
        #expect(doc.info.kind == .docx && doc.fullText.contains("Progression 1 Final Essay due Monday, October 5"))
    }

    @Test func repeatedLinesCollapse() {
        let text = "Exams\nmust be taken within one week of the original exam date\nmust be taken within one week of the original exam date\nmust be taken within one week of the original exam date\nmust be takenmust be takenmust be takenmust be taken within a week\nExam 1 Tuesday, October 6th, 2026\n1\n1"
        // A whole sentence stuttered seventeen times, twice on one line, and a short word run.
        let sentence = "Makeups will not be granted to students who do not notify the Math Department in a timely manner."
        let stuttered = "Students will be allowed a maximum of one make-up exam" + String(repeating: "a maximum of one make-up exam", count: 16) + " throughout the semester. " + String(repeating: sentence, count: 17) + " For medical reasons"
        let once = DocumentNormalizer.collapseRepeatedPhrase(stuttered)
        #expect(once == "Students will be allowed a maximum of one make-up exam throughout the semester. " + sentence + " For medical reasons")
        #expect(DocumentNormalizer.collapseRepeatedPhrase(String(repeating: "No", count: 17) + " calculators will be allowed for exams.") == "No calculators will be allowed for exams.")
        #expect(DocumentNormalizer.collapseRepeatedPhrase("10% 10% 10% 10% 10% 10%") == "10% 10% 10% 10% 10% 10%")   // cells, not a stutter
        #expect(DocumentNormalizer.collapseRepeatedPhrase("request a make-up exam within two days of the missed exam within two days of the missed exam.") == "request a make-up exam within two days of the missed exam.")   // a long clause twice
        #expect(DocumentNormalizer.collapseRepeatedPhrase("the the the") == "the the the")   // short and only thrice: prose
        let collapsed = DocumentNormalizer.collapseRepeats(text)
        #expect(collapsed.components(separatedBy: "\n").filter { $0.hasPrefix("must be taken within one week") }.count == 1)
        #expect(collapsed.contains("must be taken within a week") && !collapsed.contains("must be takenmust be taken"))
        #expect(collapsed.contains("Exam 1 Tuesday, October 6th, 2026") && collapsed.components(separatedBy: "\n").filter { $0 == "1" }.count == 2)   // short lines are left alone
    }

    @Test func keysAndSimilarity() {
        #expect(Normalize.key("  Midterm 1: Wednesday, Oct. 7!  ") == "midterm 1 wednesday oct 7")
        #expect(Normalize.numbers("Homework 12 (v2)") == ["12"])
        #expect(Normalize.collapseWhitespace("a  b\n\tc") == "a b c")
    }
}
