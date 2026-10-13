import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import GeoToolbox
import HorizonCore
import IngestKit

// What Horizon holds, described for Siri, Shortcuts and Spotlight (SPEC §7). Siri understands an app's content only
// through the system's schemas (WWDC26 "Build intelligent Siri experiences with App Schemas"), and none is about
// coursework, so each kind of content borrows the schema whose meaning it shares: an item is a reminder (Horizon writes
// every one to Reminders, with its date, its notes and its check), a course is a list of them, a grade row a section of
// a list, a policy a note quoted from the course's documents. Siri then reads and acts on them in its own words ("push
// this to Sunday", "what's the makeup policy for Calc?"); the properties beyond the schema (weight, grade row, site) are
// for Shortcuts and Spotlight, which see them, where Siri does not. Documents and the day's plan have no schema that
// fits and stay Horizon's own.

// MARK: Courses

/// A course, as a list of reminders: the "list" Siri files a new item in ("add a quiz to Calc").
@AppEntity(schema: .reminders.list)
struct CourseEntity: IndexedEntity {
    static let defaultQuery = CourseQuery()

    let id: UUID
    var name: String
    var type: CourseListType
    @Property(title: "Code") var code: String
    @Property(title: "Term") var term: String?
    @Property(title: "Instructor") var instructor: String?

    var displayRepresentation: DisplayRepresentation {
        let detail = [code == name ? nil : code, term].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(name)", subtitle: detail.isEmpty ? nil : "\(detail)", image: .init(systemName: "book.closed"))
    }

    /// Items filed under no course still belong to a list: this one.
    static let unfiledID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let unfiled = CourseEntity(id: unfiledID, name: "No Course", type: .standard, code: "", term: nil, instructor: nil)
    var isUnfiled: Bool { id == Self.unfiledID }

    init(id: UUID, name: String, type: CourseListType = .standard, code: String, term: String?, instructor: String?) {
        self.id = id; self.name = name; self.type = type; self.code = code; self.term = term; self.instructor = instructor
    }

    init(_ c: CourseSnapshot) {
        self.init(id: c.id, name: c.displayName, code: c.code, term: c.term, instructor: c.instructor)
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.keywords = [code, term, instructor].compactMap { $0 }.filter { !$0.isEmpty }
        return set
    }
}

@AppEnum(schema: .reminders.listType)
enum CourseListType: String {
    case standard
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Course"]
}

struct CourseQuery: EntityStringQuery, EnumerableEntityQuery {
    @Dependency var model: AppModel

    @MainActor func entities(for identifiers: [CourseEntity.ID]) async throws -> [CourseEntity] {
        let courses = try await model.intentCourses()
        return identifiers.compactMap { id in id == CourseEntity.unfiledID ? .unfiled : courses.first { $0.id == id }.map(CourseEntity.init) }
    }

    /// "Calc", "calculus 2", "MA 1124": the courses the words name, best first (`CourseMatch`).
    @MainActor func entities(matching string: String) async throws -> [CourseEntity] {
        CourseMatch.ranked(string, in: try await model.intentCourses()).map(CourseEntity.init)
    }

    /// In the user's own order, the order of the Mac's sidebar and of Coverage once they have set one.
    @MainActor func allEntities() async throws -> [CourseEntity] {
        try await model.intentCourses().map(CourseEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [CourseEntity] { try await allEntities() }
}

// MARK: Items

/// An item: something graded with a date, as a reminder (Horizon's copy of the one it keeps in Reminders).
@AppEntity(schema: .reminders.reminder)
struct ItemEntity: IndexedEntity {
    static let defaultQuery = ItemQuery()

    let id: UUID
    var title: String
    var note: AttributedString?
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool
    var isFlagged: Bool?
    var creationDate: Date?
    var completionDate: Date?
    var list: CourseEntity
    var locationTrigger: PlaceTriggerEntity?

    /// The share of the final grade, in percentage points.
    @Property(title: "Weight") var weight: Double?
    /// The grade breakdown row it counts toward ("Homework").
    @Property(title: "Counts Toward") var gradeRow: String?
    /// Where the work is handed in, when the documents say ("WebAssign").
    @Property(title: "Site") var site: String?
    /// To do, done, waiting for the user's look in Review, or waiting for a date.
    @Property(title: "Status") var status: ItemStatus
    /// The due moment as a date, for Shortcuts' filters and sorts (`dueDate` is the schema's components), and Spotlight's.
    @Property(title: "Due", indexingKey: \.dueDate) var due: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(Design.itemLine(course: list.isUnfiled ? nil : list.name, due: due, hasTime: dueDate?.hour != nil, weight: weight))",
                              image: .init(systemName: isCompleted ? "checkmark.circle" : "circle"))
    }

    init(_ o: ObligationSnapshot, course: CourseSnapshot?, calendar: Calendar = .current) {
        id = o.id
        title = o.title
        note = o.notes.flatMap { $0.isEmpty ? nil : AttributedString($0) }
        tags = []
        urls = [o.link]
        dueDate = o.due.map { calendar.dateComponents(o.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: $0) }
        recurrence = nil
        isCompleted = o.completedAt != nil
        isFlagged = nil
        creationDate = nil
        completionDate = o.completedAt
        list = course.map(CourseEntity.init) ?? .unfiled
        locationTrigger = nil
        weight = o.pointsAtStake
        gradeRow = o.componentName
        site = o.platform == .syllabusOnly ? nil : Coverage.platformName(o.platform)
        status = ItemStatus(o)
        due = o.due
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.contentDescription = Design.itemLine(course: list.isUnfiled ? nil : list.name, due: due, hasTime: dueDate?.hour != nil, weight: weight)
        set.keywords = [list.isUnfiled ? nil : list.name, list.code, gradeRow, site].compactMap { $0 }.filter { !$0.isEmpty }
        return set
    }
}

/// Where an item stands, as people say it.
enum ItemStatus: String, AppEnum {
    case toDo, done, inReview, awaitingDate
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Status"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .toDo: "To Do", .done: "Done", .inReview: "Waiting for Review", .awaitingDate: "Waiting for a Date",
    ]
    init(_ o: ObligationSnapshot) {
        self = o.completedAt != nil ? .done : o.state == .pendingReview ? .inReview : o.due == nil ? .awaitingDate : .toDo
    }
}

struct ItemQuery: EntityStringQuery {
    @Dependency var model: AppModel

    @MainActor func entities(for identifiers: [ItemEntity.ID]) async throws -> [ItemEntity] {
        let (items, courses) = try await model.intentItems()
        let wanted = Set(identifiers)
        return items.filter { wanted.contains($0.id) }.map { ItemEntity($0, course: $0.courseID.flatMap { courses[$0] }) }
    }

    /// Every word must start a word of the item's name, course or grade row ("calc quiz", "lab 3"), the search's rule.
    @MainActor func entities(matching string: String) async throws -> [ItemEntity] {
        let (items, courses) = try await model.intentItems()
        let found = HorizonSearch.run(string, items: items, courses: Array(courses.values), policies: [], documents: []).items
        return found.map { ItemEntity($0, course: $0.courseID.flatMap { courses[$0] }) }
    }

    /// What is coming up, nearest first: what a person most likely means.
    @MainActor func suggestedEntities() async throws -> [ItemEntity] {
        let (items, courses) = try await model.intentItems()
        let ahead = DueQuery.items(items, in: DuePeriod.nextTwoWeeks.interval(at: .now, calendar: .current))
        return ahead.prefix(20).map { ItemEntity($0, course: $0.courseID.flatMap { courses[$0] }) }
    }
}

/// A grade breakdown row, as a section of a course's list ("add it under Quizzes").
@AppEntity(schema: .reminders.section)
struct GradeRowEntity {
    static let defaultQuery = GradeRowQuery()
    /// "<course id>|<row name>": a row has no identity of its own.
    let id: String
    var name: String
    var list: CourseEntity

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(list.name)") }

    init(course: CourseSnapshot, row: GradeComponent) {
        id = "\(course.id.uuidString)|\(row.name)"; name = row.name; list = CourseEntity(course)
    }
}

struct GradeRowQuery: EntityStringQuery {
    @Dependency var model: AppModel

    @MainActor func entities(for identifiers: [GradeRowEntity.ID]) async throws -> [GradeRowEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    /// "quizzes", "calc homework": the rows whose name (and course) the words start.
    @MainActor func entities(matching string: String) async throws -> [GradeRowEntity] {
        let words = HorizonSearch.terms(string)
        return try await suggestedEntities().filter { row in
            let named = HorizonSearch.terms(row.name + " " + row.list.name + " " + row.list.code)
            return words.allSatisfy { word in named.contains { $0.hasPrefix(word) || ItemSeries.component(for: word, in: [GradeComponent(name: row.name)]) != nil } }
        }
    }

    @MainActor func suggestedEntities() async throws -> [GradeRowEntity] {
        try await model.intentCourses().flatMap { course in course.gradeComponents.map { GradeRowEntity(course: course, row: $0) } }
    }
}

/// The reminders schema's place trigger. Horizon's items are due at a time, not at a place: no item has one, and an
/// intent asked for one says so.
@AppEntity(schema: .reminders.locationTrigger)
struct PlaceTriggerEntity {
    static let defaultQuery = PlaceTriggerQuery()
    let id: String
    var place: PlaceDescriptor
    var event: PlaceTriggerEvent
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(place.commonName ?? "A place")") }
}

@AppEnum(schema: .reminders.locationTriggerEvent)
enum PlaceTriggerEvent: String {
    case arrive, depart
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.arrive: "Arriving", .depart: "Leaving"]
}

struct PlaceTriggerQuery: EntityStringQuery {
    func entities(for identifiers: [PlaceTriggerEntity.ID]) async throws -> [PlaceTriggerEntity] { [] }
    func entities(matching string: String) async throws -> [PlaceTriggerEntity] { [] }   // none: no item is due at a place
}

// MARK: Policies

/// A policy quoted from a course's documents (late work, makeup exams, attendance, dropped scores, extra credit), as a
/// note in the course's folder: its text is the syllabus's own, never a paraphrase (SPEC §5), so Siri answers "what's
/// the makeup policy for Calc?" with the document's words.
@AppEntity(schema: .notes.note)
struct PolicyEntity: IndexedEntity {
    static let defaultQuery = PolicyQuery()

    let id: UUID
    var name: AttributedString
    var content: AttributedString?
    var attachments: [IntentFile]
    var isPinned: Bool
    var creationDate: Date?
    var modificationDate: Date?
    var folder: CourseFolderEntity?

    @Property(title: "Kind") var kind: PolicyTopic
    /// The text as the documents print it, plain (`content` carries it for Siri), and what Spotlight's semantic index
    /// reads of the policy: Siri answers a question about it from there.
    @Property(title: "Text", indexingKey: \.textContent) var text: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(name.characters))", subtitle: "\(folder?.name ?? "")", image: .init(systemName: "text.quote"))
    }

    init(_ p: PolicySnapshot) {
        id = p.id
        name = AttributedString(PolicyLookup.name(p.kind))
        content = AttributedString(p.text)
        attachments = []
        isPinned = false
        creationDate = nil
        modificationDate = nil
        folder = p.courseID.map { CourseFolderEntity(id: $0, name: p.courseName ?? "") }
        kind = PolicyTopic(p.kind)
        text = p.text
    }

    /// The text itself comes from `text`'s indexing key; the description shows it under the title in Spotlight.
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.contentDescription = text
        set.keywords = [folder?.name, PolicyLookup.name(kind.kind)].compactMap { $0 }
        return set
    }
}

/// The course a policy belongs to, as the folder its note sits in.
@AppEntity(schema: .notes.folder)
struct CourseFolderEntity {
    static let defaultQuery = CourseFolderQuery()
    let id: UUID
    var name: String
    var parentFolder: CourseFolderEntity?
    var account: HorizonAccountEntity?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", image: .init(systemName: "book.closed")) }

    init(id: UUID, name: String) { self.id = id; self.name = name; parentFolder = nil; account = nil }
}

struct CourseFolderQuery: EntityQuery {
    @Dependency var model: AppModel
    @MainActor func entities(for identifiers: [CourseFolderEntity.ID]) async throws -> [CourseFolderEntity] {
        try await model.intentCourses().filter { identifiers.contains($0.id) }.map { CourseFolderEntity(id: $0.id, name: $0.displayName) }
    }
    @MainActor func suggestedEntities() async throws -> [CourseFolderEntity] {
        try await model.intentCourses().map { CourseFolderEntity(id: $0.id, name: $0.displayName) }
    }
}

/// The notes schema's account a folder may belong to; Horizon keeps no accounts, and no folder names one.
@AppEntity(schema: .notes.account)
struct HorizonAccountEntity {
    static let defaultQuery = HorizonAccountQuery()
    let id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct HorizonAccountQuery: EntityQuery {
    func entities(for identifiers: [HorizonAccountEntity.ID]) async throws -> [HorizonAccountEntity] { [] }
}

/// What a policy is about.
enum PolicyTopic: String, AppEnum {
    case lateWork, makeupExams, attendance, droppedScores, extraCredit, other
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Policy"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .lateWork: DisplayRepresentation(title: "Late Work", synonyms: ["late", "extensions", "late penalty"]),
        .makeupExams: DisplayRepresentation(title: "Makeup Exams", synonyms: ["makeups", "test makeups", "missed exams", "makeup tests"]),
        .attendance: DisplayRepresentation(title: "Attendance", synonyms: ["absences"]),
        .droppedScores: DisplayRepresentation(title: "Dropped Scores", synonyms: ["drops", "lowest score dropped"]),
        .extraCredit: DisplayRepresentation(title: "Extra Credit", synonyms: ["bonus"]),
        .other: "Other",
    ]
    init(_ kind: PolicyKind) {
        self = switch kind {
        case .lateWork: .lateWork
        case .makeupExam: .makeupExams
        case .attendance: .attendance
        case .dropRule: .droppedScores
        case .extraCredit: .extraCredit
        case .other: .other
        }
    }
    var kind: PolicyKind {
        switch self {
        case .lateWork: .lateWork
        case .makeupExams: .makeupExam
        case .attendance: .attendance
        case .droppedScores: .dropRule
        case .extraCredit: .extraCredit
        case .other: .other
        }
    }
}

struct PolicyQuery: EntityStringQuery {
    @Dependency var model: AppModel

    @MainActor func entities(for identifiers: [PolicyEntity.ID]) async throws -> [PolicyEntity] {
        try await model.intentPolicies().filter { identifiers.contains($0.id) }.map(PolicyEntity.init)
    }

    /// "makeup exams calc", "late work": the policies the words are about, best first (`PolicyLookup`).
    @MainActor func entities(matching string: String) async throws -> [PolicyEntity] {
        let policies = try await model.intentPolicies()
        let courses = try await model.intentCourses()
        // A course's name among the words narrows to that course; the rest says which policy.
        let named = courses.first { course in CourseMatch.score(string, name: course.title, code: course.code) > 0.5 ||
            string.split(separator: " ").contains { CourseMatch.score(String($0), name: course.title, code: course.code) >= 0.7 } }
        let pool = named.map { course in policies.filter { $0.courseID == course.id } } ?? policies
        return PolicyLookup.answers(string, in: pool).map(PolicyEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [PolicyEntity] {
        try await model.intentPolicies().map(PolicyEntity.init)
    }
}

// MARK: Documents

/// A document Horizon read (or will read): a syllabus, a schedule, a screenshot of an assignment list.
struct DocumentEntity: AppEntity, IndexedEntity {
    static let defaultQuery = DocumentQuery()
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Document", numericFormat: "\(placeholder: .int) documents")

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Course") var course: String?
    @Property(title: "Status") var status: String
    @Property(title: "Read") var read: Date?
    /// The file's own name, as it was shared.
    var filename: String
    var kind: String
    var sha256: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\([course, status].compactMap { $0 }.joined(separator: " · "))", image: .init(systemName: "doc.text"))
    }

    init(_ d: DocumentSnapshot, course: String?) {
        id = d.id; filename = d.filename; kind = d.kind; sha256 = d.sha256   // the plain fields first: a property's setter needs the rest in place
        name = d.displayName; self.course = course; read = d.ingestedAt
        status = switch d.status {
        case .parsed: "Read"
        case .queued: "Waiting to be read"
        case .awaitingCloudParse: "Waiting for Claude"
        case .failed: "Could not be read"
        case .cancelled: "Cancelled"
        }
    }
}

struct DocumentQuery: EntityStringQuery {
    @Dependency var model: AppModel

    @MainActor func entities(for identifiers: [DocumentEntity.ID]) async throws -> [DocumentEntity] {
        try await model.intentDocuments().filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [DocumentEntity] {
        let documents = try await model.intentDocuments()
        let words = string.lowercased().split(separator: " ").map(String.init)
        return documents.filter { document in
            let haystack = [document.name, document.course ?? "", document.filename].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    @MainActor func suggestedEntities() async throws -> [DocumentEntity] { try await model.intentDocuments() }
}

extension DocumentEntity: Transferable {
    /// The document itself, for "send the Calc syllabus to…": a copy named as the app names it.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { document in
            guard let url = await MainActor.run(body: { AppModel.current?.exportFile(sha256: document.sha256, kind: document.kind, name: document.name) }) else {
                throw IntentFailure.message("That document's file is not on this device.")
            }
            return SentTransferredFile(url)
        }
    }
}

// MARK: The day's plan

/// A block of today's plan: work, study, a meal, a rest, or an event from the calendar. Lives as long as the plan does.
struct PlanBlockEntity: AppEntity {
    static let defaultQuery = PlanBlockQuery()
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Plan Block", numericFormat: "\(placeholder: .int) blocks")

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Start") var start: Date
    @Property(title: "End") var end: Date
    @Property(title: "Why") var reason: String
    @Property(title: "Done") var isDone: Bool
    @Property(title: "Set Aside") var isSkipped: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))",
                              image: .init(systemName: isDone ? "checkmark.circle" : "clock"))
    }

    init(_ b: PlanBlock) {
        id = b.id; title = b.title; start = b.start; end = b.end; reason = b.reason; isDone = b.isDone; isSkipped = b.isSkipped
    }
}

struct PlanBlockQuery: EntityQuery {
    @Dependency var model: AppModel

    @MainActor func entities(for identifiers: [PlanBlockEntity.ID]) async throws -> [PlanBlockEntity] {
        (model.plan?.blocks ?? []).filter { identifiers.contains($0.id) }.map(PlanBlockEntity.init)
    }

    /// The day's blocks still open, from the one on now.
    @MainActor func suggestedEntities() async throws -> [PlanBlockEntity] {
        (model.plan?.blocks ?? []).filter { $0.isOpen && $0.end > .now }.map(PlanBlockEntity.init)
    }
}
