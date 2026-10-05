// Renders Evals/Fixtures/*/source.md into that fixture's source document.
// The "render" key in expected.json picks the format: pdf (text layer) | scanned (image-only pdf) | png | docx | txt.
// Run: swift Scripts/make-fixtures.swift
// Fixtures with no source.md (16-19, the user's real documents) are kept as given and skipped.
import AppKit
import CoreText
import UniformTypeIdentifiers

let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Evals/Fixtures", isDirectory: true)
let page = CGRect(x: 0, y: 0, width: 612, height: 792)
let margin: CGFloat = 54
let scale: CGFloat = 2

func attributed(_ markdown: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let body = NSFont(name: "Helvetica", size: 11)!, mono = NSFont(name: "Menlo", size: 9)!
    let h1 = NSFont(name: "Helvetica-Bold", size: 17)!, h2 = NSFont(name: "Helvetica-Bold", size: 12.5)!
    let para = NSMutableParagraphStyle(); para.paragraphSpacing = 3
    let monoPara = NSMutableParagraphStyle(); monoPara.paragraphSpacing = 0
    var inFence = false
    for line in markdown.components(separatedBy: "\n") {
        if line.hasPrefix("```") { inFence.toggle(); continue }
        var font = body, style = para, text = line
        if inFence { font = mono; style = monoPara }
        else if line.hasPrefix("# ") { font = h1; text = String(line.dropFirst(2)) }
        else if line.hasPrefix("## ") { font = h2; text = String(line.dropFirst(3)) }
        out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.black]))
    }
    return out
}

func frames(_ text: NSAttributedString, height: CGFloat) -> [CTFrame] {
    let setter = CTFramesetterCreateWithAttributedString(text)
    let path = CGPath(rect: CGRect(x: margin, y: margin, width: page.width - 2 * margin, height: height), transform: nil)
    var start = 0, result: [CTFrame] = []
    while start < text.length {
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        if visible.length == 0 { break }
        result.append(frame); start += visible.length
    }
    return result
}

func bitmap(_ frame: CTFrame, height: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(page.width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: page.width * scale, height: height * scale))
    ctx.scaleBy(x: scale, y: scale)
    CTFrameDraw(frame, ctx)
    return ctx.makeImage()!
}

func writePDF(_ text: NSAttributedString, to url: URL, scanned: Bool) {
    var box = page
    let ctx = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
    for frame in frames(text, height: page.height - 2 * margin) {
        ctx.beginPDFPage(nil)
        if scanned { ctx.draw(bitmap(frame, height: page.height), in: box) }
        else { ctx.setFillColor(.white); ctx.fill(box); CTFrameDraw(frame, ctx) }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func writePNG(_ text: NSAttributedString, to url: URL) {
    let setter = CTFramesetterCreateWithAttributedString(text)
    let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: page.width - 2 * margin, height: 100_000), nil)
    let frame = frames(text, height: ceil(needed.height) + 8)[0]
    let image = bitmap(frame, height: ceil(needed.height) + 8 + 2 * margin)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
for dir in try fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath).sorted(by: { $0.path < $1.path }) {
    guard let markdown = try? String(contentsOf: dir.appendingPathComponent("source.md"), encoding: .utf8) else { continue }
    let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("expected.json"))) as! [String: Any]
    let render = expected["render"] as? String ?? "pdf"
    for ext in ["pdf", "png", "docx", "txt"] { try? fm.removeItem(at: dir.appendingPathComponent("source." + ext)) }
    let text = attributed(markdown)
    switch render {
    case "pdf": writePDF(text, to: dir.appendingPathComponent("source.pdf"), scanned: false)
    case "scanned": writePDF(text, to: dir.appendingPathComponent("source.pdf"), scanned: true)
    case "png": writePNG(text, to: dir.appendingPathComponent("source.png"))
    case "docx":
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: dir.appendingPathComponent("source.docx"))
    case "txt": try markdown.write(to: dir.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    default: fatalError("unknown render \(render) in \(dir.lastPathComponent)")
    }
    print("\(dir.lastPathComponent): \(render)")
}
