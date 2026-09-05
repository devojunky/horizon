import Foundation
import SwiftData
import IngestKit

// CloudKit-compatible from the first commit (SPEC §4.4): every property optional or defaulted, no unique attributes,
// every relationship optional with an explicit inverse. The production schema is append-only once deployed.

public enum HorizonSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [Course.self, Obligation.self, SourceDocument.self, Policy.self] }

    @Model
    public final class Course {
        public var id: UUID = UUID()
        public var code: String = ""
        public var title: String = ""
        public var instructor: String?
        public var term: String?
        public var termStart: Date?
        public var termEnd: Date?
        public var room: String?
        public var meetings: [MeetingSlot] = []
        public var gradeComponents: [GradeComponent] = []
        public var noClassDates: [ClosedDateRange] = []
        /// `Platform` raw values ever seen for this course, for the Coverage screen.
        public var platforms: [String] = []
        public var lastIngested: Date?
        public var createdAt: Date = Date()
        @Relationship(deleteRule: .cascade, inverse: \Obligation.course) public var obligations: [Obligation]?
        @Relationship(deleteRule: .cascade, inverse: \SourceDocument.course) public var documents: [SourceDocument]?
        @Relationship(deleteRule: .cascade, inverse: \Policy.course) public var policies: [Policy]?

        public init(code: String, title: String) { self.code = code; self.title = title }
    }

    @Model
    public final class Obligation {
        public var id: UUID = UUID()
        public var title: String = ""
        /// Local time; 23:59 on the due day when `dueHasTime` is false.
        public var due: Date?
        public var dueHasTime: Bool = false
        public var platform: Platform = Platform.syllabusOnly
        public var componentName: String?
        /// Percentage points of the final grade.
        public var pointsAtStake: Double?
        public var confidence: Double = 0
        public var state: ObligationState = ObligationState.pendingReview
        public var origin: Origin = Origin.document
        public var dateAsWritten: String?
        public var flags: [String] = []
        public var sourcePage: Int?
        public var notes: String?
        public var userOverrides: [FieldKey] = []
        /// `EKCalendarItem.calendarItemExternalIdentifier`, stable across devices (SPEC §4.4 idempotency).
        public var ekExternalID: String?
        /// What was last written to Reminders, to tell a hand edit there from a document update here.
        public var projectedTitle: String?
        public var projectedDue: Date?
        /// The user-text part of the notes last written, so a Reminders-side note edit can be told from an app-side one.
        public var projectedNotes: String?
        public var completedAt: Date?
        /// Soft delete. Every query filters on `deletedAt == nil`; tombstones purge after 180 days.
        public var deletedAt: Date?
        /// Another date the same item was given (two documents disagree); surfaced, never resolved silently.
        public var conflictingDate: Date?
        /// Human-readable diff after a re-ingest changed a document-owned field; cleared when the user confirms.
        public var changeNote: String?
        /// Device that created the row. Only that device creates the reminder, so two devices never race (SPEC §4.4).
        public var createdOn: String = ""
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()
        public var course: Course?
        public var sourceDocument: SourceDocument?

        public init(title: String) { self.title = title }
    }

    @Model
    public final class SourceDocument {
        public var id: UUID = UUID()
        public var filename: String = ""
        public var sha256: String = ""
        public var kind: String = "pdf"
        public var pageCount: Int = 0
        public var queuedAt: Date = Date()
        public var ingestedAt: Date?
        public var deviceName: String = ""
        public var status: DocumentStatus = DocumentStatus.queued
        public var failure: String?
        public var route: String?
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        public var durationMs: Int = 0
        public var warnings: [String] = []
        public var course: Course?
        @Relationship(deleteRule: .nullify, inverse: \Obligation.sourceDocument) public var obligations: [Obligation]?

        public init(filename: String, sha256: String, kind: String, deviceName: String) {
            self.filename = filename; self.sha256 = sha256; self.kind = kind; self.deviceName = deviceName
        }
    }

    @Model
    public final class Policy {
        public var id: UUID = UUID()
        public var kind: PolicyKind = PolicyKind.other
        public var text: String = ""
        public var verbatim: Bool = true
        public var course: Course?

        public init(kind: PolicyKind, text: String, verbatim: Bool) { self.kind = kind; self.text = text; self.verbatim = verbatim }
    }
}

public typealias Course = HorizonSchemaV1.Course
public typealias Obligation = HorizonSchemaV1.Obligation
public typealias SourceDocument = HorizonSchemaV1.SourceDocument
public typealias Policy = HorizonSchemaV1.Policy

public enum HorizonMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [HorizonSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
