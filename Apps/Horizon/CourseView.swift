import SwiftUI
import SwiftData
import QuickLook
import AppIntents
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
    @State private var addingItem = false
    @State private var preview: URL?     // the document being looked at, in Quick Look
    @State private var lingering = Lingering()
    /// The masthead's name has gone under the navigation bar, which then shows it (`nameHeight`: how far the page
    /// scrolls before it has).
    @State private var nameUnderBar = false
    @State private var nameHeight: CGFloat = 40
    @State private var pageWidth: CGFloat = 0   // the bar's width, for the room a name has centred in it
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoute) private var openRoute   // an item's details, pushed on the stack this page is in
    // The course's items and documents come through queries, not its relationships: the store saves from a context of
    // its own, and only a query redraws for that (read through the relationship, an item deleted stayed on the page).
    @Query private var items: [Obligation]
    @Query private var files: [SourceDocument]
    @Query private var policies: [Policy]

    init(course: Course) {
        self.course = course
        let id = course.id
        _items = Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.course?.id == id })
        _files = Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil && $0.course?.id == id })
        _policies = Query(filter: #Predicate<Policy> { $0.course?.id == id })   // a re-read that changes only the policies redraws the page too
    }

    /// Every document on file for the course, newest first: what its items, its grade table and its policies came from.
    /// They sit at the foot of the page, after the policies and before what is done.
    private var documents: [SourceDocument] { files.sorted { $0.queuedAt > $1.queuedAt } }
    private var obligations: [Obligation] { items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
    /// What is still to do, in date order; an item just checked off or skipped stays here a moment (`Lingering`).
    private var toDo: [Obligation] { obligations.filter { $0.completedAt == nil || lingering.contains($0.id) } }
    /// What is done, in date order, at the foot of the page.
    private var done: [Obligation] { obligations.filter { $0.completedAt != nil && $0.skippedAt == nil && !lingering.contains($0.id) } }
    /// What the user set aside, under it: closed, but not done.
    private var skipped: [Obligation] { obligations.filter { $0.skippedAt != nil && !lingering.contains($0.id) } }

    var body: some View {
        List {
            // The masthead: the course's name whole (a navigation bar's title is cut at the bar's width), then what else
            // the document said, each part kept whole on its line.
            let detail = [course.code == course.displayName ? nil : course.code, course.term, course.instructor].compactMap { $0 }.filter { !$0.isEmpty }
            VStack(alignment: .leading, spacing: 6) {
                Text(course.displayName).display().fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameHeight = $0 }
                if !detail.isEmpty { Text(detail.map(DocumentsView.figure).joined(separator: DocumentsView.separator)).foregroundStyle(.secondary) }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
            .onPaper()
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
                if obligations.isEmpty { Text("No items yet. Add a document, or an item by hand, from the More menu above.").foregroundStyle(.secondary) }
                else if toDo.isEmpty { Text("Everything on file is done.").foregroundStyle(.secondary) }
            }
            .onPaper()
            if !policies.isEmpty {
                PageSection("Policies") {
                    ForEach(policies) { policy in
                        VStack(alignment: .leading, spacing: 2) {
                            // The caption only where it adds something: not "Policy", and not over a text that opens with it.
                            if policy.kind != .other, !policy.text.lowercased().hasPrefix(label(policy.kind).lowercased()) {
                                Text(label(policy.kind)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(policy.text)
                        }
                        .appEntityIdentifier(EntityIdentifier(for: PolicyEntity.self, identifier: policy.id))   // "what does this say about makeups?"
                    }
                }
                .onPaper()
            }
            if !documents.isEmpty {
                PageSection("Documents") {
                    ForEach(documents) { doc in
                        Button { preview = model.previewFile(for: doc) } label: { CourseDocumentRow(document: doc, items: items.count { $0.sourceDocument?.id == doc.id }, onDevice: model.hasFile(doc)) }
                            .buttonStyle(.plain)
                            .disabled(!model.hasFile(doc))
                            .contextMenu {
                                Button("Open", systemImage: "eye") { preview = model.previewFile(for: doc) }.disabled(!model.hasFile(doc))
                                Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
                            }
                            .accessibilityHint("Opens the document")
                            .appEntityIdentifier(EntityIdentifier(for: DocumentEntity.self, identifier: doc.id))
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
            if !skipped.isEmpty {
                PageSection("Skipped") {
                    ForEach(skipped) { row($0) }
                }
                .onPaper()
            }
        }
        .listStyle(.plain)
        .paper()
        .animation(.default, value: toDo.map(\.id))
        .animation(.default, value: skipped.map(\.id))
        .animation(.default, value: documents.map(\.id))   // a document deleted here leaves its row animated
        // The bar names the course once the masthead's name has scrolled under it (a large title's way), and not before:
        // two copies of the name would say it twice.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > nameHeight + 4 } action: { _, under in nameUnderBar = under }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .navigationTitle(course.displayName)   // for the back button's menu and the system; the bar shows `BarName`
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BarName(course: course, shown: nameUnderBar, room: pageWidth > 0 ? pageWidth - 2 * BarName.buttons : .infinity) }
            ToolbarItem(placement: .primaryAction) {
                ImportMenu(courseID: course.id) {   // one button, so the name has the bar's middle
                    Button { addingItem = true } label: { Label("Add Item…", systemImage: "square.and.pencil") }
                    Button { editingCourse = true } label: { Label("Edit Course…", systemImage: "pencil") }
                }
            }
        }
        .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        .sheet(isPresented: $addingItem) { ObligationEditor(mode: .manual, courses: courses, preferredCourse: course.id) }   // added here: this course
        .sheet(isPresented: $editingCourse) { CourseEditor(course: course) }
        .quickLookPreview($preview)
        .showsEntity(CourseEntity.self, id: course.id, title: course.displayName)   // Siri's "this course"
        .onChange(of: course.deletedAt) { _, gone in if gone != nil { dismiss() } }
        .onAppear {   // once per launch: a sheet closed must not open again as the page reappears
            if MainTabs.debugOnce("--open-item"), let first = obligations.first {   // its details, as a tap opens them (`--edit-item` then its editor)
                Task { try? await Task.sleep(for: .milliseconds(700)); openRoute(.item(first.id)) }   // once this page's own push has landed: one asked for during it is dropped
            }
            if MainTabs.debugOnce("--check-first-item"), let first = toDo.first {   // DEBUG: a check without a tap, to see the row linger, then move down to Done
                Task { try? await Task.sleep(for: .seconds(2)); lingering.mark(first.id, done: true); await model.setCompleted(first.id, true) }
            }
            if MainTabs.debugOnce("--open-course-editor") { editingCourse = true }
            if MainTabs.debugOnce("--add-item") { addingItem = true }
        }
    }

    /// An item's row, to do, done or skipped: the ring, its details on a tap, the swipes and the menu (with the editor).
    private func row(_ item: Obligation) -> some View {
        // Only a row still to do lingers where it was (a skip as a check does, then down to Skipped): one already closed,
        // done then skipped or the other way, goes straight to its section.
        let open = item.completedAt == nil
        let mark: (Bool) -> Void = { done in
            if open || !done { lingering.mark(item.id, done: done) }
            Task { await model.setCompleted(item.id, done) }
        }
        let skip: (Bool) -> Void = { skipped in
            if open || !skipped { lingering.mark(item.id, done: skipped) }
            Task { await model.setSkipped(item.id, skipped) }
        }
        return Button { openRoute(.item(item.id)) } label: { ObligationRow(obligation: item, showCourse: false, mark: mark, disclosure: true) }
            .buttonStyle(.plain)
            .opacity(lingering.isLeaving(item.id) ? 0 : 1)
            .obligationActions(done: item.completedAt != nil && item.skippedAt == nil, skipped: item.skippedAt != nil, mark: mark, skip: skip,
                               edit: { editing = item }, delete: { Task { await model.discard(item.id) } })
            .accessibilityHint("Opens its details")
    }

    private func label(_ kind: PolicyKind) -> String {
        switch kind { case .lateWork: "Late work"; case .makeupExam: "Makeup exams"; case .attendance: "Attendance"; case .dropRule: "Drop rule"; case .extraCredit: "Extra credit"; case .other: "Policy" }
    }
}

/// The course's name in the navigation bar, set as the bar sets a title, shown once the masthead's has scrolled away.
/// The bar centres a title only when it clears the buttons on both sides, and otherwise sets it against the back
/// button; so the name gets the room it has centred, and one too long for that gives way to the code (only then cut).
private struct BarName: View {
    let course: Course
    let shown: Bool
    /// The width the bar has for it centred: the bar's, less a button's room on either side.
    let room: CGFloat
    /// What a button takes from the bar's edge on either side (the back button, the More menu: its glass, the bar's
    /// margin, and the gap the bar keeps before a title). Toolbar items measure only themselves, so it is counted.
    static let buttons: CGFloat = 80
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(course.displayName)
            if !course.code.isEmpty, course.code != course.displayName { Text(course.code) }
            Text(course.displayName).truncationMode(.tail)
        }
        .lineLimit(1)
        .frame(maxWidth: max(room, 0))
        .font(.system(.headline, design: .serif))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)   // the bar's own title stops at about this size
        .opacity(shown ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: shown)
        .accessibilityHidden(!shown)   // the masthead is the page's heading while it shows
    }
}
#endif

/// One of a course's documents on its page: what the app calls it, and where it stands (read, with what it gave; or
/// queued, waiting, failed). Pressing it opens the file itself.
struct CourseDocumentRow: View {
    let document: SourceDocument
    /// What came from it, counted from the page's query (a relationship read would not redraw when an item goes).
    let items: Int
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
