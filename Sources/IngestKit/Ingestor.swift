import Foundation
import CoreGraphics

public struct IngestOptions: Sendable {
    public enum RoutePolicy: Sendable {
        case onDeviceOnly
        /// On-device first; Private Cloud Compute only when the on-device model is unavailable.
        case onDeviceFirst
        case privateCloudCompute
        /// OpenAI with the user's key (`openAI`), falling back to the device when it cannot be used.
        case openAI
    }
    public var route: RoutePolicy = .onDeviceFirst
    public var openAI: OpenAIConfiguration?
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

    /// Why Private Cloud Compute cannot be used on this device right now, or nil when it can.
    public static func cloudAvailability() -> String? { Extractor.cloudAvailability() }

    func ingest(document: NormalizedDocument) async throws -> IngestResult {
        guard !document.pages.isEmpty else { throw IngestError.emptyDocument }
        let log = options.log
        var warnings: [String] = []
        var extractor: Extractor
        switch options.route {
        case .onDeviceOnly:
            extractor = try await Extractor.make(route: .onDevice, sampleText: document.fullText, log: log, progress: options.progress)
        case .privateCloudCompute:
            extractor = try await Extractor.make(route: .privateCloudCompute, sampleText: document.fullText, log: log, progress: options.progress)
        case .onDeviceFirst:
            do { extractor = try await Extractor.make(route: .onDevice, sampleText: document.fullText, log: log, progress: options.progress) }
            catch IngestError.modelUnavailable(let why) {   // a device that will never have the model; "not ready" propagates for a retry
                warnings.append("On-device model unavailable (\(why)); using Private Cloud Compute")
                extractor = try await Extractor.make(route: .privateCloudCompute, sampleText: document.fullText, log: log, progress: options.progress)
            }
        case .openAI:
            guard let configuration = options.openAI else { throw IngestError.remoteUnavailable("no API key") }
            extractor = try await Extractor.make(route: .openAI, openAI: configuration, sampleText: document.fullText, log: log, progress: options.progress)
        }

        var completed = false
        defer { if !completed { options.progress(.finished(obligations: 0)) } }   // a failed or cancelled read must end in the UI too
        var outcomes: [ExtractionOutcome]
        do {
            outcomes = try await run(extractor, document: document)
        } catch IngestError.remoteUnavailable(let why) where extractor.route == .openAI {
            // The key, the model or the network failed the whole read: the device reads it instead, and says so.
            let note = "OpenAI could not be used (\(why)); read on device instead"
            log(note); warnings.append(note)
            warnings += await extractor.warnings
            extractor = try await Extractor.make(route: .onDevice, sampleText: document.fullText, log: log, progress: options.progress)
            outcomes = try await run(extractor, document: document)
        }
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
        options.progress(.started(document: document.info.name, textChunks: textChunks.count, images: images.count))
        var context = RollingContext()
        if let known = options.knownCourse { context.seed(known) }
        var outcomes: [ExtractionOutcome] = []
        for chunk in textChunks {
            try Task.checkCancellation()
            let results = try await extractor.extract(chunk, context: context, document: document.info.name, chunkCount: textChunks.count)
            for r in results { context.absorb(r.extraction) }
            outcomes += results
        }
        for (i, image) in images.enumerated() {
            try Task.checkCancellation()
            if let r = try await extractor.extract(image: image.image, orientation: image.orientation, page: image.page, imageIndex: i, imageCount: images.count,
                                                   position: textChunks.count + i, context: context, document: document.info.name) {
                context.absorb(r.extraction)
                outcomes.append(r)
            }
        }
        return outcomes
    }
}
