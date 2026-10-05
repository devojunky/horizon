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
    public var courseTitle: String? = nil
    public var sourceDocumentID: UUID?
    public var sourcePage: Int?
    /// Checked off (or back on) in the app, and Reminders not yet told.
    public var completionPending: Bool = false

    public var link: URL { Identifiers.link(for: id) }
    /// The course as the app names it: its name, falling back to the code.
    public var courseName: String? { [courseTitle, courseCode].compactMap { $0 }.first { !$0.isEmpty } }
    /// Title as written to Reminders: "Homework 3 · Calculus II".
    public var reminderTitle: String { courseName.map { "\(title) · \($0)" } ?? title }
}

public struct CourseSnapshot: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var code: String
    public var title: String
    public var term: String?
    public var termStart: Date?
    public var termEnd: Date?
    public var gradeComponents: [GradeComponent]
    /// `Platform` raw values the course's documents name.
    public var platforms: [String]
    public var lastIngested: Date?
    public var sortOrder: Int? = nil
    public var deletedAt: Date? = nil
    /// When the course came into the app: where its silence starts counting before anything is completed.
    public var createdAt: Date? = nil

    public init(id: UUID = UUID(), code: String, title: String, term: String? = nil, termStart: Date? = nil, termEnd: Date? = nil,
                gradeComponents: [GradeComponent] = [], platforms: [String] = [], lastIngested: Date? = nil, sortOrder: Int? = nil, deletedAt: Date? = nil,
                createdAt: Date? = nil) {
        self.id = id; self.code = code; self.title = title; self.term = term; self.termStart = termStart; self.termEnd = termEnd
        self.gradeComponents = gradeComponents; self.platforms = platforms; self.lastIngested = lastIngested; self.sortOrder = sortOrder; self.deletedAt = deletedAt
        self.createdAt = createdAt
    }

    public init(_ c: Course) {
        self.init(id: c.id, code: c.code, title: c.title, term: c.term, termStart: c.termStart, termEnd: c.termEnd,
                  gradeComponents: c.gradeComponents, platforms: c.platforms, lastIngested: c.lastIngested, sortOrder: c.sortOrder, deletedAt: c.deletedAt,
                  createdAt: c.createdAt)
    }

    /// What the app calls the course: its name, falling back to the code.
    public var displayName: String { title.isEmpty ? code : title }
}

/// Hand edits to a course. Each set field becomes a user override that later documents do not overwrite.
public struct CourseEdits: Sendable, Equatable {
    public var title: String?
    public var code: String?
    public var term: String??
    public var termStart: Date??
    public var termEnd: Date??
    public var instructor: String??
    public var room: String??
    public var meetings: [MeetingSlot]?
    public var gradeComponents: [GradeComponent]?
    public var noClassDates: [ClosedDateRange]?
    public init(title: String? = nil, code: String? = nil, term: String?? = nil, termStart: Date?? = nil, termEnd: Date?? = nil, instructor: String?? = nil,
                room: String?? = nil, meetings: [MeetingSlot]? = nil, gradeComponents: [GradeComponent]? = nil, noClassDates: [ClosedDateRange]? = nil) {
        self.title = title; self.code = code; self.term = term; self.termStart = termStart; self.termEnd = termEnd; self.instructor = instructor
        self.room = room; self.meetings = meetings; self.gradeComponents = gradeComponents; self.noClassDates = noClassDates
    }
}

public struct DocumentSnapshot: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var filename: String
    /// The device model's name for it ("Calculus II Syllabus"), once it has one.
    public var title: String?
    public var sha256: String
    public var kind: String
    public var status: DocumentStatus
    public var queuedAt: Date
    public var ingestedAt: Date?
    public var deviceName: String
    public var failure: String?
    public var platform: Platform?
    public var courseID: UUID?
    public var deletedAt: Date?
    /// The user has said this document may be read by the device model instead of Claude.
    public var readOnDevice: Bool
    /// The failure is the file's own: a retry would fail the same way (offer no Retry).
    public var failureIsPermanent: Bool

    public init(id: UUID = UUID(), filename: String, sha256: String, kind: String, status: DocumentStatus, queuedAt: Date, ingestedAt: Date? = nil,
                deviceName: String, failure: String? = nil, platform: Platform? = nil, courseID: UUID? = nil, deletedAt: Date? = nil, readOnDevice: Bool = false, title: String? = nil,
                failureIsPermanent: Bool = false) {
        self.id = id; self.filename = filename; self.title = title; self.sha256 = sha256; self.kind = kind; self.status = status; self.queuedAt = queuedAt
        self.ingestedAt = ingestedAt; self.deviceName = deviceName; self.failure = failure; self.platform = platform; self.courseID = courseID; self.deletedAt = deletedAt
        self.readOnDevice = readOnDevice; self.failureIsPermanent = failureIsPermanent
    }

    public init(_ d: SourceDocument) {
        id = d.id; filename = d.filename; title = d.title; sha256 = d.sha256; kind = d.kind; status = d.status; queuedAt = d.queuedAt
        ingestedAt = d.ingestedAt; deviceName = d.deviceName; failure = d.failure; platform = d.platform; courseID = d.course?.id; deletedAt = d.deletedAt
        readOnDevice = d.readOnDevice; failureIsPermanent = d.failureIsPermanent
    }

    /// What the app calls the document: its title once it has one, else its file's name without the clutter.
    public var displayName: String { DocumentName.display(title: title, filename: filename) }
}

extension ObligationSnapshot {
    public init(_ o: Obligation) {
        self.init(id: o.id, title: o.title, due: o.due, dueHasTime: o.dueHasTime, platform: o.platform, componentName: o.componentName,
                  pointsAtStake: o.pointsAtStake, confidence: o.confidence, state: o.state, origin: o.origin, flags: o.flags, notes: o.notes,
                  userOverrides: o.userOverrides, ekExternalID: o.ekExternalID, projectedTitle: o.projectedTitle, projectedDue: o.projectedDue,
                  projectedNotes: o.projectedNotes, completedAt: o.completedAt, deletedAt: o.deletedAt, changeNote: o.changeNote, createdOn: o.createdOn,
                  courseID: o.course?.id, courseCode: o.course?.code, courseTitle: o.course?.title, sourceDocumentID: o.sourceDocument?.id, sourcePage: o.sourcePage,
                  completionPending: o.completionPending)
    }
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
    /// The document, or the course it belongs to, went to the bin while it was read: nothing was folded in, and the
    /// document waits in the bin with its checkpoint, to be read again from there if it is restored.
    public var binned = false
}
