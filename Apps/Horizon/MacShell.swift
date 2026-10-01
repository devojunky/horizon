#if os(macOS)
import SwiftUI
import SwiftData
import HorizonCore
import IngestKit
import AppKit

/// What a window shows, and what the menu bar's commands act on: one per window, handed to the commands through the
/// focused scene, so a command reaches the window in front and is dimmed when there is none.
@MainActor @Observable final class MacNavigation {
    enum Page: String, CaseIterable, Identifiable {
        case coverage, horizon, now, review, documents, recentlyDeleted
        var id: String { rawValue }
        var title: String {
            switch self { case .coverage: "Coverage"; case .horizon: "Horizon"; case .now: "Now"; case .review: "Review"; case .documents: "Documents"; case .recentlyDeleted: "Recently Deleted" }
        }
        var symbol: String {
            switch self { case .coverage: "eye"; case .horizon: "chart.bar.xaxis"; case .now: "sun.horizon"; case .review: "checkmark.circle"; case .documents: "doc.text"; case .recentlyDeleted: "trash" }
        }
    }
    /// A page of the app, or a course's own page: what the sidebar has selected.
    enum Destination: Hashable { case page(Page), course(UUID) }
    var destination: Destination = .page(.coverage)
    /// The page shown, when it is not a course's.
    var page: Page? { if case .page(let page) = destination { page } else { nil } }
    /// The course whose page is shown: the Course menu acts on it, and a document added here is filed under it.
    var course: UUID? { if case .course(let id) = destination { id } else { nil } }
    func show(_ page: Page) { destination = .page(page); focusesPage = true }
    func show(course id: UUID) { destination = .course(id); focusesPage = true }
    /// Whether the page shown next takes the keyboard, so the arrow keys move through its list: yes when it was
    /// chosen with the pointer or the menu bar, no while the sidebar is walked with the arrow keys (they go on
    /// through the sidebar, and Tab goes into the page).
    var focusesPage = true
    /// Asks the sidebar for the keyboard (`keyboardToSidebar`): the page chosen has no rows to move through.
    private(set) var sidebarKeyboardAsked = 0
    func keyboardToSidebar() { sidebarKeyboardAsked += 1 }

    var importing = false
    var addingItem = false
    var addingCourse = false
    /// The course being edited (Course ▸ Edit Course…, or the menu on its story or its row in the sidebar).
    var editingCourse: UUID?
    var addingBlock = false
    var tellingPlanner = false
    var confirmingReplan = false
}

/// Where the keyboard goes as a page appears, when the page was chosen with the pointer or the menu bar
/// (`MacNavigation.focusesPage`): to its list, so the arrow keys move through the rows, or, when it has no list or
/// the list no rows, to the sidebar (a click on a sidebar row leaves the keyboard where it was, and the list that had
/// it may have gone with the last page), so the arrows always move something.
private struct PageKeyboard: ViewModifier {
    var list: FocusState<Bool>.Binding?
    var hasRows: Bool
    @Environment(MacNavigation.self) private var nav
    func body(content: Content) -> some View {
        let page = nav.destination   // the page this belongs to, as it appears
        content.task {
            guard nav.focusesPage else { return }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }   // once it is in the window
            guard nav.destination == page else { return }   // a page already gone (one passed through at launch) says nothing
            if let list, hasRows { list.wrappedValue = true } else { nav.keyboardToSidebar() }
        }
    }
}

extension View {
    /// A page's list, which takes the keyboard as the page appears when it has rows (`PageKeyboard`).
    func takesKeyboard(_ focus: FocusState<Bool>.Binding, hasRows: Bool) -> some View {
        focused(focus).modifier(PageKeyboard(list: focus, hasRows: hasRows))
    }

    /// A page with no list: the keyboard goes to the sidebar as it appears (`PageKeyboard`).
    func keyboardStaysInSidebar() -> some View { modifier(PageKeyboard(list: nil, hasRows: false)) }
}

/// The item selected in a table of items, for the menu bar's Item commands.
struct SelectedItem: Equatable {
    var id: UUID
    var done: Bool
    /// Checks it off, or back on, the way its page does (a row just checked lingers where it was for a moment).
    var mark: (Bool) -> Void
    /// Deletes it, the way the Delete key does.
    var delete: () -> Void
    static func == (a: SelectedItem, b: SelectedItem) -> Bool { a.id == b.id && a.done == b.done }
}

extension FocusedValues {
    @Entry var navigation: MacNavigation?
    @Entry var selectedItem: SelectedItem?
    @Entry var reviewActions: ReviewActions?
}

/// The Mac window: a sidebar of the app's areas and its courses, and a detail column (HIG: a sidebar holds the areas
/// and the top-level collections; Reminders keeps its lists there, Mail its mailboxes). A course is a place of its
/// own, one click from anywhere, and its page has the whole column: nothing is split inside the detail, so nothing
/// in it moves when something is chosen. The toolbar carries what acts on every page (Add Document, Sync), each page
/// adds its own after a gap, and a file from the Finder can be dropped anywhere on the window. Sheets the menu bar
/// opens (Add Item, New Course, Edit Course, Add Block, Tell the Planner) live here.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var nav = MacNavigation()
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var dropping = false

    private var shownCourse: Course? { nav.course.flatMap { id in courses.first { $0.id == id } } }
    private var editedCourse: Course? { nav.editingCourse.flatMap { id in courses.first { $0.id == id } } }

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(nav: nav)
        } detail: {
            detail
                .environment(nav)   // a page asks it whether to take the keyboard as it appears
                .toolbar {
                    if shownCourse != nil { ToolbarSpacer(.flexible, placement: .primaryAction) }   // a course's page keeps its title off the toolbar: this holds the buttons at the trailing edge, where every other page has them
                    ToolbarItemGroup(placement: .primaryAction) {   // both are File menu commands as well
                        ImportMenu(courseID: shownCourse?.id).help(shownCourse.map { "Add a document to \($0.displayName) (⌘O)" } ?? "Add a document to read (⌘O)")
                        Button { Task { await model.drainAndSync() } } label: { Label("Sync with Reminders", systemImage: "arrow.triangle.2.circlepath") }
                            .help("Read what is queued and sync with Reminders (⌘R)")
                    }
                }
        }
        .focusedSceneValue(\.navigation, nav)
        .dropDestination(for: URL.self) { urls, _ in   // a syllabus dragged out of the Finder; on a course's page, filed under it
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            let course = shownCourse?.id
            Task { await model.importFiles(files, courseID: course) }
            return true
        } isTargeted: { dropping = $0 }
        .overlay { if dropping { DropVeil(course: shownCourse?.displayName).transition(.opacity) } }
        .animation(.snappy, value: dropping)
        .frame(minWidth: 980, minHeight: 620)
        .fileImporter(isPresented: $nav.importing, allowedContentTypes: ImportMenu.readable, allowsMultipleSelection: true) { result in
            let course = shownCourse?.id
            if case .success(let urls) = result { Task { await model.importFiles(urls, courseID: course) } }
        }
        .sheet(isPresented: $nav.addingItem) { ObligationEditor(mode: .manual, courses: courses) }
        .sheet(isPresented: $nav.addingCourse) { CourseEditor(course: nil) }
        .sheet(isPresented: Binding(get: { editedCourse != nil }, set: { if !$0 { nav.editingCourse = nil } })) { if let editedCourse { CourseEditor(course: editedCourse) } }
        .sheet(isPresented: $nav.addingBlock) { PlanBlockEditor(block: nil) }
        .sheet(isPresented: $nav.tellingPlanner) { PlannerNotesEditor() }
        .confirmationDialog("Replace the plan you edited?", isPresented: $nav.confirmingReplan, titleVisibility: .visible) {
            Button("Plan Again", role: .destructive) { model.planAgain() }
        } message: {
            Text("Your changes to today's blocks are lost.")
        }
        .onChange(of: nav.confirmingReplan) { _, asking in if !asking { model.pendingTonightEnd = nil } }   // not planned again: tonight's end stays as it was
        .onChange(of: courses.map(\.id)) { _, ids in   // the course on show was deleted (here, or on another device): back to Coverage
            if let id = nav.course, !ids.contains(id) { nav.show(.coverage) }
        }
        .onAppear {
            if MainTabs.debugFlag("--tab-horizon") { nav.show(.horizon) }
            if MainTabs.debugFlag("--tab-now") { nav.show(.now) }
            if MainTabs.debugFlag("--open-documents") { nav.show(.documents) }
            if MainTabs.debugFlag("--open-recently-deleted") { nav.show(.recentlyDeleted) }
            if MainTabs.debugFlag("--open-review") { nav.show(.review) }
            if MainTabs.debugFlag("--open-course"), let first = Coverage.stories(courses: courses, obligations: [], documents: []).first { nav.show(course: first.course.id) }   // DEBUG: a course's page without a click
            if MainTabs.debugFlag("--open-settings") { openSettings() }
            #if DEBUG
            if MainTabs.debugFlag("--light") { NSApp.appearance = NSAppearance(named: .aqua) }   // the app's own appearance, for screenshots; the system's is left alone
            if MainTabs.debugFlag("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            #endif
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav.destination {
        case .page(.coverage): MacCoveragePage(nav: nav).keyboardStaysInSidebar()
        case .page(.horizon): MacHorizonPage()
        case .page(.now): NowView().keyboardStaysInSidebar()
        case .page(.review): MacReviewPage()
        case .page(.documents): DocumentsTable()
        case .page(.recentlyDeleted): RecentlyDeletedTable()
        case .course:
            if let shownCourse { MacCoursePage(course: shownCourse).id(shownCourse.id) } else { MacCoveragePage(nav: nav).keyboardStaysInSidebar() }
        }
    }
}

/// The areas of the app, what waits in two of them as badges, and the courses in the user's own order (dragged here),
/// else by name. A course's row opens its page; its menu edits or deletes it, and so does the Delete key.
private struct Sidebar: View {
    @Bindable var nav: MacNavigation
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }) private var courses: [Course]
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var binnedCourses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]

    private var toReview: Int { obligations.filter { $0.state == .pendingReview && $0.completedAt == nil }.count }   // done needs no review
    private var binned: Int { binnedCourses.count + deletedDocuments.filter(\.isBinned).count }
    /// The user's own order, then by name: a sidebar row stays where it is (Coverage puts the most suspicious
    /// first, which moves as items are checked off; a place to go to must not).
    private var ordered: [Course] {
        courses.sorted { a, b in
            switch (a.sortOrder, b.sortOrder) {
            case (let x?, let y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }

    var body: some View {
        List(selection: Binding(get: { Optional(nav.destination) }, set: { chosen in
            guard let chosen else { return }
            nav.focusesPage = NSApp.currentEvent?.type != .keyDown   // an arrow key in the sidebar keeps the keyboard there
            nav.destination = chosen
        })) {
            Section {
                row(.coverage)
                row(.horizon)
                row(.now)
            }
            Section("Library") {
                row(.review, badge: toReview)
                row(.documents)
                row(.recentlyDeleted, badge: binned)
            }
            if !ordered.isEmpty {
                Section("Courses") {   // last, the way a Mac lists what grows (Music's playlists, Reminders' lists)
                    ForEach(ordered) { course in
                        Label { Text(course.displayName) } icon: { SidebarIcon(symbol: "book.closed") }
                            .tag(MacNavigation.Destination.course(course.id))
                            .contextMenu {
                                Button("Edit Course…") { nav.editingCourse = course.id }
                                Button("Delete Course", role: .destructive) { Task { await model.deleteCourse(course.id) } }
                            }
                    }
                    .onMove { from, to in
                        var order = ordered.map(\.id)
                        order.move(fromOffsets: from, toOffset: to)
                        Task { await model.reorderCourses(order) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($focused)
        .onChange(of: nav.sidebarKeyboardAsked) { focused = true }   // the page chosen has nothing to move through
        .onDeleteCommand { if let id = nav.course { Task { await model.deleteCourse(id) } } }   // to Recently Deleted: no dialog
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
    }

    /// A page's row; its badge goes on before its tag (a badge put on a tagged row drops the tag, and the row can
    /// no longer be chosen: Review and Recently Deleted could not be).
    private func row(_ page: MacNavigation.Page, badge: Int = 0) -> some View {
        Label { Text(page.title) } icon: { SidebarIcon(symbol: page.symbol) }
            .badge(badge)
            .tag(MacNavigation.Destination.page(page))
    }
}

/// A sidebar row's icon in the app's accent whatever accent the system is set to (a sidebar's icons otherwise take
/// the system's, blue by default, and ignore a tint set on the window), and white on the row while it is selected,
/// where the accent is the highlight itself and an accent icon would vanish into it.
private struct SidebarIcon: View {
    let symbol: String
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        Image(systemName: symbol).foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(Design.accent))
    }
}

/// Documents as a table: sortable, alternating rows, a context menu and the Delete key on the selection.
struct DocumentsTable: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\SourceDocument.queuedAt, order: .reverse)]
    @State private var confirmDevice: [SourceDocument] = []   // waiting for Claude; the Mac may read them once the user says so
    @State private var preview: URL?   // the document being looked at, in Quick Look

    private var rows: [SourceDocument] { documents.sorted(using: sortOrder) }
    private func chosen(_ ids: Set<UUID>) -> [SourceDocument] { documents.filter { ids.contains($0.id) } }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Document", value: \.displayName) { doc in   // two lines on every row, so the rows keep one height
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.displayName).fontWeight(.medium).lineLimit(1)
                    Text(doc.displayName != doc.filename ? doc.filename : Self.kind(doc)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)   // the file it came as
                }
                .padding(.vertical, 3)
            }
            .width(min: 220, ideal: 320)
            TableColumn("Status", value: \.statusLabel) { doc in
                HStack(spacing: 4) {
                    Text(doc.statusLabel).foregroundStyle(doc.status == .failed ? Design.accent : .primary)
                        .help(doc.failure ?? "")   // why it could not be read, on hover
                    if !doc.warnings.isEmpty {   // what the read had to say, on hover
                        Text(doc.warnings.count == 1 ? "· 1 note" : "· \(doc.warnings.count) notes").foregroundStyle(.secondary)
                            .help(doc.warnings.joined(separator: "\n"))
                    }
                }
                .lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Course") { doc in
                if let course = doc.course { Text(course.displayName) }
                else if doc.status == .parsed, !courses.isEmpty {
                    Menu("File Under…") {
                        ForEach(courses) { course in Button(course.displayName) { Task { await model.assignDocument(doc.id, to: course.id) } } }
                    }
                    .fixedSize()
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 120, ideal: 180)
            TableColumn("Added", value: \.queuedAt) { doc in Text(Self.added(doc.queuedAt)).monospacedDigit() }.width(min: 140, ideal: 160)
            TableColumn("Read") { doc in
                if doc.status == .parsed {
                    Text("\(doc.inputTokens) in · \(doc.outputTokens) out · \(doc.durationMs / 1000) s · \(Self.routeName(doc.route))").monospacedDigit().foregroundStyle(.secondary)
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 200, ideal: 300)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .takesKeyboard($focused, hasRows: !documents.isEmpty)
        .animation(.default, value: documents.map(\.id))   // rows come and go as a Mac table's do
        .confirmationDialog("Read on this Mac instead?", isPresented: Binding(get: { !confirmDevice.isEmpty }, set: { if !$0 { confirmDevice = [] } }), titleVisibility: .visible) {
            Button(confirmDevice.count == 1 ? "Read on This Mac" : "Read \(confirmDevice.count) on This Mac") {
                let ids = confirmDevice.map(\.id)
                Task { for id in ids { await model.readOnDevice(documentID: id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Mac's own model is less sure of tables and pictures than Claude, and it takes minutes on a long document. Nothing is sent to Anthropic.")
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let docs = chosen(ids)
            if docs.count == 1, let doc = docs.first, model.hasFile(doc) {
                Button("Open") { look(at: doc) }
                Divider()
            }
            if docs.contains(where: { $0.status == .failed || $0.status == .awaitingCloudParse || $0.status == .cancelled }) {
                Button("Retry") { for doc in docs { Task { await model.retry(documentID: doc.id) } } }
            }
            if docs.contains(where: { $0.status == .awaitingCloudParse && !$0.readOnDevice }) {
                Button("Read on This Mac Instead…") { confirmDevice = docs.filter { $0.status == .awaitingCloudParse } }
            }
            if docs.count == 1, let doc = docs.first, doc.course == nil, doc.status == .parsed, !courses.isEmpty {
                Menu("File Under") {
                    ForEach(courses) { course in Button(course.displayName) { Task { await model.assignDocument(doc.id, to: course.id) } } }
                }
            }
            Button("Delete", role: .destructive) { delete(ids) }
        } primaryAction: { ids in   // a double-click opens the file, as the Finder does
            if let doc = chosen(ids).first { look(at: doc) }
        }
        .onDeleteCommand { delete(selection) }
        .onKeyPress(.space) {   // Space shows the selected file in Quick Look, as the Finder does
            guard let doc = chosen(selection).first else { return .ignored }
            look(at: doc)
            return .handled
        }
        .quickLookPreview($preview)
        .scrollContentBackground(.hidden)
        .background(Design.paper)   // the page every other one sits on; the rows' stripes lie on it
        .opacity(documents.isEmpty ? 0 : 1)
        .overlay {
            if documents.isEmpty {
                ContentUnavailableView("No Documents", systemImage: "doc.text", description: Text("Add a syllabus, a schedule or a screenshot, or drop one on this window."))
                    .background(Design.paper)
            }
        }
        .navigationTitle("Documents")
    }

    /// When a document came in: the day and the time, the year only when it is not this one.
    static func added(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }

    /// What a document is, for the line under a name that is its file's own.
    static func kind(_ doc: SourceDocument) -> String {
        let pages = doc.pageCount > 1 ? " · \(doc.pageCount) pages" : ""
        switch doc.filename.split(separator: ".").last?.lowercased() {
        case "pdf": return "PDF" + pages
        case "docx": return "Word document" + pages
        case "txt", "md": return "Text" + pages
        case "png", "jpg", "jpeg", "heic", "gif", "tiff": return "Picture"
        default: return "Document" + pages
        }
    }

    static func routeName(_ raw: String?) -> String {
        switch raw { case "onDevice": "on this Mac"; case "claude": "Claude"; case "privateCloudCompute": "Private Cloud Compute"; case "openAI": "OpenAI"; default: raw ?? "" }   // the last two: documents read before Claude
    }

    private func delete(_ ids: Set<UUID>) {   // straight to Recently Deleted, restorable for 30 days
        for id in ids { Task { await model.deleteDocument(id) } }
        selection.subtract(ids)
    }

    /// The file in Quick Look, when it is on this Mac.
    private func look(at doc: SourceDocument) {
        guard model.hasFile(doc) else { return }
        preview = model.previewFile(for: doc)
    }
}

extension SourceDocument {
    var statusLabel: String {
        switch status {
        case .queued: readSoFar.map { "Queued · \($0.finished) of \($0.total) parts read" } ?? "Queued"   // paused mid-read: it goes on from there
        case .parsed: "Read"; case .failed: "Failed"; case .awaitingCloudParse: "Waiting for Claude"; case .cancelled: "Cancelled"
        }
    }
}

/// Recently Deleted as a table: Restore and Delete Now on the selection (toolbar, context menu, the Delete key);
/// only Delete Now asks, since it cannot be undone. Double-clicking a row restores it.
struct RecentlyDeletedTable: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]
    @State private var selection: Set<UUID> = []
    @State private var erasing: [BinEntry] = []

    private var entries: [BinEntry] {
        (courses.map(BinEntry.init) + deletedDocuments.filter(\.isBinned).map(BinEntry.init)).sorted { $0.deletedAt > $1.deletedAt }
    }
    private func chosen(_ ids: Set<UUID>) -> [BinEntry] { entries.filter { ids.contains($0.id) } }

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Name") { entry in Text(entry.name).fontWeight(.medium) }.width(min: 200, ideal: 300)
            TableColumn("Kind") { entry in Text(entry.kind == .course ? "Course" : "Document") }.width(min: 80, ideal: 100)
            TableColumn("Holds") { entry in Text(holds(entry)).foregroundStyle(.secondary) }.width(min: 140, ideal: 200)
            TableColumn("Deleted") { entry in Text(entry.deletedAt.formatted(.relative(presentation: .named))) }.width(min: 120, ideal: 150)
            TableColumn("Gone in") { entry in Text(remaining(entry)).monospacedDigit() }.width(min: 80, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .takesKeyboard($focused, hasRows: !entries.isEmpty)
        .animation(.default, value: entries.map(\.id))   // restored and erased rows leave as a Mac table's do
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Restore") { restore(ids) }
            Button("Delete Now…", role: .destructive) { erasing = chosen(ids) }
        } primaryAction: { ids in
            restore(ids)
        }
        .onDeleteCommand { erasing = chosen(selection) }
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)   // the page's own, apart from the window's Add Document and Sync
            ToolbarItemGroup(placement: .primaryAction) {
                Button { restore(selection) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .help("Put the selection back").disabled(selection.isEmpty)
                Button { erasing = chosen(selection) } label: { Label("Delete Now", systemImage: "trash.slash") }
                    .help("Delete the selection for good").disabled(selection.isEmpty)
            }
        }
        .alert(eraseTitle, isPresented: Binding(get: { !erasing.isEmpty }, set: { if !$0 { erasing = [] } })) {
            Button("Delete Now", role: .destructive) { for entry in erasing { erase(entry) }; erasing = [] }
            Button("Cancel", role: .cancel) { erasing = [] }
        } message: {
            Text("This cannot be undone.")
        }
        .scrollContentBackground(.hidden)
        .background(Design.paper)
        .opacity(entries.isEmpty ? 0 : 1)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Nothing Deleted Lately", systemImage: "trash", description: Text("A course or document you delete waits here for 30 days, and can be put back until then."))
                    .background(Design.paper)
            }
        }
        .navigationTitle("Recently Deleted")
    }

    private var eraseTitle: String {
        erasing.count == 1 ? "Delete \(erasing[0].name) for good?" : "Delete \(erasing.count) items for good?"
    }
    private func holds(_ entry: BinEntry) -> String {
        var parts: [String] = []
        if entry.items > 0 { parts.append(entry.items == 1 ? "1 item" : "\(entry.items) items") }
        if entry.documents > 0 { parts.append(entry.documents == 1 ? "1 document" : "\(entry.documents) documents") }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
    private func remaining(_ entry: BinEntry) -> String {
        let days = max(0, Int((Bin.expiry(of: entry.deletedAt).timeIntervalSinceNow / 86400).rounded(.up)))
        return days == 0 ? "Today" : days == 1 ? "1 day" : "\(days) days"
    }
    private func restore(_ ids: Set<UUID>) {
        for entry in chosen(ids) { Task { entry.kind == .course ? await model.restoreCourse(entry.id) : await model.restoreDocument(entry.id) } }
        selection.subtract(ids)
    }
    private func erase(_ entry: BinEntry) {
        Task { entry.kind == .course ? await model.eraseCourse(entry.id) : await model.eraseDocument(entry.id) }
        selection.remove(entry.id)
    }
}

/// The window while a file is dragged over it.
private struct DropVeil: View {
    /// The course whose page is showing: what is dropped there is filed under it.
    var course: String?
    var body: some View {
        ZStack {
            Design.paper.opacity(0.88)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc").font(.system(size: 44, weight: .light)).foregroundStyle(Design.accent)
                Text("Drop to read").deck()
                Text(course.map { "Filed under \($0)." } ?? "A syllabus, a schedule, a screenshot.").foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 18).strokeBorder(Design.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 8])).padding(16)
        }
        .allowsHitTesting(false)
    }
}

/// The menu bar. Every toolbar and context-menu action is here too, with its shortcut, so the toolbar can be hidden
/// and the keyboard suffices. Commands act on the window in front through the focused `MacNavigation`.
struct HorizonCommands: Commands {
    let model: AppModel
    @FocusedValue(\.navigation) private var nav
    @FocusedValue(\.selectedItem) private var item
    @FocusedValue(\.reviewActions) private var review

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Document…") { nav?.importing = true }.keyboardShortcut("o").disabled(nav == nil)
            Button("Add Item…") { nav?.addingItem = true }.keyboardShortcut("n").disabled(nav == nil)
            Button("New Course…") { nav?.addingCourse = true }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(nav == nil)
            Divider()
            Button("Sync with Reminders") { Task { await model.drainAndSync() } }.keyboardShortcut("r")
            Button("Recreate Horizon List in Reminders") { Task { await model.recreateRemindersList() } }.disabled(!model.remindersListGone)
            Button("Show Inbox Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([WatchedFolder.url]) }
        }
        CommandGroup(after: .sidebar) {
            Divider()
            pageItem(.coverage, "1")
            pageItem(.horizon, "2")
            pageItem(.now, "3")
            pageItem(.review, "4")
            pageItem(.documents, "5")
            pageItem(.recentlyDeleted, "6")
        }
        CommandMenu("Course") {   // the course whose page is showing
            Button("Edit Course…") { nav?.editingCourse = nav?.course }.keyboardShortcut("e").disabled(nav?.course == nil)
            Button("Delete Course") { if let id = nav?.course { Task { await model.deleteCourse(id) } } }
                .disabled(nav?.course == nil)   // ⌘⌫ deletes what is selected in the page, as in Mail; the course goes from here, its menu, or Delete in the sidebar
        }
        CommandMenu("Item") {   // the item selected in a table (a course's items, Horizon's), and those selected in Review
            Button(item?.done == true ? "Mark Not Done" : "Mark Done") { if let item { item.mark(!item.done) } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(item == nil)
            Divider()
            Button(review.map { $0.count == 1 ? "Confirm" : "Confirm \($0.count) Items" } ?? "Confirm") { review?.confirm() }
                .keyboardShortcut(.return, modifiers: .command).disabled(review == nil)
            // ⌘⌫ acts on the selection in the page: Review's items are discarded, a table's item deleted.
            Button(review.map { $0.count == 1 ? "Discard" : "Discard \($0.count) Items" } ?? (item == nil ? "Discard" : "Delete Item")) {
                if let review { review.discard() } else { item?.delete() }
            }
            .keyboardShortcut(.delete, modifiers: .command).disabled(review == nil && item == nil)
        }
        CommandMenu("Plan") {
            Button(model.plan == nil ? "Plan Today" : "Plan Again") {
                if model.planEdited, model.plan != nil { nav?.confirmingReplan = true } else { Task { await model.planToday() } }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.planning)
            Button("Tell the Planner…") { nav?.tellingPlanner = true }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(nav == nil)
            Button("Add Block…") { nav?.addingBlock = true }.disabled(nav == nil)
            Divider()
            Picker("Tonight Until", selection: Binding(get: { model.tonightEnd }, set: { if model.chooseTonightEnd($0) { nav?.confirmingReplan = true } })) {
                ForEach(PlanHours.ends, id: \.self) { Text(PlanHours.choice($0, usual: model.usualPlanHours.end)).tag($0) }
            }
            .disabled(model.planning)
        }
        #if DEBUG
        CommandMenu("Debug") {
            Button("Ingest Sample Syllabus") {
                if let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") { Task { await model.importFiles([sample]) } }
            }
        }
        #endif
    }

    /// A page as a checked item in the View menu, with its number.
    private func pageItem(_ page: MacNavigation.Page, _ key: KeyEquivalent) -> some View {
        Toggle(page.title, isOn: Binding(get: { nav?.page == page }, set: { if $0 { nav?.show(page) } }))
            .keyboardShortcut(key).disabled(nav == nil)
    }
}

/// The Settings window (⌘,): General and Reading as toolbar panes, the way a Mac keeps its settings.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Form {
                DeviceSettingsSections()
                Section {
                    LabeledContent("Folder") { Text(WatchedFolder.url.path(percentEncoded: false)).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([WatchedFolder.url]) }
                } header: {
                    Kicker("Inbox")
                } footer: {
                    Text("Anything saved or dropped into this folder is read as soon as it stops changing.")
                }
            }
            .formStyle(.grouped)
            .frame(width: 580, height: 400)   // each pane its own height; the window follows the pane
            .tabItem { Label("General", systemImage: "gearshape") }
            Form { ReadingSettingsSections() }
                .formStyle(.grouped)
                .frame(width: 580, height: 640)
                .tabItem { Label("Reading", systemImage: "doc.text.magnifyingglass") }
        }
    }
}
#endif

#if os(macOS) && DEBUG
/// `--snapshot <path>` (DEBUG): a few seconds after launch the window draws itself into a PNG at `path`, toolbar
/// and all, and a second one, `<path>-2.png`, a few seconds later; `screencapture` cannot see a window while the
/// screen is locked, and this can.
enum WindowSnapshot {
    @MainActor static func writeIfAsked() async {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return }
        let path = CommandLine.arguments[i + 1]
        try? await Task.sleep(for: .seconds(4))
        write(to: path)
        try? await Task.sleep(for: .seconds(3))
        write(to: path.replacingOccurrences(of: ".png", with: "-2.png"))
    }

    @MainActor private static func write(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
