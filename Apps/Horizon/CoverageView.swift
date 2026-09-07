import SwiftUI
import SwiftData
import HorizonCore

/// SPEC §6.1: not a task list; where the app is probably blind, one course per story, most suspicious first.
/// Type carries the hierarchy: a sentence, two numbers, quiet detail. No cards, no badges, accent only for urgency.
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

    /// The user's own order first; courses without one follow, most suspicious first.
    private var stories: [CourseCoverage] {
        let live = obligations.map(ObligationSnapshot.init)
        let docs = documents.map(DocumentSnapshot.init)
        let assessed = courses.map { Coverage.assess(course: CourseSnapshot($0), obligations: live, documents: docs) }
        return assessed.sorted { a, b in
            switch (a.course.sortOrder, b.course.sortOrder) {
            case (let x?, let y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.suspicion > b.suspicion
            }
        }
    }

    var body: some View {
        if courses.isEmpty, !reading, !hasUnfiled {
            EditorialEmpty(title: "Nothing on file.", deck: "Add a syllabus, a schedule, or a screenshot of an assignment list. Horizon reads it, writes the deadlines to Reminders, and tells you where it is still blind.") {
                ImportMenu().buttonStyle(.borderedProminent)
            }
            .listRowSeparator(.hidden)
            .onPaper()
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        }
        ForEach(stories) { story in
            Button { open(.course(story.course.id)) } label: {
                HStack(spacing: 12) {
                    CoverageStory(story: story)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the course")
            .listRowSeparator(.visible)
            .onPaper()
            .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
        }
        .onMove { from, to in
            var order = stories.map(\.course.id)
            order.move(fromOffsets: from, toOffset: to)
            Task { await model.reorderCourses(order) }
        }
        .onDelete { offsets in   // straight to Recently Deleted, where it can be restored for 30 days: no dialog
            for story in offsets.map({ stories[$0] }) { Task { await model.deleteCourse(story.course.id) } }
        }
    }
}

struct CoverageStory: View {
    let story: CourseCoverage

    private var urgent: Bool { story.suspicion >= 0.7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !story.course.title.isEmpty, !story.course.code.isEmpty {
                Kicker(story.course.code)   // the sentence names the course
            }
            Text(story.headline)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                figure(story.daysSilent.map(String.init) ?? "—", label: "days silent", accent: (story.daysSilent ?? 99) >= 7)
                figure(String(story.upcoming14), label: "next 14 days", accent: false)
            }
            .padding(.top, 2)
            if !story.cadenceGaps.dropFirst().isEmpty || story.neverIngested.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(story.cadenceGaps.dropFirst().enumerated()), id: \.offset) { Text($0.element.sentence.prefixCapitalized) }
                    ForEach(story.neverIngested.dropFirst(), id: \.platform) { Text($0.sentence(name: story.displayName, first: false).prefixCapitalized) }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).numeral().foregroundStyle(accent ? Design.accent : .primary).contentTransition(.numericText())
            Kicker(label)
        }
    }
}

extension String {
    var prefixCapitalized: String { prefix(1).uppercased() + dropFirst() }
}
