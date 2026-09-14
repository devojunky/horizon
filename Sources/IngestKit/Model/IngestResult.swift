import Foundation

// Public, Codable output of an ingest. Stable shape: HorizonCore and the CLI both consume it.

public struct IngestResult: Codable, Sendable {
    public var document: DocumentInfo
    /// The platform a screenshot came from (the one platform its page names), nil for syllabi and other documents.
    public var sourcePlatform: Platform?
    public var route: ModelRoute
    public var course: ParsedCourse?
    public var gradeComponents: [ParsedGradeComponent]
    public var obligations: [ParsedObligation]
    public var policies: [ParsedPolicy]
    public var noClassDates: [ParsedNoClass]
    public var usage: UsageReport
    public var warnings: [String]

    public init(document: DocumentInfo, sourcePlatform: Platform? = nil, route: ModelRoute = .onDevice, course: ParsedCourse? = nil, gradeComponents: [ParsedGradeComponent] = [],
                obligations: [ParsedObligation] = [], policies: [ParsedPolicy] = [], noClassDates: [ParsedNoClass] = [],
                usage: UsageReport = UsageReport(calls: []), warnings: [String] = []) {
        self.document = document; self.sourcePlatform = sourcePlatform; self.route = route; self.course = course; self.gradeComponents = gradeComponents
        self.obligations = obligations; self.policies = policies; self.noClassDates = noClassDates; self.usage = usage; self.warnings = warnings
    }
}

public struct DocumentInfo: Codable, Sendable {
    public var name: String
    public var sha256: String
    public var kind: DocumentKind
    public var pageCount: Int
    public var ingestedAt: Date

    public init(name: String, sha256: String, kind: DocumentKind, pageCount: Int, ingestedAt: Date = Date()) {
        self.name = name; self.sha256 = sha256; self.kind = kind; self.pageCount = pageCount; self.ingestedAt = ingestedAt
    }
}

public enum DocumentKind: String, Codable, Sendable {
    case pdf, image, text, docx
}

/// Where a document was read or a plan made: Claude (the target), or the device's own model (small tasks, and the
/// fallback the user confirms when Claude cannot be reached).
public enum ModelRoute: String, Codable, Sendable {
    case onDevice, claude
}

public enum Platform: String, Codable, Sendable, CaseIterable {
    case lms, webAssign, gradescope, myLab, syllabusOnly
}

public struct ParsedCourse: Codable, Sendable {
    public var code: String?
    public var title: String?
    public var instructor: String?
    public var term: String?
    public var termStart: Date?
    public var termEnd: Date?
    public var room: String?
    public var meetings: [MeetingSlot]

    public init(code: String? = nil, title: String? = nil, instructor: String? = nil, term: String? = nil, termStart: Date? = nil, termEnd: Date? = nil, room: String? = nil, meetings: [MeetingSlot] = []) {
        self.code = code; self.title = title; self.instructor = instructor; self.term = term; self.termStart = termStart; self.termEnd = termEnd; self.room = room; self.meetings = meetings
    }
}

public struct MeetingSlot: Codable, Sendable, Equatable {
    /// 1 = Sunday … 7 = Saturday, matching `Calendar`.
    public var weekday: Int
    public var start: String?
    public var end: String?

    public init(weekday: Int, start: String? = nil, end: String? = nil) { self.weekday = weekday; self.start = start; self.end = end }
}

public struct ParsedGradeComponent: Codable, Sendable {
    public var name: String
    /// Fraction of the final grade, 0…1.
    public var weight: Double?
    public var expectedCount: Int?
    public var cadence: Cadence?
    public var dropLowest: Int?
    /// Where the document says the component's work lives ("Homework (WebAssign)"); nil when it says nothing.
    public var platform: Platform?

    public init(name: String, weight: Double? = nil, expectedCount: Int? = nil, cadence: Cadence? = nil, dropLowest: Int? = nil, platform: Platform? = nil) {
        self.name = name; self.weight = weight; self.expectedCount = expectedCount; self.cadence = cadence; self.dropLowest = dropLowest; self.platform = platform
    }
}

public enum Cadence: String, Codable, Sendable {
    case weekly, biweekly, once
}

public struct ParsedObligation: Codable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var platform: Platform
    public var componentName: String?
    public var dateAsWritten: String
    /// Local time. When `dueHasTime` is false the value is 23:59 local on the due day.
    public var due: Date?
    public var dueHasTime: Bool
    public var status: ObligationStatus
    /// 0…1. Below `IngestOptions.reviewThreshold` means `status == .needsReview`.
    public var confidence: Double
    public var flags: [ParseFlag]
    /// Percentage points of the final grade: component weight ÷ expected item count.
    public var pointsAtStake: Double?
    /// 0-based page of the source document the item was read from.
    public var sourcePage: Int

    public init(id: UUID = UUID(), title: String, platform: Platform = .syllabusOnly, componentName: String? = nil, dateAsWritten: String = "",
                due: Date?, dueHasTime: Bool = false, status: ObligationStatus, confidence: Double = 0.85, flags: [ParseFlag] = [],
                pointsAtStake: Double? = nil, sourcePage: Int = 0) {
        self.id = id; self.title = title; self.platform = platform; self.componentName = componentName; self.dateAsWritten = dateAsWritten
        self.due = due; self.dueHasTime = dueHasTime; self.status = status; self.confidence = confidence; self.flags = flags
        self.pointsAtStake = pointsAtStake; self.sourcePage = sourcePage
    }
}

public enum ObligationStatus: String, Codable, Sendable {
    case ready, needsReview, awaitingDate
}

public enum ParseFlag: String, Codable, Sendable {
    case dateNotInSource      // neither the copied wording nor the resolved date appears in the document text
    case conflictingDate      // the same item appears twice with different dates
    case dateAmbiguous        // the item's row lists several dates and the chosen one is the first, e.g. a session or release date
    case dateDisagreement     // model's ISO date and the deterministic re-parse of dateAsWritten differ
    case dateUnresolved       // a date was written but could not be resolved
    case titleNotInSource     // the document never prints this name and no line carrying the date labels it
    case titleFromLine        // the name was cut from the sentence that carries the date; check it reads well
    case dateNotOnRow         // the document names the item and the date, but never on the same line
    case dateOutsideTerm
    case unknownComponent     // component name matches no grade breakdown row
    case modelLowConfidence
}

public struct ParsedPolicy: Codable, Sendable {
    public var kind: PolicyKind
    public var text: String
    /// False when the model's quote could not be matched to the document's own sentences.
    public var verbatim: Bool

    public init(kind: PolicyKind, text: String, verbatim: Bool = true) { self.kind = kind; self.text = text; self.verbatim = verbatim }
}

public enum PolicyKind: String, Codable, Sendable {
    case lateWork, makeupExam, attendance, dropRule, extraCredit, other
}

public struct ParsedNoClass: Codable, Sendable {
    public var dateAsWritten: String
    public var start: Date
    public var end: Date?

    public init(dateAsWritten: String, start: Date, end: Date? = nil) { self.dateAsWritten = dateAsWritten; self.start = start; self.end = end }
}

public struct UsageReport: Codable, Sendable {
    public var calls: [UsageRecord]
    public var inputTokens: Int { calls.reduce(0) { $0 + $1.inputTokens } }
    public var outputTokens: Int { calls.reduce(0) { $0 + $1.outputTokens } }
    public var durationMs: Int { calls.reduce(0) { $0 + $1.durationMs } }

    enum CodingKeys: String, CodingKey { case calls, inputTokens, outputTokens, durationMs }
    public init(calls: [UsageRecord]) { self.calls = calls }
    public init(from decoder: any Decoder) throws {
        calls = try decoder.container(keyedBy: CodingKeys.self).decode([UsageRecord].self, forKey: .calls)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calls, forKey: .calls)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(durationMs, forKey: .durationMs)
    }
}

public struct UsageRecord: Codable, Sendable, Equatable {
    public var step: String
    public var chunk: Int
    public var route: ModelRoute
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var durationMs: Int

    public init(step: String, chunk: Int, route: ModelRoute, inputTokens: Int, cachedTokens: Int = 0, outputTokens: Int, reasoningTokens: Int = 0, durationMs: Int) {
        self.step = step; self.chunk = chunk; self.route = route; self.inputTokens = inputTokens; self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens; self.durationMs = durationMs
    }
}

public enum IngestError: Error, LocalizedError, Sendable {
    case unsupportedFile(String)
    case unreadable(String)
    case modelUnavailable(String)
    /// The on-device model exists but is not ready yet (assets loading): transient, retry later.
    case modelNotReady(String)
    /// Claude could not read this document now (no key, a rejected key, no connection, a rate limit, a timeout): the
    /// document waits for Claude, or for the user to have the device read it instead. Never a silent fallback.
    case claudeUnavailable(String)
    case emptyDocument
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext): "Unsupported file type: \(ext)"
        case .unreadable(let why): "Could not read document: \(why)"
        case .modelUnavailable(let why): "On-device model unavailable: \(why)"
        case .modelNotReady(let why): "On-device model not ready yet: \(why)"
        case .claudeUnavailable(let why): "Claude could not read the document: \(why)"
        case .emptyDocument: "Document has no readable text or images"
        case .extractionFailed(let why): "The model produced nothing for this document: \(why)"
        }
    }
}
