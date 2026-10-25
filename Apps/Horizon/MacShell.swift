#if os(macOS)
import SwiftUI
import SwiftData
import HorizonCore
import IngestKit
import AppKit

/// What a window shows, and what the menu bar's commands act on: one per window, handed to the commands through the
/// focused scene, so a command reaches the window in front; one that needs a window is dimmed when there is none.
@MainActor @Observable final class MacNavigation {
    enum Page: String, CaseIterable, Identifiable {
        /// `search` has no row of its own: the sidebar's search field shows it while it holds words.
        case coverage, horizon, now, review, documents, recentlyDeleted, search
        var id: String { rawValue }
        var title: String {
            switch self { case .coverage: "Coverage"; case .horizon: "Horizon"; case .now: "Now"; case .review: "Review"; case .documents: "Documents"; case .recentlyDeleted: "Recently Deleted"; case .search: "Search" }
        }
        var symbol: String {
            switch self { case .coverage: "eye"; case .horizon: "chart.bar.xaxis"; case .now: "sun.horizon"; case .review: "checkmark.circle"; case .documents: "doc.text"; case .recentlyDeleted: "trash"; case .search: "magnifyingglass" }
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
    /// Asks for the sidebar's search field (Edit ▸ Find ▸ Find…, ⌘F), showing the sidebar first when it is hidden.
    private(set) var findAsked = 0
    func find() { findAsked += 1 }

    var importing = false
    var addingItem = false
    /// The course an item is being added to from its own menu (its row in the sidebar, its story); else the one whose
    /// page is showing.
    var addingItemTo: UUID?
    var addingCourse = false
    /// The course being edited (Course ▸ Edit Course…, or the menu on its story or its row in the sidebar).
    var editingCourse: UUID?
    var addingBlock = false
    var tellingPlanner = false
    var confirmingReplan = false
    /// An item a `horizon://obligation/<id>` link asked for: the page that lists it (Review, or its course's) selects
    /// it and clears this.
    var reveal: UUID?
    /// What the Horizon page was asked to show (an intent's "show Calc on Horizon", a widget's day): it narrows to the
    /// course and chooses the day, then clears this.
    var horizonRequest: HorizonRequest?
    struct HorizonRequest: Equatable { var course: UUID?; var day: Date? }
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
    /// A table on the page: its rows on the paper, parted by the inset style's hairlines, and its header on the paper
    /// too (`PaperTableHeader`). The system's stripes are white and grey, and over the paper they read as a sheet of
    /// another colour laid on it.
    func paperTable() -> some View {
        tableStyle(.inset).alternatingRowBackgrounds(.disabled).scrollContentBackground(.hidden)
            .background(PaperTableHeader())
    }

    /// A page's list, which takes the keyboard as the page appears when it has rows (`PageKeyboard`).
    func takesKeyboard(_ focus: FocusState<Bool>.Binding, hasRows: Bool) -> some View {
        focused(focus).modifier(PageKeyboard(list: focus, hasRows: hasRows))
    }

    /// A page with no list: the keyboard goes to the sidebar as it appears (`PageKeyboard`).
    func keyboardStaysInSidebar() -> some View { modifier(PageKeyboard(list: nil, hasRows: false)) }
}

/// The item selected in a table of items, for the menu bar's Item commands. Published as the table's own focused value;
/// it stays published under a sheet, so the commands that act on it check `HorizonCommands.keyboardIsElsewhere` first
/// (⌘⌫ in a sheet's field deletes words, not the item).
struct SelectedItem: Equatable {
    var id: UUID
    var done: Bool
    var skipped: Bool
    /// Checks it off, or back on, the way its page does (a row just checked lingers where it was for a moment).
    var mark: (Bool) -> Void
    /// Skips it (closed, not done), or takes the skip back.
    var skip: (Bool) -> Void
    /// Opens its editor, as a double-click does.
    var edit: () -> Void
    /// Shows the document it was read from in Quick Look, when the file is on this Mac.
    var openDocument: (() -> Void)?
    /// Deletes it, the way the Delete key does.
    var delete: () -> Void
    static func == (a: SelectedItem, b: SelectedItem) -> Bool { a.id == b.id && a.done == b.done && a.skipped == b.skipped && (a.openDocument == nil) == (b.openDocument == nil) }
}

/// The documents selected in Documents, for the File menu: what the table's context menu does, from the menu bar.
struct DocumentActions: Equatable {
    var ids: Set<UUID>
    /// Shows the one selected file in Quick Look (nil when several are selected, or the file is on another device).
    var look: (() -> Void)?
    /// Reads again those that failed, were cancelled or wait for Claude.
    var retry: (() -> Void)?
    /// Asks, then reads on this Mac those waiting for Claude.
    var readOnDevice: (() -> Void)?
    /// Files the one selected document, read and loose, under a course.
    var fileUnder: [(name: String, file: () -> Void)]
    static func == (a: DocumentActions, b: DocumentActions) -> Bool {
        a.ids == b.ids && (a.look == nil) == (b.look == nil) && (a.retry == nil) == (b.retry == nil)
            && (a.readOnDevice == nil) == (b.readOnDevice == nil) && a.fileUnder.map(\.name) == b.fileUnder.map(\.name)
    }
}

/// The selection in Recently Deleted, for the File menu.
struct BinActions: Equatable {
    var ids: Set<UUID>
    var restore: () -> Void
    /// Asks first: it cannot be undone.
    var erase: () -> Void
    static func == (a: BinActions, b: BinActions) -> Bool { a.ids == b.ids }
}

extension FocusedValues {
    @Entry var navigation: MacNavigation?
    @Entry var selectedItem: SelectedItem?
    @Entry var reviewActions: ReviewActions?
    @Entry var documentActions: DocumentActions?
    @Entry var binActions: BinActions?
}

/// The Mac window: a sidebar of the app's areas and its courses, and a detail column (HIG: a sidebar holds the areas
/// and the top-level collections; Reminders keeps its lists there, Mail its mailboxes). A course is a place of its
/// own, one click from anywhere, and its page has the whole column: nothing is split inside the detail, so nothing
/// in it moves when something is chosen. The toolbar carries what acts on every page (Add Document, Sync), each page
/// adds its own after a gap, and a file from the Finder can be dropped anywhere on the window. Sheets the menu bar
/// opens (Add Item, New Course, Edit Course, Add Block, Tell the Planner) live here.
///
/// The toolbar is one thing on every page: no band of its own, the paper running up under it (a page's scroll views
/// fade softly beneath it once scrolled), so it never changes from page to page, nor splits where a page's columns
/// meet (a course's rail, Review's detail and Now's column each claimed it for themselves).
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var nav = MacNavigation()
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var dropping = false
    /// An item a link asked for that no page lists (no course, nothing to review): its editor, over the window.
    @State private var linkedItem: Obligation?
    /// A document's file asked for (an intent, a Spotlight result): Quick Look, over the window.
    @State private var preview: URL?
    @State private var photos: ImportPickers.Photos?
    @State private var noFiles = false
    @State private var noScan = false
    @FocusState private var searchFocused: Bool

    private var shownCourse: Course? { nav.course.flatMap { id in courses.first { $0.id == id } } }
    private var editedCourse: Course? { nav.editingCourse.flatMap { id in courses.first { $0.id == id } } }

    var body: some View {
        @Bindable var nav = nav
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(nav: nav)
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")   // the app's one search, at the sidebar's head (HIG)
                .searchFocused($searchFocused)
        } detail: {
            detail
                .environment(nav)   // a page asks it whether to take the keyboard as it appears
                .scrollEdgeEffectStyle(.soft, for: .top)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .navigationSplitViewColumnWidth(min: 740, ideal: 1000)   // the narrowest a page's tables keep their key columns at; the sidebar gives way first
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
        .sheet(isPresented: $nav.addingItem, onDismiss: { nav.addingItemTo = nil }) {   // added from a course's menu or on its page: that course
            ObligationEditor(mode: .manual, courses: courses, preferredCourse: nav.addingItemTo ?? shownCourse?.id)
        }
        .sheet(item: $linkedItem) { ObligationEditor(mode: .edit($0), courses: courses) }
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
        .onChange(of: model.destination) { _, destination in route(destination) }
        .onChange(of: model.searchText) { _, text in   // words in the field show what matches; an empty field, where the window was
            let searching = !text.trimmingCharacters(in: .whitespaces).isEmpty
            if searching, nav.page != .search { nav.destination = .page(.search) } else if !searching, nav.page == .search { nav.show(.coverage) }
        }
        .onChange(of: nav.findAsked) {
            guard columns != .all else { searchFocused = true; return }
            columns = .all
            Task { @MainActor in searchFocused = true }   // once the sidebar holding the field is back
        }
        .quickLookPreview($preview)
        .modifier(ImportPickers(courseID: nil, files: $noFiles, photos: $photos, scanning: $noScan))   // the file importer is ⌘O's (`nav.importing`)
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])   // a link or a file opened from outside comes to this window, not a new one
        .onAppear {
            if MainTabs.debugFlag("--tab-horizon") { nav.show(.horizon) }
            if MainTabs.debugFlag("--tab-now") { nav.show(.now) }
            if MainTabs.debugFlag("--open-documents") { nav.show(.documents) }
            if MainTabs.debugFlag("--open-recently-deleted") { nav.show(.recentlyDeleted) }
            if MainTabs.debugFlag("--open-review") { nav.show(.review) }
            if MainTabs.debugFlag("--open-course"), let first = Coverage.stories(courses: courses, obligations: [], documents: []).first { nav.show(course: first.course.id) }   // DEBUG: a course's page without a click
            if MainTabs.debugFlag("--open-settings") { openSettings() }
            route(model.destination)   // a link or an intent that launched the app
            #if DEBUG
            if let i = CommandLine.arguments.firstIndex(of: "--open-link"), i + 1 < CommandLine.arguments.count, let url = URL(string: CommandLine.arguments[i + 1]) {
                Task { await model.open(url) }   // DEBUG: a horizon:// link without a reminder to click
            }
            if MainTabs.debugFlag("--light") { NSApp.appearance = NSAppearance(named: .aqua) }   // the app's own appearance, for screenshots; the system's is left alone
            if MainTabs.debugFlag("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            #endif
        }
    }

    /// Where the app was asked to go (`AppModel.destination`: a link, an intent, Spotlight), in the window that takes
    /// it first; the app comes forward. Settings is its own window, Search the sidebar's field.
    private func route(_ destination: AppDestination?) {
        guard let destination else { return }
        model.destination = nil
        switch destination {
        case .page(.coverage): nav.show(.coverage)
        case .page(.horizon): nav.show(.horizon)
        case .page(.now): nav.show(.now)
        case .page(.review): nav.show(.review)
        case .page(.documents): nav.show(.documents)
        case .page(.recentlyDeleted): nav.show(.recentlyDeleted)
        case .page(.settings): openSettings()
        case .page(.search), .search: if !model.searchText.isEmpty { nav.destination = .page(.search) }
        case .course(let id), .policies(let id):
            if courses.contains(where: { $0.id == id }) { nav.show(course: id) } else { model.lastError = "That course is no longer in Horizon." }
        case .item(let id): show(linked: id)
        case .document(let id):
            if let document = try? context.fetch(FetchDescriptor<SourceDocument>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })).first {
                preview = model.previewFile(for: document)
            }
        case .horizon(let course, let day):
            nav.horizonRequest = .init(course: course, day: day)
            nav.show(.horizon)
        case .importDocument(let choice):
            switch choice {
            case .files, .camera: nav.importing = true   // no document camera on a Mac
            case .photos: photos = .images
            case .screenshots: photos = .screenshots
            }
        }
        NSApp.activate()
    }

    /// A `horizon://obligation/<id>` link (the link on every reminder): the item where it lives, selected. Review when it
    /// waits there, else its course's page; an item neither lists opens in its editor.
    private func show(linked id: UUID) {
        guard let item = try? context.fetch(FetchDescriptor<Obligation>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })).first else { return }   // deleted since its reminder was written
        if item.state == .pendingReview, item.completedAt == nil {
            nav.reveal = id; nav.show(.review)
        } else if let course = item.course, course.deletedAt == nil {
            nav.reveal = id; nav.show(course: course.id)
        } else {
            linkedItem = item
        }
        NSApp.activate()
    }

    @ViewBuilder private var detail: some View {
        switch nav.destination {
        case .page(.coverage): MacCoveragePage(nav: nav).keyboardStaysInSidebar()
        case .page(.horizon): MacHorizonPage()
        case .page(.now): NowView().keyboardStaysInSidebar()
        case .page(.review): MacReviewPage()
        case .page(.documents): DocumentsTable()
        case .page(.recentlyDeleted): RecentlyDeletedTable()
        case .page(.search): MacSearchPage(nav: nav).keyboardStaysInSidebar()
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
    /// The user's own order, then by name: a sidebar row stays where it is (Coverage, which follows the same order once
    /// there is one, puts the courses without one most suspicious first, which moves as items are checked off; a place
    /// to go to must not).
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
                                Button("Add Item…") { nav.addingItemTo = course.id; nav.addingItem = true }
                                Button("Edit Course…") { nav.editingCourse = course.id }
                                Divider()
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

/// Documents as a table on the paper (`paperTable()`: no stripes): sortable, a context menu and the Delete key on the
/// selection, and the same actions in the File menu while the table has the keyboard.
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
        Group {
            if documents.isEmpty {
                ScrollView {
                    EditorialEmpty(title: "No documents yet.", deck: "Add a syllabus, a schedule or a screenshot, or drop one on this window. Every document Horizon reads is listed here, with what became of it.") {
                        ImportMenu().buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, Design.margin)
                }
                .keyboardStaysInSidebar()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    PageLine("Everything Horizon has been given to read. Select a document and press Space to look at it.")
                    table
                }
            }
        }
        .background(Design.paper)
        .confirmationDialog("Read on this Mac instead?", isPresented: Binding(get: { !confirmDevice.isEmpty }, set: { if !$0 { confirmDevice = [] } }), titleVisibility: .visible) {
            Button(confirmDevice.count == 1 ? "Read on This Mac" : "Read \(confirmDevice.count) on This Mac") {
                let ids = confirmDevice.map(\.id)
                Task { for id in ids { await model.readOnDevice(documentID: id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Mac's own model is less sure of tables and pictures than Claude, and it takes minutes on a long document. Nothing is sent to Anthropic.")
        }
        .quickLookPreview($preview)
        .navigationTitle("Documents")
    }

    /// Ideal widths that fit the narrowest page (the detail column's minimum) with every column in view; the columns
    /// share what a wider window adds.
    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Document", value: \.displayName) { doc in   // two lines on every row, so the rows keep one height
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.displayName).fontWeight(.medium).lineLimit(1)
                    Text(doc.displayName != doc.filename ? doc.filename : Self.kind(doc)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)   // the file it came as
                }
                .padding(.vertical, 3)
                .help(doc.displayName)
            }
            .width(min: 140, ideal: 190)
            TableColumn("Status", value: \.statusLabel) { doc in
                HStack(spacing: 4) {
                    Text(doc.statusLabel).foregroundStyle(doc.status == .failed ? Design.accentInk : .primary)
                        .help(doc.failure ?? "")   // why it could not be read, on hover
                    if !doc.warnings.isEmpty {   // what the read had to say, on hover
                        Text(doc.warnings.count == 1 ? "· 1 note" : "· \(doc.warnings.count) notes").foregroundStyle(.secondary)
                            .help(doc.warnings.joined(separator: "\n"))
                    }
                }
                .lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Course") { doc in
                if let course = doc.course { Text(course.displayName).lineLimit(1) }
                else if doc.status == .parsed, !courses.isEmpty {
                    Menu("File Under…") {
                        ForEach(courses) { course in Button(course.displayName) { Task { await model.assignDocument(doc.id, to: course.id) } } }
                    }
                    .fixedSize()
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Added", value: \.queuedAt) { doc in Text(Self.added(doc.queuedAt)).monospacedDigit().lineLimit(1) }.width(min: 90, ideal: 110)
            TableColumn("Read") { doc in
                if doc.status == .parsed {
                    Text("\(doc.inputTokens) in · \(doc.outputTokens) out · \(doc.durationMs / 1000) s · \(Self.routeName(doc.route))").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        .help("\(doc.inputTokens) tokens in, \(doc.outputTokens) out, \(doc.durationMs / 1000) seconds, read \(Self.routeName(doc.route) == "Claude" ? "by Claude" : Self.routeName(doc.route))")
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 80, ideal: 100)
        }
        .paperTable()
        .takesKeyboard($focused, hasRows: true)
        .animation(.default, value: documents.map(\.id))   // rows come and go as a Mac table's do
        .contextMenu(forSelectionType: UUID.self) { ids in
            let docs = chosen(ids)
            if docs.count == 1, let doc = docs.first, model.hasFile(doc) {
                Button("Quick Look") { look(at: doc) }
                Divider()
            }
            if docs.contains(where: Self.canRetry) {
                Button("Retry") { retry(docs) }
            }
            if docs.contains(where: Self.waitsForClaude) {
                Button("Read on This Mac Instead…") { confirmDevice = docs.filter(Self.waitsForClaude) }
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
        .focusedValue(\.documentActions, actions)
    }

    /// The File menu's share of the context menu, for the selection.
    private var actions: DocumentActions? {
        let docs = chosen(selection)
        guard !docs.isEmpty else { return nil }
        let one = docs.count == 1 ? docs.first : nil
        let loose = one.flatMap { $0.course == nil && $0.status == .parsed ? $0 : nil }
        return DocumentActions(
            ids: Set(docs.map(\.id)),
            look: one.flatMap { doc in model.hasFile(doc) ? { look(at: doc) } : nil },
            retry: docs.contains(where: Self.canRetry) ? { retry(docs) } : nil,
            readOnDevice: docs.contains(where: Self.waitsForClaude) ? { confirmDevice = docs.filter(Self.waitsForClaude) } : nil,
            fileUnder: loose.map { doc in courses.map { course in (name: course.displayName, file: { file(doc.id, under: course.id) }) } } ?? [])
    }

    private static func canRetry(_ doc: SourceDocument) -> Bool { doc.status == .failed || doc.status == .awaitingCloudParse || doc.status == .cancelled }
    private static func waitsForClaude(_ doc: SourceDocument) -> Bool { doc.status == .awaitingCloudParse && !doc.readOnDevice }
    private func file(_ document: UUID, under course: UUID) { Task { await model.assignDocument(document, to: course) } }
    private func retry(_ docs: [SourceDocument]) { for doc in docs where Self.canRetry(doc) { Task { await model.retry(documentID: doc.id) } } }

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

/// Recently Deleted as a table: Restore and Delete Now on the selection (toolbar, context menu, the File menu, the
/// Delete key); only Delete Now asks, since it cannot be undone. Double-clicking a row restores it. Sortable, newest
/// deletion first.
struct RecentlyDeletedTable: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\BinEntry.deletedAt, order: .reverse)]
    @State private var erasing: [BinEntry] = []

    private var entries: [BinEntry] {
        (courses.map(BinEntry.init) + deletedDocuments.filter(\.isBinned).map(BinEntry.init)).sorted(using: sortOrder)
    }
    private func chosen(_ ids: Set<UUID>) -> [BinEntry] { entries.filter { ids.contains($0.id) } }

    var body: some View {
        let entries = entries
        Group {
            if entries.isEmpty {
                ScrollView {
                    EditorialEmpty(title: "Nothing deleted lately.", deck: "A course or document you delete waits here for 30 days, and can be put back until then.") { EmptyView() }
                        .padding(.horizontal, Design.margin)
                }
                .keyboardStaysInSidebar()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    PageLine("Deleted courses and documents wait here for 30 days. Double-click one to put it back.")
                    table(entries)
                }
            }
        }
        .background(Design.paper)
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)   // the page's own, apart from the window's Add Document and Sync
            ToolbarItemGroup(placement: .primaryAction) {   // both in the File menu too
                Button { restore(selection) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .help("Put the selection back").disabled(chosen(selection).isEmpty)
                Button { erasing = chosen(selection) } label: { Label("Delete Now", systemImage: "trash.slash") }
                    .help("Delete the selection for good").disabled(chosen(selection).isEmpty)
            }
        }
        .alert(eraseTitle, isPresented: Binding(get: { !erasing.isEmpty }, set: { if !$0 { erasing = [] } })) {
            Button("Delete Now", role: .destructive) { for entry in erasing { erase(entry) }; erasing = [] }
            Button("Cancel", role: .cancel) { erasing = [] }
        } message: {
            Text("This cannot be undone.")
        }
        .navigationTitle("Recently Deleted")
    }

    /// Ideal widths that fit the narrowest page with every column in view; the columns share what a wider window adds.
    private func table(_ entries: [BinEntry]) -> some View {
        Table(entries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in Text(entry.name).fontWeight(.medium).lineLimit(1).help(entry.name) }.width(min: 140, ideal: 220)
            TableColumn("Kind", value: \.kindName) { entry in Text(entry.kindName) }.width(min: 70, ideal: 80)
            TableColumn("Holds", value: \.held) { entry in Text(holds(entry)).foregroundStyle(.secondary).lineLimit(1) }.width(min: 90, ideal: 130)
            TableColumn("Deleted", value: \.deletedAt) { entry in Text(entry.deletedAt.formatted(.relative(presentation: .named))).lineLimit(1) }.width(min: 90, ideal: 110)
            TableColumn("Gone in", value: \.expiry) { entry in Text(remaining(entry)).monospacedDigit() }.width(min: 60, ideal: 70)
        }
        .paperTable()
        .takesKeyboard($focused, hasRows: true)
        .animation(.default, value: entries.map(\.id))   // restored and erased rows leave as a Mac table's do
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Restore") { restore(ids) }
            Button("Delete Now…", role: .destructive) { erasing = chosen(ids) }
        } primaryAction: { ids in
            restore(ids)
        }
        .onDeleteCommand { erasing = chosen(selection) }
        .focusedValue(\.binActions, chosen(selection).isEmpty ? nil : BinActions(ids: selection, restore: { restore(selection) }, erase: { erasing = chosen(selection) }))
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
        let days = max(0, Int((entry.expiry.timeIntervalSinceNow / 86400).rounded(.up)))
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

extension BinEntry {
    /// What it is, in a word, and what the table sorts the Kind column by.
    var kindName: String { kind == .course ? "Course" : "Document" }
    /// How much went with it, for sorting the Holds column: items first, then documents.
    var held: Int { items * 1000 + documents }
    /// When it is erased for good.
    var expiry: Date { Bin.expiry(of: deletedAt) }
}

/// The line that opens a page of a table, on the paper above it (Review's, Documents', Recently Deleted's): it says
/// what the page holds, and it keeps the table off the toolbar, whose band a table's pinned header would otherwise
/// bring back on just these pages.
struct PageLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, Design.margin)
            .padding(.top, 16)
            .padding(.bottom, 12)
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
/// and the keyboard suffices. Commands act on the window in front through the focused `MacNavigation`, and on a
/// page's selection only while its table has the keyboard (a sheet's fields then keep their own keys: ⌘⌫ deletes
/// words in a title, never the item behind the sheet).
struct HorizonCommands: Commands {
    let model: AppModel
    @FocusedValue(\.navigation) private var nav
    @FocusedValue(\.selectedItem) private var item
    @FocusedValue(\.reviewActions) private var review
    @FocusedValue(\.documentActions) private var documents
    @FocusedValue(\.binActions) private var bin

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Document…") { nav?.importing = true }.keyboardShortcut("o").disabled(nav == nil)
            Button("Add Item…") { nav?.addingItem = true }.keyboardShortcut("n").disabled(nav == nil)
            Button("New Course…") { nav?.addingCourse = true }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(nav == nil)
            Divider()
            // The documents selected in Documents, as their context menu has them.
            Button("Quick Look") { documents?.look?() }.keyboardShortcut("y").disabled(documents?.look == nil)
            Button("Retry Reading") { documents?.retry?() }.disabled(documents?.retry == nil)
            Button("Read on This Mac Instead…") { documents?.readOnDevice?() }.disabled(documents?.readOnDevice == nil)
            if let courses = documents?.fileUnder, !courses.isEmpty {
                Menu("File Under") {
                    ForEach(Array(courses.enumerated()), id: \.offset) { _, course in Button(course.name) { course.file() } }
                }
            } else {
                Button("File Under") {}.disabled(true)   // an empty submenu would not dim
            }
            Divider()
            // What is selected in Recently Deleted.
            Button("Restore") { bin?.restore() }.disabled(bin == nil)
            Button("Delete Now…") { bin?.erase() }.disabled(bin == nil)
            Divider()
            Button("Sync with Reminders") { Task { await model.drainAndSync() } }.keyboardShortcut("r")
            Button("Recreate Horizon List in Reminders") { Task { await model.recreateRemindersList() } }.disabled(!model.remindersListGone)
            Button("Show Inbox Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([WatchedFolder.url]) }
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {   // HIG: Edit ▸ Find ▸ Find… (⌘F); the app's one search is the sidebar's field
                Button("Find…") { if NSApp.keyWindow?.sheetParent == nil { nav?.find() } }   // under a sheet, the sheet keeps the keyboard
                    .keyboardShortcut("f").disabled(nav == nil)
            }
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
            Button(ItemActions.markTitle(done: item?.done == true)) { if !Self.keyboardIsElsewhere, let item { item.mark(!item.done) } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(item == nil)
            Button(ItemActions.skipTitle(skipped: item?.skipped == true)) { if !Self.keyboardIsElsewhere, let item { item.skip(!item.skipped) } }
                .disabled(item == nil)
            Button("Edit Item…") { if !Self.keyboardIsElsewhere { (review?.edit ?? item?.edit)?() } }   // Return in the table, as a double-click
                .disabled(review?.edit == nil && item == nil)
            Button("Open Document") { (review?.openDocument ?? item?.openDocument)?() }
                .disabled(review?.openDocument == nil && item?.openDocument == nil)
            Divider()
            Button(review.map { $0.count == 1 ? "Confirm" : "Confirm \($0.count) Items" } ?? "Confirm") { if !Self.keyboardIsElsewhere { review?.confirm() } }
                .keyboardShortcut(.return, modifiers: .command).disabled(review == nil)
            // A later document moved the date: the choice is between the two dates (Discard would delete the item).
            Button(review?.otherDate.map { "Use \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "Use Other Date") { if !Self.keyboardIsElsewhere { review?.useOtherDate?() } }
                .disabled(review?.useOtherDate == nil)
            // ⌘⌫ acts on the selection in the page: Review's items are discarded, a table's item deleted. In a text
            // field (an editor's Title, the key in Settings) it is the text's own ⌘⌫, to the line's start.
            Button(deleteTitle) {
                if Self.keyboardIsElsewhere { NSApp.sendAction(#selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)), to: nil, from: nil); return }
                if let review { review.discard?() } else { item?.delete() }
            }
            .keyboardShortcut(.delete, modifiers: .command).disabled(review?.discard == nil && item == nil)
        }
        CommandMenu("Plan") {   // each needs a window: an edited plan asks there before it is replaced
            Button(model.plan == nil ? "Plan Today" : "Plan Again") {
                if model.planEdited, model.plan != nil { nav?.confirmingReplan = true } else { Task { await model.planToday() } }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.planning || nav == nil || model.storeFailure != nil)
            // ⌥⌘P, beside Plan Today: ⌥⌘T is the system's Show/Hide Toolbar (HIG keyboards), which View already has.
            Button("Tell the Planner…") { nav?.tellingPlanner = true }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(nav == nil)
            Button("Add Block…") { nav?.addingBlock = true }.disabled(nav == nil)
            Divider()
            Picker("Tonight Until", selection: Binding(get: { model.tonightEnd }, set: { if model.chooseTonightEnd($0) { nav?.confirmingReplan = true } })) {
                ForEach(PlanHours.endsAhead(including: model.tonightEnd), id: \.self) { Text(PlanHours.choice($0, usual: model.usualPlanHours.end)).tag($0) }   // only the ends still ahead, as Now's pop-up
            }
            .disabled(model.planning || nav == nil || model.storeFailure != nil)
        }
        #if DEBUG
        CommandMenu("Debug") {
            Button("Ingest Sample Syllabus") {
                if let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") { Task { await model.importFiles([sample]) } }
            }
        }
        #endif
    }

    /// The keyboard is somewhere a ⌘-key belongs to what is being typed or to a sheet, not to the page's selection: a
    /// field being edited, or an editor's sheet over the window. A menu's key equivalent is matched before a field sees
    /// the key, and a table's selection stays published under a sheet, so ⌘⌫ in an editor's Title deleted the item
    /// selected behind it (seen 2026-10-05).
    @MainActor static var keyboardIsElsewhere: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return window.sheetParent != nil || window.firstResponder is NSText
    }

    /// ⌘⌫'s item: Discard in Review (those of the selection a later document did not move), Delete Item elsewhere.
    private var deleteTitle: String {
        if let review { return review.discardCount <= 1 ? "Discard" : "Discard \(review.discardCount) Items" }
        return nav?.page == .review ? "Discard" : "Delete Item"
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
                LibrarySettingsSection()
            }
            .formStyle(.grouped)
            .frame(width: 580, height: 600)   // each pane its own height; the window follows the pane
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


#if os(macOS)
/// A table's header on the paper. AppKit pins the header over a band of its hard scroll edge (a view of its own in the
/// header's banner, which lightens what is under it: a white strip across the cream), and nothing public changes it:
/// SwiftUI's `scrollEdgeEffectStyle` and `scrollEdgeEffectHidden` do not reach a table's scroll view, and AppKit's edge
/// styles are for title bar accessories. So the header's clip view is given the paper, opaque (rows scroll under it
/// unseen), and the band is hidden. Found by looking, at the table this sits behind; if the views are not there (a
/// later system), nothing is changed and the band is back.
struct PaperTableHeader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Dresser() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Dresser)?.dress() }

    final class Dresser: NSView {
        private weak var header: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.dress() }   // the table's own views are made after this one
        }
        override func layout() { super.layout(); dress() }

        func dress() {
            if header?.window == nil { header = find() }
            guard let header else { return }
            if !header.drawsBackground { header.drawsBackground = true }
            header.backgroundColor = NSColor(Design.paper)
            for band in Self.views(in: header) where !band.isHidden && String(describing: type(of: band)).contains("HardPocket") { band.isHidden = true }
        }

        /// The clip view holding the header of the table this sits behind (its scroll view covers this view's middle).
        private func find() -> NSClipView? {
            guard let window, let content = window.contentView else { return nil }
            let middle = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let scroll = Self.views(in: content).lazy.compactMap { $0 as? NSScrollView }
                .first { $0.documentView is NSTableView && $0.convert($0.bounds, to: nil).contains(middle) }
            return scroll.flatMap { Self.views(in: $0).first { $0 is NSTableHeaderView }?.superview as? NSClipView }
        }

        private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    }
}
#endif
