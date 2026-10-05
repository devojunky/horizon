import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// A document reduced to pages of either text (PDFKit/plain text) or raster images (screenshots, scanned pages). No
/// OCR of our own: Claude reads a picture and transcribes it (`PageReading`), which is what the deterministic guards in
/// `Merger` check against; the device model has the system's text tool. A PDF keeps its bytes so a text page can also
/// be shown to Claude as a picture, where the text layer garbles a table.
public struct NormalizedDocument: @unchecked Sendable {
    public var info: DocumentInfo
    public var pages: [Page]
    /// The PDF's bytes, for `pictures(ofPages:)`. Nil for anything but a PDF.
    var pdfData: Data?

    public enum Page {
        case text(String)
        case image(CGImage, orientation: CGImagePropertyOrientation?)
    }

    struct ImagePage { var page: Int; var image: CGImage; var orientation: CGImagePropertyOrientation? }
    /// A page as a picture, with its index in the document.
    struct Picture: @unchecked Sendable { var page: Int; var image: CGImage; var orientation: CGImagePropertyOrientation? }

    /// Text pages with their index in the document.
    var textPages: [(page: Int, text: String)] { pages.enumerated().compactMap { i, p in if case .text(let t) = p { (i, t) } else { nil } } }
    var imagePages: [ImagePage] {
        pages.enumerated().compactMap { i, p in if case .image(let img, let o) = p { ImagePage(page: i, image: img, orientation: o) } else { nil } }
    }
    /// The text pages, in page order. Pictures contribute nothing here; their transcripts arrive with the extraction.
    var fullText: String {
        pages.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
    }

    /// The text pages of a PDF in `range`, rendered as pictures about 1500 pixels on the long edge (a letter page at about
    /// 140 dpi: under the 1568 every model keeps whole; `Extractor.jpegData` has the rest). Empty for anything but a PDF,
    /// and for image pages, which are pictures already.
    func pictures(ofPages range: ClosedRange<Int>) -> [Picture] {
        guard let pdfData, let pdf = PDFDocument(data: pdfData) else { return [] }
        return range.compactMap { index -> Picture? in
            guard index < pdf.pageCount, case .text = pages[index], let page = pdf.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2, 1500 / max(bounds.width, bounds.height, 1))
            return DocumentNormalizer.rasterize(page, scale: scale).map { Picture(page: index, image: $0, orientation: nil) }
        }
    }
}

enum DocumentNormalizer {
    /// Pages whose text layer is shorter than this are treated as scanned and rasterized instead.
    static let minimumTextCharacters = 40
    static let rasterScale: CGFloat = 2.0

    static func normalize(fileURL: URL) throws -> NormalizedDocument {
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw IngestError.unreadable(error.localizedDescription) }
        let name = fileURL.lastPathComponent
        let type = UTType(filenameExtension: fileURL.pathExtension) ?? .data

        if type.conforms(to: .pdf) {
            guard let pdf = PDFDocument(data: data) else { throw IngestError.unreadable("PDFKit could not open \(name)") }
            // Every page keeps its place, so that a page's index here is its index in the PDF (`pictures(ofPages:)` draws
            // by it, and a page that dropped out put every later picture beside the wrong text): one that cannot be drawn
            // keeps what little text it has.
            var pages: [NormalizedDocument.Page] = []
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { pages.append(.text("")); continue }
                let text = collapseRepeats(page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                if text.count >= minimumTextCharacters {
                    pages.append(.text(text))
                } else if let image = rasterize(page) {
                    pages.append(.image(image, orientation: nil))
                } else {
                    pages.append(.text(text))
                }
            }
            if pages.allSatisfy({ if case .text(let t) = $0 { t.isEmpty } else { false } }) { pages = [] }   // nothing on any page: nothing to read
            return NormalizedDocument(info: info(name, data, .pdf, pdf.pageCount), pages: pages, pdfData: data)
        }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw IngestError.unreadable("ImageIO could not decode \(name)")
            }
            var orientation: CGImagePropertyOrientation?
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let raw = props[kCGImagePropertyOrientation] as? UInt32 {
                orientation = CGImagePropertyOrientation(rawValue: raw)
            }
            return NormalizedDocument(info: info(name, data, .image, 1), pages: [.image(image, orientation: orientation)])
        }
        if fileURL.pathExtension.lowercased() == "docx" {
            #if canImport(AppKit)
            let attributed = try NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            return normalize(text: attributed.string, name: name, kind: .docx, data: data)
            #else
            throw IngestError.unsupportedFile("docx (macOS only)")
            #endif
        }
        if type.conforms(to: .text) || type == .data, let text = String(data: data, encoding: .utf8) {
            return normalize(text: text, name: name, kind: .text, data: data)
        }
        throw IngestError.unsupportedFile(fileURL.pathExtension.isEmpty ? "unknown" : fileURL.pathExtension)
    }

    static func normalize(text: String, name: String, kind: DocumentKind = .text, data: Data? = nil) -> NormalizedDocument {
        let bytes = data ?? Data(text.utf8)
        // Split long plain text on form feeds or every ~60 lines so the chunker has page boundaries to work with.
        let pages = text.components(separatedBy: "\u{0C}").flatMap { block -> [String] in
            let lines = block.components(separatedBy: "\n")
            return stride(from: 0, to: max(lines.count, 1), by: 60).map { lines[$0..<min($0 + 60, lines.count)].joined(separator: "\n") }
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return NormalizedDocument(info: info(name, bytes, kind, max(pages.count, 1)), pages: pages.map { .text($0) })
    }

    static func normalize(image: CGImage, name: String) -> NormalizedDocument {
        let bytes = Data("\(name)-\(image.width)x\(image.height)".utf8)
        return NormalizedDocument(info: info(name, bytes, .image, 1), pages: [.image(image, orientation: nil)])
    }

    /// Some text layers repeat a line many times (overlaid glyph runs). Keep each line's first occurrence, and cut a
    /// phrase that repeats inside one line ("must be takenmust be taken…") down to one copy.
    static func collapseRepeats(_ text: String) -> String {
        var previous = ""
        return text.components(separatedBy: "\n").compactMap { raw -> String? in
            let line = collapseRepeatedPhrase(raw)
            let key = Normalize.key(line)
            defer { previous = key }
            return key.count > 12 && key == previous ? nil : line   // only a line repeating the one before it; a row that recurs later is content
        }.joined(separator: "\n")
    }

    /// "must be takenmust be takenmust be taken within…" → "must be taken within…": a phrase repeated back to back keeps
    /// one copy. A phrase of 20 characters or more needs only two copies (no prose repeats a clause of that length back to
    /// back), one of 8 to 19 three, a short word ("NoNoNoNo…") five. Every run in the line is collapsed, since a text
    /// layer can stutter twice on one line (a whole sentence seventeen times bloats a chunk past the model's context
    /// and buries what follows it).
    static func collapseRepeatedPhrase(_ line: String) -> String {
        var line = line
        while let collapsed = collapseFirstRepeat(in: line) { line = collapsed }
        return line
    }

    private static func collapseFirstRepeat(in line: String) -> String? {
        let chars = Array(line)
        guard chars.count >= 10 else { return nil }
        for start in 0..<(chars.count - 9) {   // anywhere in the line: a stutter can begin after a clean clause
            for length in 2...max(2, min(200, (chars.count - start) / 2)) {   // two copies must fit; shorter phrases need more
                let phrase = chars[start..<(start + length)]
                let letters = phrase.filter(\.isLetter).count
                guard letters >= (length < 8 ? 2 : 3) else { continue }   // words, not a run of "10%" cells
                var repeats = 1
                while start + (repeats + 1) * length <= chars.count, chars[(start + repeats * length)..<(start + (repeats + 1) * length)].elementsEqual(phrase) { repeats += 1 }
                if repeats >= (length < 8 ? 5 : length < 20 ? 3 : 2) {
                    return String(chars[..<start]) + String(phrase) + String(chars[(start + repeats * length)...])
                }
            }
        }
        return nil
    }

    private static func info(_ name: String, _ data: Data, _ kind: DocumentKind, _ pages: Int) -> DocumentInfo {
        DocumentInfo(name: name, sha256: Normalize.sha256(data), kind: kind, pageCount: pages, ingestedAt: Date())
    }

    static func rasterize(_ page: PDFPage, scale rasterScale: CGFloat = rasterScale) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * rasterScale), height = Int(bounds.height * rasterScale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: rasterScale, y: rasterScale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
