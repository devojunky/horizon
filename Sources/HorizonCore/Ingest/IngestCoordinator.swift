import Foundation
import IngestKit

/// Progress of one document's read, for live UI.
public struct DocumentProgress: Sendable, Equatable {
    public var documentID: UUID
    public var filename: String
    public var event: IngestEvent
}

/// Inbox → parser → store → Reminders. The share extension and the folder watcher only `enqueue`; the app `drain`s.
public actor IngestCoordinator {
    public typealias Parser = @Sendable (URL, IngestOptions) async throws -> IngestResult

    private let store: HorizonStore
    private let storage: DocumentStorage
    private let sync: SyncCoordinator?
    private var options: IngestOptions
    private let deviceName: String
    private let parse: Parser
    private let progress: @Sendable (DocumentProgress) -> Void

    public struct Report: Sendable, Equatable {
        public var document: DocumentSnapshot
        public var summary: IngestSummary?
        public var failure: String?
    }

    public init(store: HorizonStore, storage: DocumentStorage, sync: SyncCoordinator?, options: IngestOptions = IngestOptions(), deviceName: String,
                progress: @escaping @Sendable (DocumentProgress) -> Void = { _ in }, parse: Parser? = nil) {
        self.store = store; self.storage = storage; self.sync = sync; self.options = options; self.deviceName = deviceName; self.progress = progress
        self.parse = parse ?? { url, options in try await Ingestor(options: options).ingest(fileURL: url) }
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
        case IngestError.modelUnavailable(let why): "The on-device model is unavailable: \(why)"
        default: error.localizedDescription
        }
    }

    /// Retires a course with its items and documents, and removes the documents' files.
    public func deleteCourse(id: UUID) async throws {
        for record in try await store.deleteCourse(id: id) { storage.remove(sha256: record.sha256, extension: record.kind) }
    }

    /// Removes a document, its stored file, and the items that came from it (soft-deleted; the next sync removes their reminders).
    public func deleteDocument(id: UUID) async throws {
        guard let record = try await store.deleteDocument(id: id) else { return }
        storage.remove(sha256: record.sha256, extension: record.kind)
    }

    /// Where the next drain reads documents: on device, or in Private Cloud Compute (a user setting).
    public func setRoute(_ route: IngestOptions.RoutePolicy) { options.route = route }

    /// Parses every queued document, folds results into the store, then writes Reminders.
    public func drain() async -> [Report] {
        var reports: [Report] = []
        guard let queued = try? await store.queuedDocuments() else { return reports }
        for doc in queued {
            if Task.isCancelled { break }   // background time ran out; the rest stays queued
            let url = storage.url(sha256: doc.sha256, extension: doc.kind)
            guard storage.exists(sha256: doc.sha256, extension: doc.kind) else { continue }   // ingested on another device
            var perDocument = options
            if let courseID = doc.courseID, let known = try? await store.knownCourse(for: courseID) { perDocument.knownCourse = known }   // filed under a course: read it as that course's
            let sink = progress, id = doc.id, name = doc.filename
            perDocument.progress = { event in sink(DocumentProgress(documentID: id, filename: name, event: event)) }
            do {
                let result = try await parse(url, perDocument)
                let summary = try await store.ingest(result, documentID: doc.id)
                reports.append(Report(document: doc, summary: summary, failure: nil))
            } catch IngestError.modelNotReady(let why) {
                try? await store.markDocument(id: doc.id, status: .queued, failure: "Waiting for the on-device model: \(why)")
                reports.append(Report(document: doc, summary: nil, failure: "Waiting for the on-device model: \(why)"))
                break   // nothing else will parse until the model is ready
            } catch IngestError.cloudUnavailable(let why) {
                try? await store.markDocument(id: doc.id, status: .awaitingCloudParse, failure: why)
                reports.append(Report(document: doc, summary: nil, failure: "Queued for Private Cloud Compute: \(why)"))
            } catch is CancellationError {
                try? await store.markDocument(id: doc.id, status: .queued, failure: nil)   // background time ran out mid-document; read it again next time
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
