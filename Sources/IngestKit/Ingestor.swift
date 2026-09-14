import Foundation
import CoreGraphics

public struct IngestOptions: Sendable {
    public enum RoutePolicy: Sendable, Equatable {
        /// Claude, with `claude`: the target. The whole document in one or two calls, its pages attached as pictures so
        /// tables are read as printed. Cannot be reached → `IngestError.claudeUnavailable`; nothing falls back by itself.
        case claude
        /// The device's own model: small context, chunked reads, no eye for tables. The user's choice, or the fallback
        /// they confirm for one document when Claude cannot be reached.
        case onDevice
    }
    public var route: RoutePolicy = .claude
    public var claude: ClaudeConfiguration?
    /// What is already known about the course this document belongs to (from its syllabus, or the user's hand): seeds the
    /// prompt, the grade components and the term dates, so a schedule that names none of them still resolves.
    public var knownCourse: KnownCourse?
    /// Year for dates when the document names no term. Defaults to the current year. A term label like "Spring 2027" wins.
    public var defaultYear: Int?
    /// Overrides the term start used for week-relative dates and term bounds.
    public var termStart: Date?
    public var calendar: Calendar = .current
    /// Obligations below this confidence are marked `.needsReview`.
    public var reviewThreshold: Double = 0.7
    public var log: @Sendable (String) -> Void = { _ in }
    /// Receives progress as the document is read, including partial obligations while the model streams.
    public var progress: @Sendable (IngestEvent) -> Void = { _ in }
    /// Where an earlier read of this document stopped: its finished parts are reused, the rest read.
    public var resume: IngestCheckpoint?
    /// Told where the read stands after every finished part, so the caller can keep it for a read that stops.
    public var checkpoint: (@Sendable (IngestCheckpoint) async -> Void)?

    public init() {}
}

/// A course the caller already knows, handed to the parser with a document that may not name it.
public struct KnownCourse: Sendable, Equatable {
    public var code: String?
    public var title: String?
    public var term: String?
    public var termStart: Date?
    public var termEnd: Date?
    public var components: [KnownComponent]
    public init(code: String? = nil, title: String? = nil, term: String? = nil, termStart: Date? = nil, termEnd: Date? = nil, components: [KnownComponent] = []) {
        self.code = code; self.title = title; self.term = term; self.termStart = termStart; self.termEnd = termEnd; self.components = components
    }
}

public struct KnownComponent: Sendable, Equatable {
    public var name: String
    /// Fraction of the final grade, 0…1.
    public var weight: Double?
    public var expectedCount: Int?
    public var cadence: Cadence?
    public var platform: Platform?
    public init(name: String, weight: Double? = nil, expectedCount: Int? = nil, cadence: Cadence? = nil, platform: Platform? = nil) {
        self.name = name; self.weight = weight; self.expectedCount = expectedCount; self.cadence = cadence; self.platform = platform
    }
}

/// Points of the final grade one item is worth: the component's weight over how many of it there are (a stated count,
/// else the rhythm over the term, else what is on file). Shared by the parser and the store, which recomputes per course.
public enum PointsAtStake {
    public static func perItem(weight: Double, expectedCount: Int?, cadence: Cadence?, termStart: Date?, termEnd: Date?, onFile: Int) -> Double? {
        let expected = expectedCount ?? impliedCount(cadence, termStart: termStart, termEnd: termEnd) ?? onFile
        guard expected > 0 else { return nil }
        return (weight * 100 / Double(expected) * 100).rounded() / 100
    }

    public static func impliedCount(_ cadence: Cadence?, termStart: Date?, termEnd: Date?) -> Int? {
        guard let cadence else { return nil }
        if cadence == .once { return 1 }
        guard let termStart, let termEnd, termEnd > termStart else { return nil }
        let weeks = max(1, Int(termEnd.timeIntervalSince(termStart) / (7 * 86400)))
        return cadence == .weekly ? weeks : max(1, weeks / 2)
    }
}

/// Which grade component an item counts toward, from its name alone ("PS 3" → "Problem Sets"), for items filed under a
/// course after they were read.
public enum ComponentNames {
    public static func infer(title: String, among names: [String]) -> String? { Merger.componentName(forTitle: title, among: names) }
}

/// Documents in, structured obligations out. Pure: no storage, no EventKit.
public actor Ingestor {
    public let options: IngestOptions

    public init(options: IngestOptions = IngestOptions()) { self.options = options }

    public func ingest(fileURL: URL) async throws -> IngestResult {
        try await ingest(document: DocumentNormalizer.normalize(fileURL: fileURL))
    }

    public func ingest(text: String, name: String) async throws -> IngestResult {
        try await ingest(document: DocumentNormalizer.normalize(text: text, name: name))
    }

    public func ingest(image: CGImage, name: String) async throws -> IngestResult {
        try await ingest(document: DocumentNormalizer.normalize(image: image, name: name))
    }

    /// Whether Claude answers with this configuration: one tiny request, for Settings' Test Connection.
    public static func probe(claude configuration: ClaudeConfiguration) async throws -> String { try await Extractor.probe(claude: configuration) }

    func ingest(document: NormalizedDocument) async throws -> IngestResult {
        guard !document.pages.isEmpty else { throw IngestError.emptyDocument }
        let log = options.log
        var warnings: [String] = []
        let extractor: Extractor
        switch options.route {
        case .claude:
            guard let configuration = options.claude else { throw IngestError.claudeUnavailable("no API key") }
            extractor = try await Extractor.make(route: .claude, claude: configuration, sampleText: document.fullText, log: log, progress: options.progress)
        case .onDevice:
            extractor = try await Extractor.make(route: .onDevice, sampleText: document.fullText, log: log, progress: options.progress)
        }

        var completed = false
        defer { if !completed { options.progress(.finished(obligations: 0)) } }   // a failed or cancelled read must end in the UI too
        let outcomes = try await run(extractor, document: document)
        warnings += await extractor.warnings
        guard !outcomes.isEmpty else { throw IngestError.extractionFailed(warnings.joined(separator: "; ")) }
        let result = Merger.merge(outcomes: outcomes, document: document, route: extractor.route, options: options, warnings: warnings)
        completed = true
        options.progress(.finished(obligations: result.obligations.count))
        return result
    }

    /// Every chunk and image page through one extractor, in order, with the rolling context between them.
    private func run(_ extractor: Extractor, document: NormalizedDocument) async throws -> [ExtractionOutcome] {
        let log = options.log
        let textChunks = Chunker.chunks(pages: document.textPages, budgetTokens: extractor.chunkBudgetTokens, charsPerToken: extractor.charsPerToken)
        let images = document.imagePages
        log("\(document.info.name): \(document.pages.count) page(s) → \(textChunks.count) text chunk(s), \(images.count) image(s)")
        // A read that stopped earlier: its finished parts stand, if the chunking is the same; otherwise it starts afresh.
        let resume = options.resume.flatMap { $0.applies(route: extractor.route, textChunks: textChunks.count, images: images.count) ? $0 : nil }
        if options.resume != nil, resume == nil { log("checkpoint set aside: the read is chunked or routed differently now") }
        if let resume { log("resuming: \(resume.finishedParts) of \(resume.totalParts) part(s) from the checkpoint") }
        var checkpoint = IngestCheckpoint(route: extractor.route, textChunks: textChunks.count, images: images.count)
        options.progress(.started(document: document.info.name, textChunks: textChunks.count, images: images.count, resumed: resume?.finishedParts ?? 0))
        var context = RollingContext()
        if let known = options.knownCourse { context.seed(known) }
        var outcomes: [ExtractionOutcome] = []
        // Every part in turn: a part the checkpoint holds shows up as it did then, without the wait; the rest is read,
        // and the checkpoint grows by one part each time, so a read that stops loses at most the part under way.
        for position in 0 ..< (textChunks.count + images.count) {
            try Task.checkCancellation()
            let results: [ExtractionOutcome]
            if let kept = resume?.entry(at: position) {
                results = kept.outcomes
                Self.replay(position, results, route: extractor.route, to: options.progress)
            } else if position < textChunks.count {
                let chunk = textChunks[position]
                // Claude sees the chunk's pages as pictures beside the text, so a table garbled by the text layer is read as printed.
                let pictures = extractor.route == .claude ? document.pictures(ofPages: chunk.firstPage...chunk.lastPage) : []
                results = try await extractor.extract(chunk, pictures: pictures, context: context, document: document.info.name, chunkCount: textChunks.count)
            } else {
                let i = position - textChunks.count, image = images[i]
                results = try await extractor.extract(image: image.image, orientation: image.orientation, page: image.page, imageIndex: i, imageCount: images.count,
                                                      position: position, context: context, document: document.info.name).map { [$0] } ?? []
            }
            for r in results { context.absorb(r.extraction) }
            outcomes += results
            checkpoint.record(index: position, outcomes: results)
            if resume?.entry(at: position) == nil, let keep = options.checkpoint { await keep(checkpoint) }
        }
        return outcomes
    }

    /// A kept part's events, as the model would have sent them, so the reading bar and the provisional list show it.
    private static func replay(_ index: Int, _ results: [ExtractionOutcome], route: ModelRoute, to progress: @Sendable (IngestEvent) -> Void) {
        progress(.chunkStarted(index: index))
        let items = results.enumerated().flatMap { n, r in r.extraction.obligations.enumerated().map { i, o in
            ProvisionalObligation(id: "kept-\(index)-\(n)-\(i)", title: o.title, dateAsWritten: o.dateAsWritten, component: o.component) } }
        if !items.isEmpty { progress(.partial(chunk: index, obligations: items)) }
        let usage = results.last?.usage ?? UsageRecord(step: "kept", chunk: index, route: route, inputTokens: 0, outputTokens: 0, durationMs: 0)
        progress(.chunkFinished(index: index, obligations: results.reduce(0) { $0 + $1.extraction.obligations.count }, usage: usage))
    }
}
