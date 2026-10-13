#if os(macOS)
import SwiftUI
import SwiftData
import HorizonCore

/// Coverage on a Mac (SPEC §6.1): the stories side by side, as many columns as the window holds, in the user's order
/// (the sidebar's), else most suspicious first. A phone reads them down one column; a window sets them like a front page, so every course is in view at
/// once. Each story has, under its figures, its term week by week: a week with something on file is a cell in the
/// strip's colour (deeper as more of the grade is at stake), a week with nothing an empty one, so where the app may be
/// blind shows before a word of it is read. A story opens its course (the sidebar follows); its menu edits or deletes it.
struct MacCoveragePage: View {
    @Bindable var nav: MacNavigation
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }) private var courses: [Course]
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]

    var body: some View {
        let stories = Coverage.stories(courses: courses, obligations: obligations, documents: documents)
        let span = TermWeeks.span(courses: courses, obligations: obligations)   // one term for every band, so the weeks line up from story to story
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IntakeStatus(openDocuments: { nav.show(.documents) }, openSettings: { openSettings() })
                    .padding(.horizontal, 8)   // on the margin, with the stories' words
                    .padding(.bottom, 8)
                if stories.isEmpty, model.reading == nil {
                    EditorialEmpty(title: "Nothing on file.", deck: "Add a syllabus, a schedule, or a screenshot of an assignment list, or drop one on this window. Horizon reads it, writes the deadlines to Reminders, and tells you where it is still blind.") {
                        ImportMenu().buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 28, alignment: .topLeading)], alignment: .leading, spacing: 28) {
                    ForEach(stories) { story in
                        StoryCard(story: story, weeks: TermWeeks(course: courses.first { $0.id == story.course.id }, obligations: obligations, span: span),
                                  open: { nav.show(course: story.course.id) })
                            .contextMenu {
                                Button("Open") { nav.show(course: story.course.id) }
                                Button("Add Item…") { nav.addingItemTo = story.course.id; nav.addingItem = true }
                                Button("Edit Course…") { nav.editingCourse = story.course.id }
                                Divider()
                                Button("Delete Course", role: .destructive) { Task { await model.deleteCourse(story.course.id) } }
                            }
                    }
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, Design.margin - 8)   // a card's own inset brings its words to the margin
            .padding(.vertical, 12)
        }
        .background(Design.paper)
        .animation(.default, value: stories.map(\.id))
        // A banner at the head of the page (the read, the sync's line, waiting for Claude, Reminders off) pushes the
        // stories down animated, not in one frame.
        .animation(.default, value: model.reading != nil)
        .animation(.default, value: model.statusLine)
        .animation(.default, value: model.lastError)
        .animation(.default, value: model.remindersAuthorized)
        .animation(.default, value: model.remindersListGone)
        .animation(.default, value: documents.map(\.status))
        .navigationTitle("Coverage")
    }
}

/// One course's story as a card on the front page: its code, its name, a line per finding, its figures, and its term
/// week by week. The whole card opens the course; the pointer lights it first.
private struct StoryCard: View {
    let story: CourseCoverage
    let weeks: TermWeeks
    var open: () -> Void
    @State private var hovering = false

    private var code: String? { story.course.title.isEmpty || story.course.code.isEmpty ? nil : story.course.code }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                if let code { Kicker(code).padding(.bottom, 4) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(story.displayName).font(.system(.title2, design: .serif, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
                }
                CoverageFindings(story: story).padding(.top, 10)
                if !weeks.cells.isEmpty { WeekBand(weeks: weeks).padding(.top, 16) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(story.headline)
        .accessibilityValue(([weeks.summary] + story.facts).joined(separator: ", "))
        .accessibilityHint("Opens the course")
        .accessibilityAddTraits(.isButton)
    }
}

/// A course's term, week by week: what it has on file in each, for the band under its story.
struct TermWeeks {
    struct Week: Identifiable {
        var id: Date { period.start }
        var period: DateInterval
        var count: Int
        var points: Double
        var past: Bool
        var current: Bool
    }
    var cells: [Week] = []

    /// The term every band shares: the span the Horizon strip draws, from every course and every dated item.
    @MainActor static func span(courses: [Course], obligations: [Obligation], calendar: Calendar = .current, now: Date = Date()) -> ClosedRange<Date> {
        Strip.span(termStarts: courses.compactMap(\.termStart), termEnds: courses.compactMap(\.termEnd), items: obligations.compactMap(item), now: now, calendar: calendar)
    }

    @MainActor private static func item(_ o: Obligation) -> StripItem? {
        guard let due = o.due else { return nil }
        return StripItem(id: o.id, title: o.title, courseID: o.course?.id, courseCode: o.course?.code ?? "", courseName: o.course?.title, due: due, dueHasTime: o.dueHasTime,
                         points: o.pointsAtStake, state: o.state, completed: o.completedAt != nil)
    }

    @MainActor init(course: Course?, obligations: [Obligation], span: ClosedRange<Date>, calendar: Calendar = .current, now: Date = Date()) {
        guard let course else { return }
        let items = obligations.filter { $0.course?.id == course.id }.compactMap(Self.item)
        let byWeek = Dictionary(uniqueKeysWithValues: Strip.cells(items, level: .weeks, calendar: calendar).map { ($0.period.start, $0) })
        cells = Strip.periods(in: span, level: .weeks, calendar: calendar).map { period in
            let cell = byWeek[period.start]
            return Week(period: period, count: cell?.count ?? 0, points: cell?.items.reduce(0) { $0 + ($1.points ?? 0) } ?? 0,
                        past: period.end <= now, current: period.start <= now && now < period.end)
        }
    }

    /// For VoiceOver: how much of the term has something on file.
    var summary: String {
        let filled = cells.filter { $0.count > 0 }.count
        return "Items on file in \(filled) of \(cells.count) weeks"
    }
}

/// The term under a story: a cell per week, filled where something is on file (deeper as more of the grade is at
/// stake), a bare ground where nothing is; the weeks behind are quieter, and this week is underlined.
private struct WeekBand: View {
    let weeks: TermWeeks

    var body: some View {
        Canvas { context, size in
            let count = CGFloat(max(weeks.cells.count, 1))
            let gap: CGFloat = 3
            let width = max((size.width - gap * (count - 1)) / count, 3)
            let height = size.height - 5
            for (i, week) in weeks.cells.enumerated() {
                let rect = CGRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: height)
                let shape = Path(roundedRect: rect, cornerRadius: min(3, width / 3))
                let fade = week.past ? 0.45 : 1
                if week.count > 0 {
                    context.fill(shape, with: .color(Design.paper))
                    context.fill(shape, with: .color(Design.accent.opacity(Strip.heat(points: week.points) * fade)))
                } else {
                    context.fill(shape, with: .color(.primary.opacity(0.07 * fade)))   // an empty week: a ground, not a box
                }
                if week.current {
                    context.fill(Path(roundedRect: CGRect(x: rect.minX, y: size.height - 2, width: rect.width, height: 2), cornerRadius: 1), with: .color(.primary))
                }
            }
        }
        .frame(height: 19)
        .help(weeks.summary)
        .accessibilityHidden(true)
    }
}
#endif
