import Foundation
import UniformTypeIdentifiers
import IngestKit

/// Progress of one document's read, for live UI.
public struct DocumentProgress: Sendable, Equatable {
    public var documentID: UUID
    /// What the app calls the document now: its title when it has one, else its file's name, tidied. A title that
    /// arrives mid-read comes as `IngestEvent.named`.
    public var name: String
    public var event: IngestEvent
}

/// Inbox → parser → store → Reminders. The share extension and the folder watcher only `enqueue`; the app `drain`s.
public actor IngestCoordinator {
    public typealias Parser = @Sendable (URL, IngestOptions) async throws -> IngestResult
    /// Names a document on file: its stored copy, what to tell the model, and a digest of what was read from it (for a picture).
    public typealias Namer = @Sendable (URL, DocumentTitleRequest, String?) async -> DocumentTitleOutcome

    private let store: HorizonStore
    private let storage: DocumentStorage
    private let sync: SyncCoordinator?
    private var options: IngestOptions
    private let deviceName: String
    private let parse: Parser
    private let name: Namer
    private let progress: @Sendable (DocumentProgress) -> Void
    /// Whether the device has a model to read with at all (Apple Intelligence supported, on or not): where it has none, a
    /// document cleared for the device (`readOnDevice`, a permission to use it instead of waiting for Claude, given on a
    /// build that offered it everywhere) takes the drain's route like any other, or it could never be read.
    private var deviceReads = true
    /// The read under way: its document, and the task reading it (stopped when the user deletes the document).
    private var reading: (id: UUID, task: Task<IngestResult, any Error>)?
    /// Documents found with nothing to name them from while they wait to be read (a picture, a scan): not opened again to
    /// be named, a decode or a render each time, until they have been read.
    private var nothingToNameYet: Set<UUID> = []

    public struct Report: Sendable, Equatable {
        public var document: DocumentSnapshot
        public var summary: IngestSummary?
        public var failure: String?
    }

    public init(store: HorizonStore, storage: DocumentStorage, sync: SyncCoordinator?, options: IngestOptions = IngestOptions(), deviceName: String,
                progress: @escaping @Sendable (DocumentProgress) -> Void = { _ in }, parse: Parser? = nil, name: Namer? = nil) {
        self.store = store; self.storage = storage; self.sync = sync; self.options = options; self.deviceName = deviceName; self.progress = progress
        self.parse = parse ?? { url, options in try await Ingestor(options: options).ingest(fileURL: url) }
        let log = options.log
        self.name = name ?? { url, request, digest in await Ingestor.title(fileURL: url, request: request, digest: digest, log: log) }
    }

    /// Copies the file into the App Group container and records it. The same file shared twice is recorded once;
    /// a file that failed before is queued again. A file of a kind Horizon cannot read is refused before it is copied:
    /// recorded as failed for good, with what to do instead.
    public func enqueue(fileURL: URL, filename: String? = nil, courseID: UUID? = nil) async throws -> DocumentSnapshot {
        let name = filename ?? fileURL.lastPathComponent
        let target = fileURL.resolvingSymlinksInPath()   // a link is judged, like it is stored, by its file
        if let refusal = Self.refusal(for: target) {
            let kind = target.pathExtension.isEmpty ? "bin" : target.pathExtension.lowercased()
            return try await store.enqueueDocument(filename: name, sha256: try DocumentStorage.sha256(fileAt: target), kind: kind, deviceName: deviceName,
                                                   courseID: courseID, refusal: Self.explain(refusal, kind: kind))
        }
        let stored = try storage.store(fileURL)
        return try await store.enqueueDocument(filename: name, sha256: stored.sha256,
                                               kind: stored.url.pathExtension.lowercased(), deviceName: deviceName, courseID: courseID)
    }

    /// Why a file cannot be read, from its kind alone, as the reader would find (`DocumentNormalizer.normalize`: a PDF, a
    /// picture, a Word document on a Mac, text, or a file of no known kind tried as text); nil for a kind it reads.
    /// Keep the two in step.
    static func refusal(for url: URL) -> IngestError? {
        if url.pathExtension.lowercased() == "docx" {
            #if canImport(AppKit)
            return nil
            #else
            return .unsupportedFile("docx (macOS only)")
            #endif
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .text) || type == .data { return nil }
        return .unsupportedFile(url.pathExtension.isEmpty ? "unknown" : url.pathExtension)
    }

    /// A failure in the user's terms: no stored file names, no framework names.
    static func explain(_ error: any Error, kind: String) -> String {
        switch error {
        case IngestError.unreadable: "The file could not be opened as a \(kind.uppercased()) document."
        case IngestError.emptyDocument: "The document has no readable text or images."
        case IngestError.unsupportedFile(let ext) where ext.hasPrefix("docx"): "Word documents can only be read on a Mac. Save it as a PDF and add that instead."
        case IngestError.unsupportedFile(let ext): "Horizon cannot read .\(ext) files."
        case IngestError.extractionFailed: "The model found nothing in it to read."
        case IngestError.modelUnavailable(let why): "\(why.prefix(1).uppercased() + why.dropFirst())."   // the reason carries its own way out
        default: error.localizedDescription
        }
    }

    /// A failure that is the file's own (unreadable, empty, a kind Horizon cannot read): reading it again can only fail
    /// the same way, so it is recorded as permanent and offered no Retry.
    static func isPermanent(_ error: any Error) -> Bool {
        switch error {
        case IngestError.unreadable, IngestError.emptyDocument, IngestError.unsupportedFile: true
        default: false
        }
    }

    /// Whether a wait for Claude stops the drain: every document behind it would get the same answer (no key, a key
    /// refused, no connection, an account out of credit, a model Anthropic does not have or will not let the key use, a
    /// request it refused), so they wait with it rather than each spending a request on that answer. A rate limit or an
    /// overload the client has already waited out does not: the next document may pass. Horizon's reading service answers
    /// every document from this device alike (its allowance used up, the device not confirmed, the service down), so its
    /// waits stop the drain too. The reason is known by its words (`ClaudeError`'s, through `Extractor.explainClaude`),
    /// since they are what a waiting document keeps.
    public static func stopsDrain(_ why: String) -> Bool {
        isKeyOrModelProblem(why) || why.hasPrefix("no connection") || why.contains("out of credit") || why.contains("Horizon's reading service")
    }

    /// Whether a wait for Claude is the key's or the model's, for Settings to put right rather than another try: no key, a
    /// key refused, a model Anthropic does not have or will not let the key use, or a request it refused (sent again
    /// unchanged, it would be refused again).
    public static func isKeyOrModelProblem(_ why: String) -> Bool {
        why == "no API key" || why.contains("missing or was rejected") || why.contains("does not let this key") || why.contains("has no model named")
            || why.hasPrefix("Anthropic rejected the request")
    }

    // MARK: Recently Deleted (the store decides; this removes the files once something is gone for good)

    /// The document being read now, if any.
    public var documentBeingRead: UUID? { reading?.id }

    /// To the bin. A read under way of a document that went with it (the document itself, or one filed under the
    /// course) stops: what was read so far stays in its checkpoint, and the drain goes on to the next document.
    public func deleteCourse(id: UUID) async throws { try await store.deleteCourse(id: id); await stopReadIfBinned() }
    public func deleteDocument(id: UUID) async throws { try await store.deleteDocument(id: id); await stopReadIfBinned() }

    private func stopReadIfBinned() async {
        guard let current = reading, (try? await store.document(id: current.id))?.deletedAt != nil else { return }
        current.task.cancel()
    }

    public func restoreCourse(id: UUID) async throws { try await store.restoreCourse(id: id) }
    public func restoreDocument(id: UUID) async throws { try await store.restoreDocument(id: id) }

    /// Gone for good, its documents' files with it.
    public func eraseCourse(id: UUID) async throws {
        for record in try await store.eraseCourse(id: id) { storage.remove(sha256: record.sha256, extension: record.kind) }
    }

    /// Gone for good, its file with it.
    public func eraseDocument(id: UUID) async throws {
        guard let record = try await store.eraseDocument(id: id) else { return }
        storage.remove(sha256: record.sha256, extension: record.kind)
    }

    /// Empties what has sat in the bin for `Bin.age`, files included.
    public func expireBin(now: Date = Date()) async throws {
        for record in try await store.expireBin(now: now) { storage.remove(sha256: record.sha256, extension: record.kind) }
    }

    /// Where the next drain reads documents: Claude (with `setClaude`) or the device model (user settings). A document
    /// the user has cleared for the device (`readOnDevice`) goes to the device whatever the setting.
    public func setRoute(_ route: IngestOptions.RoutePolicy) { options.route = route }
    public func setClaude(_ configuration: ClaudeConfiguration?) { options.claude = configuration }
    public func setDeviceReads(_ reads: Bool) { deviceReads = reads }

    /// Names the documents on file that nobody has tried to name: those read before titles existed, or while the
    /// device model was away. A few per call, quietly; a document the model has no name for is marked so, and a model
    /// that is not there ends the pass until another time. A document with nothing to name it from yet (a picture
    /// waiting for Claude) is passed over, not counted, and named once it has been read; one read to the end with still
    /// nothing to go on is marked as having no name.
    public func nameUntitled(limit: Int = 4) async {
        guard let untitled = try? await store.untitledDocuments() else { return }
        var asked = 0
        for doc in untitled {
            if Task.isCancelled || asked == limit { return }
            guard storage.exists(sha256: doc.sha256, extension: doc.kind) else { continue }   // read on another device
            if doc.status != .parsed, nothingToNameYet.contains(doc.id) { continue }
            var course: KnownCourse?
            if let courseID = doc.courseID { course = try? await store.knownCourse(for: courseID) }
            let request = DocumentTitleRequest(filename: doc.filename, course: course.flatMap { $0.title ?? $0.code })
            switch await name(storage.url(sha256: doc.sha256, extension: doc.kind), request, try? await store.digest(for: doc.id)) {
            case .titled(let title): asked += 1; try? await store.setDocumentTitle(id: doc.id, title: title)
            case .nothing: asked += 1; try? await store.setDocumentTitle(id: doc.id, title: "")
            case .notYet:   // as it is now: it may have been read, or queued again, meanwhile
                if (try? await store.document(id: doc.id))?.status == .parsed { try? await store.setDocumentTitle(id: doc.id, title: "") }
                else { nothingToNameYet.insert(doc.id) }
            case .unavailable: return
            }
        }
    }

    /// Parses every queued document, folds results into the store, then writes Reminders.
    public func drain() async -> [Report] {
        var reports: [Report] = []
        guard let queued = try? await store.queuedDocuments() else { return reports }
        documents: for listed in queued {
            if Task.isCancelled { break }   // background time ran out; the rest stays queued
            // As it is now: the queue was listed before the reads ahead of it, and the user may have deleted it since.
            guard let doc = try? await store.document(id: listed.id), doc.deletedAt == nil, doc.status == .queued || doc.status == .awaitingCloudParse else { continue }
            let url = storage.url(sha256: doc.sha256, extension: doc.kind)
            guard storage.exists(sha256: doc.sha256, extension: doc.kind) else { continue }   // ingested on another device
            var perDocument = options
            if doc.readOnDevice, deviceReads { perDocument.route = .onDevice }   // the user's word, for this document
            if let courseID = doc.courseID, let known = try? await store.knownCourse(for: courseID) { perDocument.knownCourse = known }   // filed under a course: read it as that course's
            // A document with no title yet is named along the way (the device model's small task, whatever reads it);
            // the title is kept the moment it arrives, so a read that then fails still leaves the document named.
            if doc.title == nil { perDocument.titleRequest = DocumentTitleRequest(filename: doc.filename, course: perDocument.knownCourse.flatMap { $0.title ?? $0.code }) }
            let sink = progress, id = doc.id, name = doc.displayName, titles = store
            perDocument.progress = { event in
                if case .named(let title) = event { Task { try? await titles.setDocumentTitle(id: id, title: title ?? "") } }
                sink(DocumentProgress(documentID: id, name: name, event: event))
            }
            // A read that stopped earlier goes on from its checkpoint; every finished part is kept as it comes.
            if let data = try? await store.checkpoint(for: doc.id), let checkpoint = try? IngestCheckpoint(data: data) { perDocument.resume = checkpoint }
            let keeper = store
            perDocument.checkpoint = { checkpoint in if let data = try? checkpoint.encoded() { try? await keeper.saveCheckpoint(id: id, data: data) } }
            do {
                let result = try await read(url, perDocument, id: doc.id)
                let summary = try await store.ingest(result, documentID: doc.id)
                if !summary.binned { reports.append(Report(document: doc, summary: summary, failure: nil)) }   // deleted while read: it waits in the bin
            } catch {
                // Deleted while it was read (its read stopped, or failed on the way): it waits in the bin with what was
                // read, and the next document is read.
                if !Task.isCancelled, (try? await store.document(id: doc.id))?.deletedAt != nil { continue }
                switch error {
                case IngestError.modelNotReady(let why):
                    try? await store.markDocument(id: doc.id, status: .queued, failure: "Waiting for Apple Intelligence: \(why)")
                    reports.append(Report(document: doc, summary: nil, failure: "Waiting for Apple Intelligence: \(why)"))
                    if options.route == .onDevice { break documents }   // nothing else will parse until the model is ready; on Claude's route only the documents cleared for the device wait
                case IngestError.claudeUnavailable(let why):
                    // Claude could not read it now: it waits (a processing task with the network, the next drain, or the
                    // user's word to read it on the device). Never read on the device unasked.
                    try? await store.markDocument(id: doc.id, status: .awaitingCloudParse, failure: why)
                    reports.append(Report(document: doc, summary: nil, failure: "Waiting for Claude: \(why)"))
                    if Self.stopsDrain(why) { break documents }   // the same answer waits for every document behind it
                case is CancellationError, _ where Task.isCancelled:
                    try? await store.markDocument(id: doc.id, status: .queued, failure: nil)   // paused: the checkpoint holds the parts read so far; it goes on next time
                    break documents
                default:
                    let failure = Self.explain(error, kind: doc.kind)
                    try? await store.markDocument(id: doc.id, status: .failed, failure: failure, permanent: Self.isPermanent(error))
                    reports.append(Report(document: doc, summary: nil, failure: failure))
                }
            }
        }
        if let sync, !reports.isEmpty { _ = try? await sync.sync() }
        return reports
    }

    /// One document's read, as a task of its own so that deleting the document can stop it (`stopReadIfBinned`); the
    /// drain being cancelled (background time running out) stops it too.
    private func read(_ url: URL, _ options: IngestOptions, id: UUID) async throws -> IngestResult {
        let parse = parse
        let task = Task { try await parse(url, options) }
        reading = (id, task)
        defer { reading = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
