import Foundation
import IngestKit

// Value types stored inside models. All Codable so SwiftData (and CloudKit mirroring) can persist them as data.

public typealias MeetingSlot = IngestKit.MeetingSlot

public struct GradeComponent: Codable, Sendable, Equatable {
    public var name: String
    /// Fraction of the final grade, 0…1.
    public var weight: Double?
    public var expectedCount: Int?
    public var cadence: Cadence?
    public var dropLowest: Int?
    /// Where the documents say the component's work lives; nil when they say nothing. Coverage's "never read" claim
    /// stands on this and on the items' own platforms, never on a guess.
    public var platform: Platform?
    public init(name: String, weight: Double? = nil, expectedCount: Int? = nil, cadence: Cadence? = nil, dropLowest: Int? = nil, platform: Platform? = nil) {
        self.name = name; self.weight = weight; self.expectedCount = expectedCount; self.cadence = cadence; self.dropLowest = dropLowest; self.platform = platform
    }
}

/// One document's word on an item: the title and date it prints, kept on the row (`Obligation.documentWords`) whatever
/// the user's edits. New fields must be optional: rows written before them still decode.
public struct DocumentWord: Codable, Sendable, Equatable {
    public var document: UUID
    public var title: String
    public var due: Date?
    public var dueHasTime: Bool
    public init(document: UUID, title: String, due: Date?, dueHasTime: Bool) { self.document = document; self.title = title; self.due = due; self.dueHasTime = dueHasTime }
}

public struct ClosedDateRange: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var label: String?
    public init(start: Date, end: Date, label: String? = nil) { self.start = start; self.end = end; self.label = label }
}

/// Where an obligation sits in the intake pipeline (SPEC §4.4 "Offline").
public enum ObligationState: String, Codable, Sendable, CaseIterable {
    case pendingReview      // below the confidence threshold, or a re-ingest changed a field: the user confirms
    case awaitingDate       // the document says TBD
    case readyToProject     // confirmed or confident; the next projection writes it to Reminders
    case projected          // in Reminders; `ekExternalID` set
}

public enum Origin: String, Codable, Sendable {
    case document   // parsed from a source document
    case manual     // entered by hand (the fallback editor)
    case reminders  // created by the user in Apple Reminders and imported by reconciliation
}

/// Fields the user has edited by hand. Documents no longer overwrite them (SPEC §4.4 field ownership).
public enum FieldKey: String, Codable, Sendable, CaseIterable {
    case title, due, platform, componentName, notes
}

public enum DocumentStatus: String, Codable, Sendable {
    case queued, parsed, failed, awaitingCloudParse, cancelled
}
