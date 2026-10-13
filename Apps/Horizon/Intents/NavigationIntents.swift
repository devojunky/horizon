import AppIntents
import Foundation
import HorizonCore

// Opening a place in the app: what a tapped Spotlight or Siri result does, what "show me Calc in Horizon" does, and what
// a control or a shortcut can do in one step. Each goes through `AppModel.navigate(to:)`, as links do. One `OpenIntent`
// per kind of thing, as Apple's own apps have (Notes: Open Note, Open Folder, … and Open Notes View for its places):
// Spotlight opens a tapped result through the `OpenIntent` of its type, so each kind keeps its own, and the pages are
// one, their page a parameter.

/// Opens an item: Siri's "open this", a tapped result. The system's open schema allows one type per app, and the item is
/// what Siri's answers are made of; courses, policies and documents open with intents of their own below.
@AppIntent(schema: .system.open)
struct OpenItemIntent: OpenIntent {
    static let description = IntentDescription("Opens an item in Horizon.", categoryName: "Items")
    var target: ItemEntity
    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try model.requireLibrary()
        model.navigate(to: .item(target.id))
        return .result()
    }
}

struct OpenCourseIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Course"
    static let description = IntentDescription("Opens a course's page: its grade table, its work, its policies and its documents.", categoryName: "Courses")
    @Parameter(title: "Course") var target: CourseEntity
    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try model.requireLibrary()
        model.navigate(to: target.isUnfiled ? .page(.coverage) : .course(target.id))
        return .result()
    }
}

struct OpenPolicyIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Policy"
    static let description = IntentDescription("Opens the course a policy belongs to, at its policies.", categoryName: "Courses")
    @Parameter(title: "Policy") var target: PolicyEntity
    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try model.requireLibrary()
        guard let course = target.folder?.id else { throw IntentFailure.message("That policy has no course.") }
        model.navigate(to: .policies(course: course))
        return .result()
    }
}

struct OpenDocumentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Document"
    static let description = IntentDescription("Opens a document Horizon read, in Quick Look.", categoryName: "Documents")
    @Parameter(title: "Document") var target: DocumentEntity
    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try model.requireLibrary()
        model.navigate(to: .document(target.id))
        return .result()
    }
}

/// The app's pages, for "Open Coverage", the Action button, a shortcut.
extension AppPage: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .coverage: DisplayRepresentation(title: "Coverage", synonyms: ["where Horizon is blind", "my courses"]),
        .horizon: DisplayRepresentation(title: "Horizon", synonyms: ["the semester", "the strip", "the term"]),
        .now: DisplayRepresentation(title: "Now", synonyms: ["today's plan", "my day"]),
        .review: DisplayRepresentation(title: "Review", synonyms: ["items to review"]),
        .documents: "Documents",
        .recentlyDeleted: "Recently Deleted",
        .settings: "Settings",
        .search: "Search",
    ]
}

/// A page of the app (Apple's "Open Notes View"): Coverage, Now, Review…, and Horizon's strip, which can also be
/// narrowed to a course and opened at a day ("show me Calc's next two weeks on Horizon").
struct OpenPageIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Page"
    static let description = IntentDescription("Opens one of Horizon's pages: Coverage, Horizon, Now, Review, Documents, Recently Deleted, Settings or Search. Horizon, the semester strip, can open at a day and narrowed to a course.")
    @Parameter(title: "Page") var target: AppPage
    @Parameter(title: "Course", description: "For Horizon: the one course it shows.") var course: CourseEntity?
    @Parameter(title: "Day", description: "For Horizon: the day it opens at.", kind: .date) var day: DateComponents?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary {
        When(\.$target, .equalTo, .horizon) {
            Summary("Open \(\.$target) at \(\.$day) for \(\.$course)")
        } otherwise: {
            Summary("Open \(\.$target)")
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        try model.requireLibrary()
        if target == .horizon, course != nil || day != nil {
            let date = day.flatMap { ItemSeries.due(from: $0, now: .now, calendar: .current)?.date }
            model.navigate(to: .horizon(course: course.flatMap { $0.isUnfiled ? nil : $0.id }, day: date))
        } else {
            model.navigate(to: .page(target))
        }
        return .result()
    }
}

/// Siri's and Spotlight's "search Horizon for…": the app's own search, in the app, over items, courses, policies and
/// documents (`HorizonSearch`).
@AppIntent(schema: .system.searchInApp)
struct SearchHorizonIntent: ShowInAppSearchResultsIntent {
    static let description = IntentDescription("Searches Horizon's items, courses, policies and documents.")
    static let searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria
    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        try model.requireLibrary()
        model.navigate(to: .search(criteria.term))
        return .result()
    }
}

/// Where Read Document opens to choose a document when it's handed none: the files, the screenshots in Photos, Photos,
/// or the camera. Reading what's chosen is the user's tap there; nothing is read unseen.
extension ImportChoice: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .files: DisplayRepresentation(title: "Files", image: .init(systemName: "folder"), synonyms: ["a file", "a syllabus", "a document", "a PDF"]),
        .photos: DisplayRepresentation(title: "Photos", image: .init(systemName: "photo"), synonyms: ["a photo", "a picture"]),
        .screenshots: DisplayRepresentation(title: "Screenshots", image: .init(systemName: "camera.viewfinder"), synonyms: ["a screenshot", "my screenshot", "my last screenshot"]),
        .camera: DisplayRepresentation(title: "Camera", image: .init(systemName: "doc.viewfinder"), synonyms: ["a scan", "the camera", "a page"]),
    ]
}
