import SwiftUI
import SwiftData
import HorizonCore

extension Coverage {
    /// Every course's story, in the order courses are shown in everywhere (Coverage, and the Mac's sidebar): the
    /// user's own first; courses without one follow, most suspicious first.
    @MainActor static func stories(courses: [Course], obligations: [Obligation], documents: [SourceDocument]) -> [CourseCoverage] {
        let live = obligations.map(ObligationSnapshot.init)
        let docs = documents.map(DocumentSnapshot.init)
        let assessed = courses.map { assess(course: CourseSnapshot($0), obligations: live, documents: docs) }
        return assessed.sorted { a, b in
            switch (a.course.sortOrder, b.course.sortOrder) {
            case (let x?, let y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.suspicion > b.suspicion
            }
        }
    }
}

#if os(iOS)
/// SPEC §6.1: not a task list; where the app is probably blind, one course per story, most suspicious first.
/// Type carries the hierarchy: the course's name, a short line per finding, the figures quiet under them. No cards, no
/// badges. (The Mac sets the stories side by side: `MacCoveragePage`.)
struct CoverageList: View {
    /// A read is in progress: the empty-state invitation would contradict the live section above it.
    var reading = false
    /// Documents with items but no course are on file: not nothing, even with no course yet.
    var hasUnfiled = false
    /// Pushes a course page (the home stack's guarded push).
    var open: (Route) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }) private var courses: [Course]
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]

    private var stories: [CourseCoverage] { Coverage.stories(courses: courses, obligations: obligations, documents: documents) }

    var body: some View {
        if courses.isEmpty, !reading, !hasUnfiled {
            EditorialEmpty(title: "Nothing on file.", deck: "Add a syllabus, a schedule, or a screenshot of an assignment list. Horizon reads it, writes the deadlines to Reminders, and tells you where it is still blind.") {
                ImportMenu().buttonStyle(.borderedProminent)
            }
            .listRowSeparator(.hidden)
            .onPaper()
            .pageRow(top: 8, bottom: 8)
        }
        ForEach(stories) { story in
            Button { open(.course(story.course.id)) } label: {
                CoverageStory(story: story, disclosure: true).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the course")
            .listRowSeparator(.visible)
            .onPaper()
            .pageRow(top: 18, bottom: 18)
        }
        .onMove { from, to in
            var order = stories.map(\.course.id)
            order.move(fromOffsets: from, toOffset: to)
            Task { await model.reorderCourses(order) }
        }
        .onDelete { offsets in   // straight to Recently Deleted, where it can be restored for 30 days: no dialog
            for story in offsets.map({ stories[$0] }) { Task { await model.deleteCourse(story.course.id) } }
        }
        .animation(.default, value: stories.map(\.id))         // a course moving up or down the page as its story changes moves there, animated
        .animation(.default, value: stories.map(\.findings))   // a finding coming or going grows or shrinks its row, animated
    }
}
#endif

/// One course, read top to bottom like a list row (HIG: the name to scan by, then what matters, then the quiet
/// detail): its code, its name, what says the app may be blind there (one short line each), and its figures.
struct CoverageStory: View {
    let story: CourseCoverage
    /// The row opens the course's page (on a Mac, its place in the sidebar), so the name carries the chevron.
    var disclosure = false

    /// The code over the name, when the course has both.
    private var code: String? { story.course.title.isEmpty || story.course.code.isEmpty ? nil : story.course.code }
    /// The findings a step under body on iOS; the Mac's text styles run about 4 points smaller, so there they are body.
    #if os(macOS)
    static let findingFont = Font.body, factsFont = Font.subheadline
    #else
    static let findingFont = Font.subheadline, factsFont = Font.footnote
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let code { Kicker(code).padding(.bottom, 4) }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(story.displayName).font(.system(.title3, design: .serif, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if disclosure { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            CoverageFindings(story: story).padding(.top, 8)
        }
        // One sentence for VoiceOver, the figures after it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(story.headline)
        .accessibilityValue(story.facts.joined(separator: ", "))
    }
}

/// What a story says under its course's name: one short line per finding ("Looks covered." when there is none),
/// then the figures, quiet. Coverage's rows and, on a Mac, the head of a course's page.
struct CoverageFindings: View {
    let story: CourseCoverage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if story.findings.isEmpty {
                    Text("Looks covered.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(story.findings.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            .font(CoverageStory.findingFont)
            .fixedSize(horizontal: false, vertical: true)
            Facts(parts: story.facts).padding(.top, 10)
        }
    }
}

/// The figures on one quiet line, broken between figures, never inside one, when the line runs out.
private struct Facts: View {
    let parts: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(parts.joined(separator: " · ")).lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.dropLast().joined(separator: " · ")).lineLimit(1)
                Text(parts.last ?? "").lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) { ForEach(parts, id: \.self) { Text($0) } }
        }
        .font(CoverageStory.factsFont)
        .foregroundStyle(.secondary)
    }
}
