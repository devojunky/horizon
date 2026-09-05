import Foundation

/// Progress of one ingest, in the order it happens. Partial items are the model's raw words as they stream in;
/// they become real obligations only after `Merger` runs its guards at the end.
public enum IngestEvent: Sendable, Equatable {
    case started(document: String, textChunks: Int, images: Int)
    case chunkStarted(index: Int)
    /// Everything the model has said so far for this chunk. Replaces the previous partial for the same chunk.
    case partial(chunk: Int, obligations: [ProvisionalObligation])
    case chunkFinished(index: Int, obligations: Int, usage: UsageRecord)
    case finished(obligations: Int)
}

/// An obligation as it appears mid-stream: title and date words only, no resolution, no status.
public struct ProvisionalObligation: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var dateAsWritten: String?
    public var component: String?
    public init(id: String, title: String, dateAsWritten: String? = nil, component: String? = nil) {
        self.id = id; self.title = title; self.dateAsWritten = dateAsWritten; self.component = component
    }
}
