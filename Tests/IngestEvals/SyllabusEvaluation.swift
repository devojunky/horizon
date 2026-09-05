import Foundation
import Testing
import Evaluations
import IngestKit

// Runs the parser over Evals/Fixtures and scores it with the Evaluations framework.
// Slow (model calls), so it only runs when HORIZON_EVALS is set:
//   HORIZON_EVALS=1 swift test --filter IngestEvals
// HORIZON_FIXTURE=<substring> limits the run to matching fixture folders. HORIZON_PCC=1 routes through Private Cloud Compute.
// A per-fixture table is printed and written to Evals/Results/latest.md next to the framework's JSON result.

struct FixtureSample: SampleProtocol {
    struct Input: CustomStringConvertible, Codable, Sendable {
        var name: String
        var path: String
        var description: String { name }
    }
    var input: Input
    var expected: FixtureShape?
}

struct SyllabusEvaluation: Evaluation {
    static let recall = Metric("recall")
    static let dateAccuracy = Metric("dateAccuracy")
    static let weightAccuracy = Metric("weightAccuracy")
    static let platformAccuracy = Metric("platformAccuracy")
    static let falsePositiveRate = Metric("falsePositiveRate")
    static let readyErrors = Metric("readyErrors")
    static let courseFound = Metric("courseFound")
    static let all = [recall, dateAccuracy, weightAccuracy, platformAccuracy, falsePositiveRate, readyErrors]

    var dataset: ArrayLoader<FixtureSample>
    var options: IngestOptions

    func subject(from sample: FixtureSample) async throws -> ModelSubject<FixtureShape> {
        do {
            let result = try await Ingestor(options: options).ingest(fileURL: URL(fileURLWithPath: sample.input.path))
            print("  \(sample.input.name): \(result.obligations.count) obligations, \(result.usage.inputTokens)/\(result.usage.outputTokens) tokens, \(result.usage.durationMs / 1000)s" + (result.warnings.isEmpty ? "" : ", warnings: \(result.warnings)"))
            return ModelSubject(value: result.fixtureShape())
        } catch {
            print("  \(sample.input.name): FAILED \(error)")
            throw error
        }
    }

    var evaluators: Evaluators {
        Evaluator<FixtureSample> { sample, subject in
            let s = Scoring.score(produced: subject.value, expected: sample.expected!)
            return Self.recall.scoring(s.recall, rationale: "\(s.matched)/\(s.expected) " + s.notes.filter { $0.hasPrefix("missed") || $0.hasPrefix("title") }.joined(separator: "; "))
        }
        Evaluator<FixtureSample> { sample, subject in
            let s = Scoring.score(produced: subject.value, expected: sample.expected!)
            return Self.dateAccuracy.scoring(s.dateAccuracy, rationale: s.notes.filter { $0.hasPrefix("date") }.joined(separator: "; "))
        }
        Evaluator<FixtureSample> { sample, subject in
            let s = Scoring.score(produced: subject.value, expected: sample.expected!)
            return Self.weightAccuracy.scoring(s.weightAccuracy, rationale: s.notes.filter { $0.hasPrefix("weight") || $0.hasPrefix("component") }.joined(separator: "; "))
        }
        Evaluator<FixtureSample> { sample, subject in
            let s = Scoring.score(produced: subject.value, expected: sample.expected!)
            return Self.platformAccuracy.scoring(s.platformAccuracy, rationale: s.notes.filter { $0.hasPrefix("platform") }.joined(separator: "; "))
        }
        Evaluator<FixtureSample> { sample, subject in
            let s = Scoring.score(produced: subject.value, expected: sample.expected!)
            return Self.falsePositiveRate.scoring(s.falsePositiveRate, rationale: s.notes.filter { $0.hasPrefix("spurious") }.joined(separator: "; "))
        }
        Evaluator<FixtureSample> { sample, subject in
            Self.readyErrors.scoring(Double(Scoring.score(produced: subject.value, expected: sample.expected!).readyErrors))
        }
        Evaluator<FixtureSample> { sample, subject in
            Scoring.score(produced: subject.value, expected: sample.expected!).courseFound ? Self.courseFound.passing() : Self.courseFound.failing()
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: Self.recall)
        aggregator.computeMinimum(of: Self.recall)
        aggregator.computeMean(of: Self.dateAccuracy)
        aggregator.computeMean(of: Self.weightAccuracy)
        aggregator.computeMean(of: Self.platformAccuracy)
        aggregator.computeMean(of: Self.falsePositiveRate)
        aggregator.computeMaximum(of: Self.readyErrors)
    }

    /// One markdown row per fixture with every metric and its rationale.
    func report(_ result: EvaluationResult, samples: [FixtureSample]) -> String {
        let detailed = result.detailed
        var lines = ["| fixture | recall | date | weight | platform | FP rate | ready errors | notes |", "|---|---|---|---|---|---|---|---|"]
        for (i, sample) in samples.enumerated() {
            let metrics = Self.all.map { detailed[metric: $0][i] }
            let cells = metrics.map { m -> String in m?.doubleValue.map { String(format: "%.2f", $0) } ?? "–" }
            let notes = metrics.compactMap { $0?.rationale }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
            lines.append("| \(sample.input.name) | " + cells.joined(separator: " | ") + " | \(notes.replacingOccurrences(of: "|", with: "/")) |")
        }
        lines.append("")
        lines.append(result.groupedSummary)
        return lines.joined(separator: "\n")
    }
}

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let dir = root.appendingPathComponent("Evals/Fixtures", isDirectory: true)
    static let results = root.appendingPathComponent("Evals/Results", isDirectory: true)

    static func load(filter: String? = nil) throws -> [FixtureSample] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath).sorted { $0.path < $1.path }.compactMap { folder in
            let name = folder.lastPathComponent
            if let filter, !name.contains(filter) { return nil }
            guard let source = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix("source.") && $0.pathExtension != "md" }) else {
                print("  \(name): no rendered source, run `swift Scripts/make-fixtures.swift`"); return nil
            }
            let expected = try JSONDecoder().decode(FixtureShape.self, from: Data(contentsOf: folder.appendingPathComponent("expected.json")))
            return FixtureSample(input: .init(name: name, path: source.path), expected: expected)
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["HORIZON_EVALS"] != nil, "set HORIZON_EVALS=1 to run model evals"))
struct IngestEvals {
    @Test func syllabusExtraction() async throws {
        let env = ProcessInfo.processInfo.environment
        var options = IngestOptions()
        options.route = env["HORIZON_PCC"] != nil ? .privateCloudCompute : .onDeviceOnly
        let samples = try Fixtures.load(filter: env["HORIZON_FIXTURE"])
        #expect(!samples.isEmpty)
        let evaluation = SyllabusEvaluation(dataset: ArrayLoader(samples: samples), options: options)
        let result = try await evaluation.run(info: ["route": "\(options.route)"])

        let report = "# Ingest evals — \(samples.count) fixtures, \(Int(result.duration))s, route \(options.route)\n\n" + evaluation.report(result, samples: samples)
        print("\n" + report)
        try FileManager.default.createDirectory(at: Fixtures.results, withIntermediateDirectories: true)
        try report.write(to: Fixtures.results.appendingPathComponent("latest.md"), atomically: true, encoding: .utf8)
        _ = try result.saveJSON(to: Fixtures.results)

        // Recall matters most; a spurious or wrong-dated item must never reach Reminders without review.
        #expect(result.aggregateValue(.mean(of: SyllabusEvaluation.recall)) >= 0.9)
        #expect(result.aggregateValue(.maximum(of: SyllabusEvaluation.readyErrors)) == 0)
    }
}
