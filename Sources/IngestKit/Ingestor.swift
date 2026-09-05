import Foundation
import CoreGraphics

public struct IngestOptions: Sendable {
    public enum RoutePolicy: Sendable {
        case onDeviceOnly
        /// On-device first; Private Cloud Compute only when the on-device model is unavailable.
        case onDeviceFirst
        case privateCloudCompute
    }
    public var route: RoutePolicy = .onDeviceFirst
    /// Year for dates when the document names no term. Defaults to the current year. A term label like "Spring 2027" wins.
    public var defaultYear: Int?
    /// Overrides the term start used for week-relative dates and term bounds.
    public var termStart: Date?
    public var calendar: Calendar = .current
    /// Obligations below this confidence are marked `.needsReview`.
    public var reviewThreshold: Double = 0.7
    public var log: @Sendable (String) -> Void = { _ in }

    public init() {}
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

    func ingest(document: NormalizedDocument) async throws -> IngestResult {
        guard !document.pages.isEmpty else { throw IngestError.emptyDocument }
        let log = options.log
        var warnings: [String] = []
        let extractor: Extractor
        switch options.route {
        case .onDeviceOnly:
            extractor = try await Extractor.make(route: .onDevice, sampleText: document.fullText, log: log)
        case .privateCloudCompute:
            extractor = try await Extractor.make(route: .privateCloudCompute, sampleText: document.fullText, log: log)
        case .onDeviceFirst:
            do { extractor = try await Extractor.make(route: .onDevice, sampleText: document.fullText, log: log) }
            catch let error as IngestError {
                warnings.append("\(error.localizedDescription); using Private Cloud Compute")
                extractor = try await Extractor.make(route: .privateCloudCompute, sampleText: document.fullText, log: log)
            }
        }

        let textChunks = Chunker.chunks(pages: document.textPages, budgetTokens: extractor.chunkBudgetTokens, charsPerToken: extractor.charsPerToken)
        let images = document.imagePages
        log("\(document.info.name): \(document.pages.count) page(s) → \(textChunks.count) text chunk(s), \(images.count) image(s)")

        var context = RollingContext()
        var outcomes: [ExtractionOutcome] = []
        for chunk in textChunks {
            let results = try await extractor.extract(chunk, context: context, document: document.info.name, chunkCount: textChunks.count)
            for r in results { context.absorb(r.extraction) }
            outcomes += results
        }
        for (i, image) in images.enumerated() {
            if let r = try await extractor.extract(image: image.image, orientation: image.orientation, page: image.page, imageIndex: i, imageCount: images.count,
                                                   context: context, document: document.info.name) {
                context.absorb(r.extraction)
                outcomes.append(r)
            }
        }
        warnings += await extractor.warnings
        guard !outcomes.isEmpty else { throw IngestError.extractionFailed(warnings.joined(separator: "; ")) }
        return Merger.merge(outcomes: outcomes, document: document, route: extractor.route, options: options, warnings: warnings)
    }
}
