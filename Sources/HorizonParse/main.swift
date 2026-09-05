import Foundation
import IngestKit

// horizon-parse: feed it a course document, get structured JSON. No storage, no UI.

let usage = """
usage: horizon-parse <file> [options]
  file                 .pdf, .png/.jpg/.heic, .txt/.md, .docx
  --pcc                use Private Cloud Compute (32k context, one pass)
  --on-device          never fall back to Private Cloud Compute
  --year YYYY          year for undated-year dates when the document names no term
  --term-start YYYY-MM-DD
  --threshold 0.7      review threshold for confidence
  --verbose            progress and token usage on stderr
  --compact            single-line JSON
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") { print(usage); exit(args.isEmpty ? 2 : 0) }

var options = IngestOptions()
var path: String?
var compact = false
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--pcc": options.route = .privateCloudCompute
    case "--on-device": options.route = .onDeviceOnly
    case "--verbose": options.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    case "--compact": compact = true
    case "--year":
        guard let v = args.first.flatMap(Int.init) else { fail("--year needs a number", code: 2) }
        args.removeFirst(); options.defaultYear = v
    case "--term-start":
        let parts = (args.first ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let d = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { fail("--term-start needs YYYY-MM-DD", code: 2) }
        args.removeFirst(); options.termStart = d
    case "--threshold":
        guard let v = args.first.flatMap(Double.init) else { fail("--threshold needs a number", code: 2) }
        args.removeFirst(); options.reviewThreshold = v
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)\n\(usage)", code: 2) }
        path = a
    }
}
guard let path else { fail(usage, code: 2) }

let url = URL(fileURLWithPath: path)
let result: IngestResult
do {
    result = try await Ingestor(options: options).ingest(fileURL: url)
} catch {
    fail("error: \(error.localizedDescription)")
}

let encoder = JSONEncoder()
encoder.outputFormatting = compact ? [.sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .custom { date, enc in
    let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
    var c = enc.singleValueContainer(); try c.encode(f.string(from: date))
}
print(String(decoding: try encoder.encode(result), as: UTF8.self))
