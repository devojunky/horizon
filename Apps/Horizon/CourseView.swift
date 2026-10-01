import SwiftUI
import SwiftData
import QuickLook
import HorizonCore
import IngestKit

#if os(iOS)
/// A course's page on a phone: the grade, the items, the policies, the documents, what is done, down one column. The
/// Mac sets the same things side by side (`MacCoursePage`).
struct CourseView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    let course: Course
    @State private var editing: Obligation?
    @State private var editingCourse = false
    @State private var selected: UUID?
    @State private var preview: URL?     // the document being looked at, in Quick Look
    @State private var lingering = Lingering()
    @Environment(\.dismiss) private var dismiss
    // The course's items and documents come through queries, not its relationships: the store saves from a context of
    // its own, and only a query redraws for that (read through the relationship, an item deleted stayed on the page).
    @Query private var items: [Obligation]
    @Query private var files: [SourceDocument]

    init(course: Course) {
        self.course = course
        let id = course.id
        _items = Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.course?.id == id })
        _files = Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil && $0.course?.id == id })
    }

    /// Every document on file for the course, newest first: what its items, its grade table and its policies came from.
    /// They sit at the foot of the page, after the policies and before what is done.
    private var documents: [SourceDocument] { files.sorted { $0.queuedAt > $1.queuedAt } }
    private var obligations: [Obligation] { items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
    /// What is still to do, in date order; an item just checked off stays here a moment, crossed off (`Lingering`).
    private var toDo: [Obligation] { obligations.filter { $0.completedAt == nil || lingering.contains($0.id) } }
    /// What is done, in date order, at the foot of the page.
    private var done: [Obligation] { obligations.filter { $0.completedAt != nil && !lingering.contains($0.id) } }

    var body: some View {
        List(selection: $selected) {
            let detail = [course.code == course.displayName ? nil : course.code, course.term, course.instructor].compactMap { $0 }.filter { !$0.isEmpty }
            if !detail.isEmpty {   // the title names the course; this line carries what else the document said
                Text(detail.joined(separator: " · ")).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                    .onPaper()
            }
            if !course.gradeComponents.isEmpty {
                PageSection("Grade") {
                    ForEach(course.gradeComponents, id: \.name) { component in
                        HStack { Text(component.name); Spacer(); Design.points(component.weight.map { $0 * 100 }).font(.body.weight(.semibold)) }
                    }
                }
                .onPaper()
            }
            PageSection("Items") {
                ForEach(toDo) { row($0) }
                if obligations.isEmpty { Text("No items yet. Add a document, or an item by hand from the Coverage menu.").foregroundStyle(.secondary) }
                else if toDo.isEmpty { Text("Everything on file is done.").foregroundStyle(.secondary) }
            }
            .onPaper()
            if let policies = course.policies, !policies.isEmpty {
                PageSection("Policies") {
                    ForEach(policies) { policy in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(policy.kind)).font(.caption).foregroundStyle(.secondary)
                            Text(policy.text)
                        }
                    }
                }
                .onPaper()
            }
            if !documents.isEmpty {
                PageSection("Documents") {
                    ForEach(documents) { doc in
                        Button { preview = model.previewFile(for: doc) } label: { CourseDocumentRow(document: doc, onDevice: model.hasFile(doc)) }
                            .buttonStyle(.plain)
                            .disabled(!model.hasFile(doc))
                            .contextMenu {
                                Button("Open", systemImage: "eye") { preview = model.previewFile(for: doc) }.disabled(!model.hasFile(doc))
                                Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
                            }
                            .accessibilityHint("Opens the document")
                    }
                }
                .onPaper()
            }
            if !done.isEmpty {   // what is behind the user comes last: the page leads with what is ahead
                PageSection("Done") {
                    ForEach(done) { row($0) }
                }
                .onPaper()
            }
        }
        .listStyle(.plain)
        .paper()
        .animation(.default, value: toDo.map(\.id))
        .navigationTitle(course.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ImportMenu(courseID: course.id) }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editingCourse = true } }
        }
        .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        .sheet(isPresented: $editingCourse) { CourseEditor(course: course) }
        .quickLookPreview($preview)
        .onChange(of: course.deletedAt) { _, gone in if gone != nil { dismiss() } }
        .onAppear {
            if MainTabs.debugFlag("--open-item") { editing = obligations.first }
            if MainTabs.debugOnce("--check-first-item"), let first = toDo.first {   // DEBUG: a check without a tap, to see the row linger, then move down to Done
                Task { try? await Task.sleep(for: .seconds(2)); lingering.mark(first.id, done: true); await model.setCompleted(first.id, true) }
            }
            if MainTabs.debugFlag("--open-course-editor") { editingCourse = true }
        }
    }

    /// An item's row, to do or done: the ring, the editor, the swipes and the menu.
    private func row(_ item: Obligation) -> some View {
        let mark: (Bool) -> Void = { done in
            lingering.mark(item.id, done: done)
            Task { await model.setCompleted(item.id, done) }
        }
        return Button { editing = item } label: { ObligationRow(obligation: item, showCourse: false, mark: mark) }
            .buttonStyle(.plain)
            .obligationActions(done: item.completedAt != nil, mark: mark, edit: { editing = item }, delete: { Task { await model.discard(item.id) } })
            .accessibilityHint("Opens the editor")
    }

    private func label(_ kind: PolicyKind) -> String {
        switch kind { case .lateWork: "Late work"; case .makeupExam: "Makeup exams"; case .attendance: "Attendance"; case .dropRule: "Drop rule"; case .extraCredit: "Extra credit"; case .other: "Policy" }
    }
}
#endif

/// One of a course's documents on its page: what the app calls it, and where it stands (read, with what it gave; or
/// queued, waiting, failed). Pressing it opens the file itself.
struct CourseDocumentRow: View {
    let document: SourceDocument
    /// The file is on this device; a document read on another is a record only.
    let onDevice: Bool
    /// A chevron says pressing it opens the file (a phone's page); a Mac's column says so on hover instead.
    var disclosure = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.displayName).font(.body.weight(.medium)).lineLimit(2)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(disclosure ? 1 : 2)
            }
            Spacer()
            if onDevice, disclosure { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let items = (document.obligations ?? []).filter { $0.deletedAt == nil }.count
        var parts: [String]
        switch document.status {
        case .parsed:
            parts = ["Read \((document.ingestedAt ?? document.queuedAt).formatted(.dateTime.month(.abbreviated).day()))", items == 1 ? "1 item" : "\(items) items"]
            if document.pageCount > 1 { parts.append("\(document.pageCount) pages") }
        case .queued: parts = ["Waiting to be read"]
        case .awaitingCloudParse: parts = ["Waiting for Claude"]
        case .failed: parts = ["Could not be read"]
        case .cancelled: parts = ["Reading cancelled"]
        }
        if !onDevice { parts.append("the file is on \(document.deviceName.isEmpty ? "another device" : document.deviceName)") }
        return parts.joined(separator: " · ")
    }
}
