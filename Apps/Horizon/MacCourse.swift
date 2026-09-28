#if os(macOS)
import SwiftUI
import SwiftData
import QuickLook
import HorizonCore
import IngestKit

/// A course's page on a Mac: its masthead over its items, in a table, and beside them a column of what the syllabus
/// said about it (where the app may be blind, the grade and its weights, the documents, the policies). A phone reads
/// all of that down one column; a window has the width to set the work and its reference side by side, so the items
/// get the height and the reference never pushes them off the screen.
struct MacCoursePage: View {
    let course: Course
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\ItemRow.due)]
    @State private var editing: Obligation?
    @State private var editingCourse = false
    @State private var preview: URL?     // the document being looked at, in Quick Look
    @State private var lingering = Lingering()
    @AppStorage("courseShowsDone") private var showsDone = false

    private var obligations: [Obligation] { (course.obligations ?? []).filter { $0.deletedAt == nil } }
    private var documents: [SourceDocument] { (course.documents ?? []).filter { $0.deletedAt == nil }.sorted { $0.queuedAt > $1.queuedAt } }
    private var story: CourseCoverage {
        Coverage.assess(course: CourseSnapshot(course), obligations: obligations.map(ObligationSnapshot.init), documents: documents.map(DocumentSnapshot.init))
    }

    var body: some View {
        let listed = obligations.filter { showsDone || $0.completedAt == nil || lingering.contains($0.id) }
        let rows = listed.map { ItemRow($0, lingering: lingering) }.sorted(using: sortOrder)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CourseMasthead(course: course)
                    .padding(.horizontal, Design.margin)
                    .padding(.top, 20)
                    .padding(.bottom, 22)
                HStack(alignment: .firstTextBaseline) {
                    Kicker("Items")
                    Spacer()
                    Toggle("Show Done", isOn: $showsDone).toggleStyle(.checkbox).controlSize(.small)
                        .help("List the items already done, crossed off, with the rest")
                }
                .padding(.horizontal, Design.margin)
                .padding(.bottom, 6)
                ItemTable(rows: rows, selection: $selection, sortOrder: $sortOrder, showsCourse: false,
                          emptyText: obligations.isEmpty ? "No items yet. Add a document, or an item by hand (File ▸ Add Item…)." : "Everything on file is done.",
                          mark: { id, done in lingering.mark(id, done: done); Task { await model.setCompleted(id, done) } },
                          edit: { id in editing = obligations.first { $0.id == id } },
                          delete: { ids in for id in ids { Task { await model.discard(id) } }; selection.subtract(ids) })
            }
            .frame(minWidth: 420, maxWidth: .infinity)
            CourseRail(course: course, story: story, documents: documents, preview: $preview)
                .frame(width: 300)
        }
        .background(Design.paper)
        .animation(.default, value: rows.map(\.id))
        .navigationTitle(course.displayName)
        .toolbar(removing: .title)   // the window keeps the name (the Window menu, Mission Control); the page shows it once, in its masthead
        .toolbar {   // Add Document is the window's, and on this page files under the course
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editingCourse = true }.help("Edit the course: its name, code, term and grade table (⌘E)")
            }
        }
        .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        .sheet(isPresented: $editingCourse) { CourseEditor(course: course) }
        .quickLookPreview($preview)
        .onAppear {
            if MainTabs.debugFlag("--open-item") { editing = obligations.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.first }
            if MainTabs.debugFlag("--open-course-editor") { editingCourse = true }
        }
    }
}

/// The head of a course's page on a Mac: its code over its name, set large, and what else the syllabus said of it.
struct CourseMasthead: View {
    let course: Course
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !course.title.isEmpty, !course.code.isEmpty { Kicker(course.code).padding(.bottom, 6) }
            Text(course.displayName).display().fixedSize(horizontal: false, vertical: true)
            let detail = [course.term, course.instructor].compactMap { $0 }.filter { !$0.isEmpty }
            if !detail.isEmpty { Text(detail.joined(separator: " · ")).foregroundStyle(.secondary).padding(.top, 6).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The column beside a course's items: its story (where the app may be blind), its grade, the documents it was read
/// from, and its policies. It scrolls on its own; the items keep their place.
private struct CourseRail: View {
    let course: Course
    let story: CourseCoverage
    let documents: [SourceDocument]
    @Binding var preview: URL?
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                RailSection("Coverage") { CoverageFindings(story: story) }
                if !course.gradeComponents.isEmpty {
                    RailSection("Grade") { GradeWeights(components: course.gradeComponents) }
                }
                if !documents.isEmpty {
                    RailSection("Documents") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(documents) { doc in
                                Button { preview = model.previewFile(for: doc) } label: { CourseDocumentRow(document: doc, onDevice: model.hasFile(doc), disclosure: false) }
                                    .buttonStyle(.plain)
                                    .disabled(!model.hasFile(doc))
                                    .help(model.hasFile(doc) ? "Open in Quick Look" : "The file is on another device")
                                    .contextMenu {
                                        Button("Open") { preview = model.previewFile(for: doc) }.disabled(!model.hasFile(doc))
                                        Divider()
                                        Button("Delete", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
                                    }
                            }
                        }
                    }
                }
                if let policies = course.policies, !policies.isEmpty {
                    RailSection("Policies") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(policies) { policy in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Self.label(policy.kind)).font(.caption).foregroundStyle(.secondary)
                                    Text(policy.text).font(.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.trailing, Design.margin)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
        .scrollEdgeEffectStyle(.soft, for: .top)   // at rest nothing is under the toolbar: no band there, as over the items beside it
    }

    static func label(_ kind: PolicyKind) -> String {
        switch kind { case .lateWork: "Late work"; case .makeupExam: "Makeup exams"; case .attendance: "Attendance"; case .dropRule: "Drop rule"; case .extraCredit: "Extra credit"; case .other: "Policy" }
    }
}

/// A kicker over a block of a page's side column.
struct RailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(title).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// The grade table as bars: each row's share of the grade, the longest row's bar the rail's width, deeper in the
/// accent as the share grows (the strip's colour for what is at stake), and under the name what the syllabus says of
/// its rhythm: how often, how many, how many dropped, and where the work lives.
private struct GradeWeights: View {
    let components: [GradeComponent]

    var body: some View {
        let top = max(components.compactMap(\.weight).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(components, id: \.name) { component in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(component.name).lineLimit(2)
                        Spacer(minLength: 8)
                        Design.points(component.weight.map { $0 * 100 }).fontWeight(.semibold)
                    }
                    if let weight = component.weight {
                        GeometryReader { g in
                            Capsule().fill(Design.paper).overlay(Capsule().fill(Design.accent.opacity(Strip.heat(points: weight * 100))))
                                .frame(width: max(g.size.width * weight / top, 4))
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    }
                    if let detail = detail(component) { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func detail(_ c: GradeComponent) -> String? {
        var parts: [String] = []
        switch c.cadence { case .weekly: parts.append("Weekly"); case .biweekly: parts.append("Every two weeks"); case .once, nil: break }
        if let count = c.expectedCount, count > 1 { parts.append("\(count) in all") }
        if let drop = c.dropLowest, drop > 0 { parts.append(drop == 1 ? "lowest dropped" : "lowest \(drop) dropped") }
        if let platform = c.platform, platform != .syllabusOnly { parts.append("on \(Coverage.platformName(platform))") }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
#endif
