import Foundation
import IngestKit

// horizon-parse: feed it a course document, get structured JSON. No storage, no UI.

let usage = """
usage: horizon-parse <file> [options]
  file                 .pdf, .png/.jpg/.heic, .txt/.md, .docx
  --claude             read with Claude (the default when a key is found: ANTHROPIC_API_KEY, else claude_api_key.secret at the package root)
  --model sonnet       which Claude: sonnet, opus, haiku (the 5.5 models)
  --on-device          read with the device model instead
  --year YYYY          year for undated-year dates when the document names no term
  --term-start YYYY-MM-DD
  --threshold 0.7      review threshold for confidence
  --title              only name the document (the device model, from its first lines) and print the title
  --verbose            progress and token usage on stderr
  --compact            single-line JSON
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// The Claude key: ANTHROPIC_API_KEY when it holds one (set but empty is not set), else the git-ignored
/// claude_api_key.secret at the package root: the nearest folder holding Package.swift above the working directory, or
/// above the binary (.build/debug/horizon-parse). Never printed.
func claudeKey() -> String? {
    if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for start in [URL(fileURLWithPath: FileManager.default.currentDirectoryPath), binary] {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let key = (try? String(contentsOf: dir.appendingPathComponent("claude_api_key.secret"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let key, !key.isEmpty { return key }
                break   // the package root has no key: not a parent package's
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
    }
    return nil
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") { print(usage); exit(args.isEmpty ? 2 : 0) }

var options = IngestOptions()
var path: String?
var compact = false
var model = ClaudeModelChoice.default
var askedClaude = false
var titleOnly = false
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--claude": options.route = .claude; askedClaude = true
    case "--on-device": options.route = .onDevice
    case "--model":
        guard let v = args.first.flatMap({ name in ClaudeModelChoice.allCases.first { "\($0)" == name } }) else { fail("--model needs sonnet, opus or haiku", code: 2) }
        args.removeFirst(); model = v
    case "--verbose": options.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    case "--compact": compact = true
    case "--title": titleOnly = true
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
if titleOnly {
    let file = URL(fileURLWithPath: path)
    switch await Ingestor.title(fileURL: file, request: DocumentTitleRequest(filename: file.lastPathComponent), log: options.log) {
    case .titled(let title): print(title); exit(0)
    case .nothing: fail("no title worth keeping; the app would show: \(DocumentName.tidy(file.lastPathComponent))")
    case .unavailable: fail("the device model is not available to name it")
    case .notYet: fail("nothing to name it from yet: a picture is named from what is read of it; the app would show: \(DocumentName.tidy(file.lastPathComponent))")
    }
}
if options.route == .claude {
    let key = claudeKey() ?? ""
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
