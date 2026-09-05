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
    public init(name: String, weight: Double? = nil, expectedCount: Int? = nil, cadence: Cadence? = nil, dropLowest: Int? = nil) {
        self.name = name; self.weight = weight; self.expectedCount = expectedCount; self.cadence = cadence; self.dropLowest = dropLowest
    }
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
    case queued, parsed, failed, awaitingCloudParse
}
