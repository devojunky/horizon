import SwiftUI
import SwiftData
import HorizonCore

/// SPEC §6.1: not a task list; where the app is probably blind, one course per story, most suspicious first.
/// Type carries the hierarchy: a sentence, two numbers, quiet detail. No cards, no badges, accent only for urgency.
struct CoverageList: View {
    /// A read is in progress: the empty-state invitation would contradict the live section above it.
    var reading = false
    @Query private var courses: [Course]
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query private var documents: [SourceDocument]

    private var stories: [CourseCoverage] {
        let live = obligations.map(ObligationSnapshot.init)
        let docs = documents.map(DocumentSnapshot.init)
        return courses.map { Coverage.assess(course: CourseSnapshot($0), obligations: live, documents: docs) }
            .sorted { $0.suspicion > $1.suspicion }
    }

    var body: some View {
        if courses.isEmpty, !reading {
            ContentUnavailableView("Nothing on file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Share a syllabus, a screenshot of an assignment list, or drop a file into Horizon Inbox on your Mac. Horizon will tell you where it is still blind."))
                .listRowSeparator(.hidden)
        }
        ForEach(stories) { story in
            NavigationLink { CourseView(course: courses.first { $0.id == story.course.id }!) } label: {
                CoverageStory(story: story)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
        }
    }
}

struct CoverageStory: View {
    let story: CourseCoverage

    private var urgent: Bool { story.suspicion >= 0.7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !story.course.title.isEmpty, !story.course.code.isEmpty {
                Text(story.course.title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.8)   // the kicker
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
                    ForEach(story.neverIngested.dropFirst(), id: \.self) { Text("Nothing has ever come from its \(Coverage.platformName($0))") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.title, design: .default, weight: .medium)).monospacedDigit().foregroundStyle(accent ? Design.accent : .primary)
            Text(label).font(.caption).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.6)
        }
    }
}

extension String {
    var prefixCapitalized: String { prefix(1).uppercased() + dropFirst() }
}
