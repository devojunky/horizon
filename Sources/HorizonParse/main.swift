import Foundation
import IngestKit

// horizon-parse: feed it a course document, get structured JSON. No storage, no UI.

let usage = """
usage: horizon-parse <file> [options]
  file                 .pdf, .png/.jpg/.heic, .txt/.md, .docx
  --claude             read with Claude (the default when a key is found: ANTHROPIC_API_KEY, else claude_api_key.secret beside the package)
  --model sonnet5      which Claude: sonnet5, opus5, haiku45
  --on-device          read with the device model instead
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
var model = ClaudeModelChoice.default
var askedClaude = false
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--claude": options.route = .claude; askedClaude = true
    case "--on-device": options.route = .onDevice
    case "--model":
        guard let v = args.first.flatMap({ name in ClaudeModelChoice.allCases.first { "\($0)" == name } }) else { fail("--model needs sonnet5, opus5 or haiku45", code: 2) }
        args.removeFirst(); model = v
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
if options.route == .claude {
    // The key from the environment, else the git-ignored file beside the package. Never printed.
    let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let candidates = [FileManager.default.currentDirectoryPath, file.path].map { URL(fileURLWithPath: $0).appendingPathComponent("claude_api_key.secret") }
    let fromFile = candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fromFile ?? ""
    if key.isEmpty {
        if askedClaude { fail("no Claude key: set ANTHROPIC_API_KEY or write claude_api_key.secret", code: 2) }
        options.route = .onDevice   // no key, nothing asked for: the device reads
    } else {
        options.claude = ClaudeConfiguration(apiKey: key, model: model)
    }
}

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
