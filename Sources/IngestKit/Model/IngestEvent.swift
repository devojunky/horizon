import Foundation

/// Progress of one ingest, in the order it happens. Partial items are the model's raw words as they stream in;
/// they become real obligations only after `Merger` runs its guards at the end.
public enum IngestEvent: Sendable, Equatable {
    /// `resumed`: parts already finished by an earlier read of the document, reused from its checkpoint.
    case started(document: String, textChunks: Int, images: Int, resumed: Int = 0)
    case chunkStarted(index: Int)
    /// Everything the model has said so far for this chunk. Replaces the previous partial for the same chunk.
    case partial(chunk: Int, obligations: [ProvisionalObligation])
    /// Where the model is in this chunk's reply: the part being written and how far along, with the outline's totals
    /// once Claude has committed to them. Sent whenever it changes.
    case progress(chunk: Int, ReadProgress)
    case chunkFinished(index: Int, obligations: Int, usage: UsageRecord)
    case finished(obligations: Int)
}

/// Where the model is in one chunk's reply, read off the ordered JSON as it streams: the stage being written, how
/// many of that stage's items are finished, and the totals Claude committed to in its outline (the names of every
/// item, and the counts of grade rows, policies and breaks, before any of them). The device model chunks and outlines
/// nothing, so its totals are nil and a bar can only creep.
public struct ReadProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable, CaseIterable {
        /// The model is taking the measure of the document (writing its outline, or nothing yet).
        case sizing
        /// A picture is being transcribed, line by line.
        case transcribing
        case course, grading, obligations, policies, breaks
    }
    public var stage: Stage
    /// Items of the stage's list finished so far; 0 for the stages that are not lists.
    public var done: Int = 0
    /// What the outline promised for this stage, when it has arrived.
    public var total: Int?
    /// The item being written now, by the outline's name for it.
    public var current: String?
    /// The outline, once it has arrived whole.
    public var outline: Outline?

    public struct Outline: Sendable, Equatable {
        /// Every obligation's own name, in document order: the items to come, one for one.
        public var titles: [String]
        public var gradeRows: Int
        public var policies: Int
        public var breaks: Int
        public init(titles: [String], gradeRows: Int, policies: Int, breaks: Int) { self.titles = titles; self.gradeRows = gradeRows; self.policies = policies; self.breaks = breaks }
    }

    public init(stage: Stage, done: Int = 0, total: Int? = nil, current: String? = nil, outline: Outline? = nil) {
        self.stage = stage; self.done = done; self.total = total; self.current = current; self.outline = outline
    }
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
