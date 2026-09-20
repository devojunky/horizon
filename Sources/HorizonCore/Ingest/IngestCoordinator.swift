import Foundation
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
    /// a file that failed before is queued again.
    public func enqueue(fileURL: URL, filename: String? = nil, courseID: UUID? = nil) async throws -> DocumentSnapshot {
        let stored = try storage.store(fileURL)
        return try await store.enqueueDocument(filename: filename ?? fileURL.lastPathComponent, sha256: stored.sha256,
                                               kind: stored.url.pathExtension.lowercased(), deviceName: deviceName, courseID: courseID)
    }

    /// A failure in the user's terms: no stored file names, no framework names.
    static func explain(_ error: any Error, kind: String) -> String {
        switch error {
        case IngestError.unreadable: "The file could not be opened as a \(kind.uppercased()) document."
        case IngestError.emptyDocument: "The document has no readable text or images."
        case IngestError.unsupportedFile(let ext): "Horizon cannot read .\(ext) files."
        case IngestError.extractionFailed: "The model found nothing in it to read."
        case IngestError.modelUnavailable(let why): "The device model is unavailable: \(why)"
        default: error.localizedDescription
        }
    }

    // MARK: Recently Deleted (the store decides; this removes the files once something is gone for good)

    public func deleteCourse(id: UUID) async throws { try await store.deleteCourse(id: id) }
    public func deleteDocument(id: UUID) async throws { try await store.deleteDocument(id: id) }
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

    /// Names the documents on file that nobody has tried to name: those read before titles existed, or while the
    /// device model was away. A few per call, quietly; a document the model has no name for is marked so, and a model
    /// that is not there ends the pass until another time.
    public func nameUntitled(limit: Int = 4) async {
        guard let untitled = try? await store.untitledDocuments() else { return }
        for doc in untitled.prefix(limit) {
            if Task.isCancelled { return }
            guard storage.exists(sha256: doc.sha256, extension: doc.kind) else { continue }   // read on another device
            var course: KnownCourse?
            if let courseID = doc.courseID { course = try? await store.knownCourse(for: courseID) }
            let request = DocumentTitleRequest(filename: doc.filename, course: course.flatMap { $0.title ?? $0.code })
            switch await name(storage.url(sha256: doc.sha256, extension: doc.kind), request, try? await store.digest(for: doc.id)) {
            case .titled(let title): try? await store.setDocumentTitle(id: doc.id, title: title)
            case .nothing: try? await store.setDocumentTitle(id: doc.id, title: "")
            case .unavailable: return
            }
        }
    }

    /// Parses every queued document, folds results into the store, then writes Reminders.
    public func drain() async -> [Report] {
        var reports: [Report] = []
        guard let queued = try? await store.queuedDocuments() else { return reports }
        for doc in queued {
            if Task.isCancelled { break }   // background time ran out; the rest stays queued
            let url = storage.url(sha256: doc.sha256, extension: doc.kind)
            guard storage.exists(sha256: doc.sha256, extension: doc.kind) else { continue }   // ingested on another device
            var perDocument = options
            if doc.readOnDevice { perDocument.route = .onDevice }   // the user's word, for this document
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
                let result = try await parse(url, perDocument)
                let summary = try await store.ingest(result, documentID: doc.id)
                reports.append(Report(document: doc, summary: summary, failure: nil))
            } catch IngestError.modelNotReady(let why) {
                try? await store.markDocument(id: doc.id, status: .queued, failure: "Waiting for the on-device model: \(why)")
                reports.append(Report(document: doc, summary: nil, failure: "Waiting for the on-device model: \(why)"))
                break   // nothing else will parse until the model is ready
            } catch IngestError.claudeUnavailable(let why) {
                // Claude could not read it now: it waits (a processing task with the network, the next drain, or the user's
                // word to read it on the device). Never read on the device unasked.
                try? await store.markDocument(id: doc.id, status: .awaitingCloudParse, failure: why)
                reports.append(Report(document: doc, summary: nil, failure: "Waiting for Claude: \(why)"))
                if why == "no API key" || why.hasPrefix("no connection") || why.contains("rejected") { break }   // the same will stop every document behind it
            } catch is CancellationError {
                try? await store.markDocument(id: doc.id, status: .queued, failure: nil)   // paused: the checkpoint holds the parts read so far; it goes on next time
                break
            } catch {
                let failure = Self.explain(error, kind: doc.kind)
                try? await store.markDocument(id: doc.id, status: .failed, failure: failure)
                reports.append(Report(document: doc, summary: nil, failure: failure))
            }
        }
        if let sync, !reports.isEmpty { _ = try? await sync.sync() }
        return reports
    }
}
