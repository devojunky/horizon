import Foundation
import IngestKit

// Sendable copies of model rows for crossing actor boundaries. Models themselves never leave the store actor.

public struct ObligationSnapshot: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var due: Date?
    public var dueHasTime: Bool
    public var platform: Platform
    public var componentName: String?
    public var pointsAtStake: Double?
    public var confidence: Double
    public var state: ObligationState
    public var origin: Origin
    public var flags: [String]
    public var notes: String?
    public var userOverrides: [FieldKey]
    public var ekExternalID: String?
    public var projectedTitle: String?
    public var projectedDue: Date?
    public var projectedNotes: String?
    public var completedAt: Date?
    public var deletedAt: Date?
    public var changeNote: String?
    public var createdOn: String
    public var courseID: UUID?
    public var courseCode: String?
    public var sourceDocumentID: UUID?
    public var sourcePage: Int?

    public var link: URL { Identifiers.link(for: id) }
    /// Title as written to Reminders: "Homework 3 · MA-UY 1124".
    public var reminderTitle: String { courseCode.map { "\(title) · \($0)" } ?? title }
}

public struct CourseSnapshot: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var code: String
    public var title: String
    public var term: String?
    public var gradeComponents: [GradeComponent]
    public var lastIngested: Date?
}

public struct DocumentSnapshot: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var filename: String
    public var sha256: String
    public var kind: String
    public var status: DocumentStatus
    public var queuedAt: Date
    public var ingestedAt: Date?
    public var deviceName: String
    public var failure: String?
}

/// Hand edits from the review queue or the manual editor. Nil means "leave as is".
public struct ObligationEdits: Sendable, Equatable {
    public var title: String?
    public var due: Date??
    public var dueHasTime: Bool?
    public var platform: Platform?
    public var componentName: String??
    public var notes: String??
    public var courseID: UUID??
    public init(title: String? = nil, due: Date?? = nil, dueHasTime: Bool? = nil, platform: Platform? = nil, componentName: String?? = nil, notes: String?? = nil, courseID: UUID?? = nil) {
        self.title = title; self.due = due; self.dueHasTime = dueHasTime; self.platform = platform; self.componentName = componentName; self.notes = notes; self.courseID = courseID
    }
}

public struct IngestSummary: Sendable, Equatable {
    public var courseCode: String?
    public var created = 0
    public var updated = 0
    public var unchanged = 0
    public var pendingReview = 0
    public var warnings: [String] = []
}
