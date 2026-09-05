import Foundation
import FoundationModels
import Vision  // enables the OCRTool cross-import overlay (absent in the iOS simulator SDK)
import CoreGraphics
import ImageIO

/// The system OCR tool where the SDK has it; on the simulator the model reads the image without it.
func ocrTools() -> [any Tool] {
    #if canImport(_Vision_FoundationModels)
    [OCRTool()]
    #else
    []
    #endif
}

struct ExtractionOutcome: Sendable {
    enum Kind: Sendable { case text, image }
    var kind: Kind
    /// 0-based page of the source document the chunk came from (first page for a multi-page chunk).
    var page: Int
    var extraction: ChunkExtraction
    var usage: UsageRecord
}

/// Owns the model and the token budget. Every LanguageModelSession in IngestKit is created here.
/// One fresh session per chunk: the on-device context is too small to carry a transcript.
/// Chunk-level failures become `warnings`; only errors that make the whole ingest pointless are thrown.
actor Extractor {
    static let imageLabel = "page"

    let route: ModelRoute
    let contextSize: Int
    let chunkBudgetTokens: Int
    let charsPerToken: Double
    /// Instructions + schema + prompt framing, in tokens; the part of every call that is not chunk text or output.
    let fixedOverheadTokens: Int
    /// Output tokens the model may produce per call. It stops here instead of overflowing the context.
    let outputBudgetTokens: Int
    private(set) var warnings: [String] = []
    private let system: SystemLanguageModel?
    private let cloud: PrivateCloudComputeLanguageModel?
    private let log: @Sendable (String) -> Void
    private let progress: @Sendable (IngestEvent) -> Void

    static func make(route: ModelRoute, sampleText: String, log: @escaping @Sendable (String) -> Void,
                     progress: @escaping @Sendable (IngestEvent) -> Void = { _ in }) async throws -> Extractor {
        switch route {
        case .onDevice:
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available: break
            case .unavailable(.modelNotReady): throw IngestError.modelNotReady("assets are still loading")
            case .unavailable(let reason): throw IngestError.modelUnavailable(String(describing: reason))
            }
            let instructions = try await model.tokenCount(for: Instructions(IngestInstructions.text))
            let schema = try await model.tokenCount(for: ChunkExtraction.generationSchema)
            let sample = String(sampleText.prefix(2000))
            let sampleTokens = sample.isEmpty ? 1 : try await model.tokenCount(for: Prompt(sample))
            let ratio = min(4.5, max(2.5, Double(sample.count) / Double(max(sampleTokens, 1))))
            let overhead = instructions + schema + 80
            let outputReserve = max(700, Int(Double(model.contextSize) * 0.4))   // dense schedules produce ~80 tokens per item
            let budget = model.contextSize - overhead - outputReserve
            log("on-device: context \(model.contextSize), instructions \(instructions), schema \(schema), chunk budget \(budget) tokens, \(String(format: "%.2f", ratio)) chars/token")
            guard budget > 200 else { throw IngestError.modelUnavailable("context window too small for the extraction schema") }
            return Extractor(route: route, contextSize: model.contextSize, chunkBudgetTokens: budget, charsPerToken: ratio, fixedOverheadTokens: overhead,
                             outputBudgetTokens: outputReserve - 64, system: model, cloud: nil, log: log, progress: progress)
        case .privateCloudCompute:
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                throw IngestError.cloudUnavailable(String(describing: model.availability))
            }
            let context = try await model.contextSize
            let budget = context - 1500 - max(2000, context / 4)
            log("private cloud compute: context \(context), chunk budget \(budget) tokens")
            return Extractor(route: route, contextSize: context, chunkBudgetTokens: budget, charsPerToken: 3.5, fixedOverheadTokens: 1500,
                             outputBudgetTokens: max(2000, context / 4) - 64, system: nil, cloud: model, log: log, progress: progress)
        }
    }

    private init(route: ModelRoute, contextSize: Int, chunkBudgetTokens: Int, charsPerToken: Double, fixedOverheadTokens: Int, outputBudgetTokens: Int,
                 system: SystemLanguageModel?, cloud: PrivateCloudComputeLanguageModel?, log: @escaping @Sendable (String) -> Void,
                 progress: @escaping @Sendable (IngestEvent) -> Void) {
        self.route = route; self.contextSize = contextSize; self.chunkBudgetTokens = chunkBudgetTokens
        self.charsPerToken = charsPerToken; self.fixedOverheadTokens = fixedOverheadTokens; self.outputBudgetTokens = outputBudgetTokens
        self.system = system; self.cloud = cloud; self.log = log; self.progress = progress
    }

    /// Output tokens a chunk is likely to produce: every date in it is probably an obligation (~90 tokens each).
    static func expectedOutputTokens(for text: String) -> Int {
        let dates = DateResolver(defaultYear: 2000).explicitSpans(in: text).count
        return 250 + 90 * dates
    }

    /// Extract one text chunk. Splits and retries when the tokenizer disagrees with the estimate.
    func extract(_ chunk: TextChunk, context: RollingContext, document: String, chunkCount: Int, depth: Int = 0) async throws -> [ExtractionOutcome] {
        let prompt = IngestInstructions.prompt(chunk: chunk.text, chunkIndex: chunk.index, chunkCount: chunkCount, document: document, context: context)
        func split(_ why: String) async throws -> [ExtractionOutcome] {
            guard depth < 4, let halves = Chunker.halve(chunk) else {
                warn("chunk \(chunk.index) (page \(chunk.firstPage + 1)): \(why); skipped")
                return []
            }
            log("chunk \(chunk.index): \(why), splitting")
            var out: [ExtractionOutcome] = []
            for half in halves { out += try await extract(half, context: context, document: document, chunkCount: chunkCount, depth: depth + 1) }
            return out
        }
        if let system {
            let tokens = try await system.tokenCount(for: Prompt(prompt))
            if tokens > chunkBudgetTokens { return try await split("\(tokens) tokens over budget") }
            let expectedOutput = Self.expectedOutputTokens(for: chunk.text)
            if tokens + fixedOverheadTokens + expectedOutput > contextSize { return try await split("\(tokens) tokens plus ~\(expectedOutput) of output would overflow") }
        }
        do {
            return try await respond(chunk: chunk.index, page: chunk.firstPage, kind: .text, tools: []) { Prompt(prompt) }.map { [$0] } ?? []
        } catch let error where Self.isContextOverflow(error) {
            return try await split("context overflow")
        }
    }

    /// Extract one image page. A page too dense for the context is retried once at half size, then skipped with a warning.
    func extract(image: CGImage, orientation: CGImagePropertyOrientation?, page: Int, imageIndex: Int, imageCount: Int, position: Int, context: RollingContext, document: String) async throws -> ExtractionOutcome? {
        let text = IngestInstructions.imagePrompt(imageIndex: imageIndex, imageCount: imageCount, document: document, context: context)
        for attempt in 0..<2 {
            let candidate = attempt == 0 ? image : (Self.halved(image) ?? image)
            do {
                return try await respond(chunk: position, page: page, kind: .image, tools: ocrTools()) {
                    Prompt {
                        text
                        Attachment(candidate, orientation: orientation).label(Self.imageLabel)
                    }
                }
            } catch let error where Self.isContextOverflow(error) {
                log("image \(imageIndex) (page \(page + 1)): context overflow" + (attempt == 0 ? ", retrying at half size" : ""))
            }
        }
        warn("image \(imageIndex) (page \(page + 1)): too dense for the model's context; skipped")
        return nil
    }

    static func halved(_ image: CGImage) -> CGImage? {
        let w = image.width / 2, h = image.height / 2
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Numbers every model call, so streamed rows keep distinct ids across split chunks and image pages.
    private var calls = 0

    /// One model call, streamed so partial obligations reach the UI while the model is still writing. Output is capped
    /// at the reserved budget; if the model runs out (a page of policies can do that) or the context overflows anyway,
    /// the complete items from the last snapshot are kept instead of retrying the chunk.
    /// Returns nil (with a warning) when the model declines or fails on this chunk alone.
    private func respond(chunk: Int, page: Int, kind: ExtractionOutcome.Kind, tools: [any Tool], prompt: () -> Prompt) async throws -> ExtractionOutcome? {
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: outputBudgetTokens)
        try Task.checkCancellation()
        let start = ContinuousClock.now
        calls += 1
        let call = calls
        var last: LanguageModelSession.ResponseStream<ChunkExtraction>.Snapshot?
        let extraction: ChunkExtraction
        let usage: LanguageModelSession.Usage
        do {
            let stream: LanguageModelSession.ResponseStream<ChunkExtraction>
            switch route {
            case .onDevice:
                let session = LanguageModelSession(model: system!, tools: tools, instructions: Instructions(IngestInstructions.text))
                stream = session.streamResponse(to: prompt(), generating: ChunkExtraction.self, options: options, contextOptions: ContextOptions())
            case .privateCloudCompute:
                let session = LanguageModelSession(model: cloud!, tools: tools, instructions: Instructions(IngestInstructions.text))
                stream = session.streamResponse(to: prompt(), generating: ChunkExtraction.self, options: options, contextOptions: ContextOptions(reasoningLevel: .light))
            }
            progress(.chunkStarted(index: chunk))
            var lastShown: (Int, String?) = (-1, nil)
            for try await snapshot in stream {
                last = snapshot
                let items = Self.provisional(snapshot.content, call: call)
                let shown = (items.count, items.last?.dateAsWritten)
                if shown != lastShown {   // a new item appeared, or the current one's date arrived
                    progress(.partial(chunk: chunk, obligations: items))
                    lastShown = shown
                }
            }
            let response = try await stream.collect()
            extraction = response.content
            usage = response.usage
        } catch let error where Self.isContextOverflow(error) || Self.isTruncation(error) {
            // Salvage what streamed. A chunk with nothing complete falls back to splitting only for a genuine overflow.
            if let last {
                let c = last.content
                log("    streamed before the cut: meetings \((c.course ?? nil)?.meetings?.count ?? 0), components \(c.gradeComponents?.count ?? 0), obligations \(c.obligations?.count ?? 0), policies \(c.policies?.count ?? 0), noClass \(c.noClassDates?.count ?? 0), \(String(describing: c).count) chars; tail: \(last.rawContent.jsonString.suffix(600))")
            }
            guard let snapshot = last, let salvaged = Self.salvage(snapshot.content) else {
                if Self.isContextOverflow(error) { throw error }
                warn("chunk \(chunk) (page \(page + 1)): output ran out before any item completed; skipped (streamed \(last?.content.obligations?.count ?? 0) obligations, \(last?.content.gradeComponents?.count ?? 0) components, \(last?.content.policies?.count ?? 0) policies)")
                return nil
            }
            warn("chunk \(chunk) (page \(page + 1)): output ran out; kept \(salvaged.obligations.count) complete item(s) of \(snapshot.content.obligations?.count ?? 0) streamed (\(snapshot.content.gradeComponents?.count ?? 0) components, \(snapshot.content.policies?.count ?? 0) policies)")
            extraction = salvaged
            usage = snapshot.usage
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            throw IngestError.cloudUnavailable(error.localizedDescription)
        } catch LanguageModelError.rateLimited(let info) {
            throw IngestError.cloudUnavailable("rate limited until \(info.resetDate.map { "\($0)" } ?? "later")")
        } catch {
            warn("chunk \(chunk) (page \(page + 1)): model \(Self.isSafetyStop(error) ? "declined" : "failed"): \(error.localizedDescription)")
            return nil
        }
        let elapsed = ContinuousClock.now - start
        let record = UsageRecord(step: kind == .text ? "text" : "image", chunk: chunk, route: route,
                                 inputTokens: usage.input.totalTokenCount, cachedTokens: usage.input.cachedTokenCount,
                                 outputTokens: usage.output.totalTokenCount, reasoningTokens: usage.output.reasoningTokenCount,
                                 durationMs: Int(elapsed / .milliseconds(1)))
        log("chunk \(chunk) \(record.step): in \(record.inputTokens) out \(record.outputTokens) \(record.durationMs)ms, \(extraction.obligations.count) obligations")
        progress(.chunkFinished(index: chunk, obligations: extraction.obligations.count, usage: record))
        for o in extraction.obligations {
            log("    raw: \(o.title) | \(o.dateAsWritten) | \(o.dueDate ?? "nil") | \(o.platform) | \(o.component ?? "-") | \(o.confidence)")
        }
        for c in extraction.gradeComponents {
            log("    raw component: \(c.name) | \(c.weightPercent.map { "\($0)%" } ?? "nil") | \(c.count.map(String.init) ?? "-") | \(c.cadence) | \(c.platform)")
        }
        return ExtractionOutcome(kind: kind, page: page, extraction: extraction, usage: record)
    }

    /// Complete items from a partial response. Lists arrive in schema order, so only the one being written when the
    /// stream stopped can end in a cut-off element (its text may end mid-word); that element is dropped.
    static func salvage(_ partial: ChunkExtraction.PartiallyGenerated) -> ChunkExtraction? {
        let started = [partial.gradeComponents != nil, partial.obligations != nil, partial.policies != nil, partial.noClassDates != nil]
        let writing = started.lastIndex(of: true) ?? -1
        func settled<T>(_ items: [T]?, _ position: Int) -> [T] { items.map { position == writing ? Array($0.dropLast()) : $0 } ?? [] }
        let obligations = settled(partial.obligations, 1).compactMap { o -> ObligationFacts? in
            guard let title = o.title, let platform = o.platform, let written = o.dateAsWritten, let confidence = o.confidence else { return nil }
            return ObligationFacts(title: title, platform: platform, component: o.component ?? nil, dateAsWritten: written, dueDate: o.dueDate ?? nil, confidence: confidence)
        }
        let components = settled(partial.gradeComponents, 0).compactMap { c -> GradeComponentFacts? in
            guard let name = c.name, let cadence = c.cadence, let platform = c.platform else { return nil }
            return GradeComponentFacts(name: name, weightPercent: c.weightPercent ?? nil, count: c.count ?? nil, cadence: cadence, dropLowest: c.dropLowest ?? nil, platform: platform)
        }
        let policies = settled(partial.policies, 2).compactMap { p -> PolicyFacts? in
            guard let kind = p.kind, let text = p.text else { return nil }
            return PolicyFacts(kind: kind, text: text)
        }
        let noClass = settled(partial.noClassDates, 3).compactMap { n -> NoClassFacts? in
            guard let written = n.dateAsWritten else { return nil }
            return NoClassFacts(dateAsWritten: written, startDate: n.startDate ?? nil, endDate: n.endDate ?? nil)
        }
        let course = partial.course.flatMap { c -> CourseFacts? in
            let facts = c ?? nil
            guard let facts else { return nil }
            return CourseFacts(code: facts.code ?? nil, title: facts.title ?? nil, instructor: facts.instructor ?? nil, term: facts.term ?? nil,
                               termStart: facts.termStart ?? nil, termEnd: facts.termEnd ?? nil, room: facts.room ?? nil, meetings: [])
        }
        guard course != nil || !obligations.isEmpty || !components.isEmpty || !policies.isEmpty else { return nil }
        return ChunkExtraction(course: course, gradeComponents: components, obligations: obligations, policies: policies, noClassDates: noClass)
    }

    /// The model stopped at `maximumResponseTokens`, leaving the structured response unfinished.
    static func isTruncation(_ error: any Error) -> Bool {
        if case LanguageModelError.contextSizeExceeded = error { return false }
        return error is GeneratedContent.ParsingError || String(describing: error).localizedCaseInsensitiveContains("decod")
    }

    private func warn(_ message: String) {
        log(message)
        warnings.append(message)
    }

    /// The model's words so far, as rows the UI can show: only items whose title has arrived.
    static func provisional(_ partial: ChunkExtraction.PartiallyGenerated, call: Int) -> [ProvisionalObligation] {
        (partial.obligations ?? []).enumerated().compactMap { index, item in
            guard let title = item.title, !title.isEmpty else { return nil }
            return ProvisionalObligation(id: "\(call)-\(index)", title: title, dateAsWritten: item.dateAsWritten, component: item.component ?? nil)
        }
    }

    static func isContextOverflow(_ error: any Error) -> Bool {
        if case LanguageModelError.contextSizeExceeded = error { return true }
        return false
    }

    static func isSafetyStop(_ error: any Error) -> Bool {
        switch error {
        case LanguageModelError.guardrailViolation, LanguageModelError.refusal: true
        default: false
        }
    }
}
