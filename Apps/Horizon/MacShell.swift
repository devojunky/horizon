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
    var page: Page = .coverage
    /// The course in Coverage's detail pane.
    var course: UUID?
    var importing = false
    var addingItem = false
    var addingCourse = false
    var editingCourse = false
    var addingBlock = false
    var tellingPlanner = false
    var confirmingReplan = false
}

/// The item highlighted on a course's page, for the menu bar's Item commands.
struct SelectedItem: Equatable {
    var id: UUID
    var done: Bool
}

extension FocusedValues {
    @Entry var navigation: MacNavigation?
    @Entry var selectedItem: SelectedItem?
}

/// The Mac window: a sidebar of the app's areas and a detail column, the toolbar carrying what acts on every page
/// (Add Document, Sync), and a drop target for files from the Finder anywhere on it. Sheets the menu bar opens
/// (Add Item, New Course, Edit Course, Add Block, Tell the Planner) live here.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var nav = MacNavigation()
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var dropping = false

    private var selectedCourse: Course? { courses.first { $0.id == nav.course } }

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(page: $nav.page)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {   // both are File menu commands as well
                        ImportMenu().help("Add a document to read (⌘O)")
                        Button { Task { await model.drainAndSync() } } label: { Label("Sync with Reminders", systemImage: "arrow.triangle.2.circlepath") }
                            .help("Read what is queued and sync with Reminders (⌘R)")
                    }
                }
        }
        .focusedSceneValue(\.navigation, nav)
        .dropDestination(for: URL.self) { urls, _ in   // a syllabus dragged out of the Finder
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await model.importFiles(files) }
            return true
        } isTargeted: { dropping = $0 }
        .overlay { if dropping { DropVeil().transition(.opacity) } }
        .animation(.snappy, value: dropping)
        .frame(minWidth: 980, minHeight: 620)
        .fileImporter(isPresented: $nav.importing, allowedContentTypes: ImportMenu.readable, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls) } }
        }
        .sheet(isPresented: $nav.addingItem) { ObligationEditor(mode: .manual, courses: courses) }
        .sheet(isPresented: $nav.addingCourse) { CourseEditor(course: nil) }
        .sheet(isPresented: $nav.editingCourse) { if let selectedCourse { CourseEditor(course: selectedCourse) } }
        .sheet(isPresented: $nav.addingBlock) { PlanBlockEditor(block: nil) }
        .sheet(isPresented: $nav.tellingPlanner) { PlannerNotesEditor() }
        .confirmationDialog("Replace the plan you edited?", isPresented: $nav.confirmingReplan, titleVisibility: .visible) {
            Button("Plan Again", role: .destructive) { Task { await model.planToday() } }
        } message: {
            Text("Your changes to today's blocks are lost.")
        }
        .onAppear {
            if MainTabs.debugFlag("--tab-horizon") { nav.page = .horizon }
            if MainTabs.debugFlag("--tab-now") { nav.page = .now }
            if MainTabs.debugFlag("--open-documents") { nav.page = .documents }
            if MainTabs.debugFlag("--open-recently-deleted") { nav.page = .recentlyDeleted }
            if MainTabs.debugFlag("--open-review") { nav.page = .review }
            if MainTabs.debugFlag("--open-settings") { openSettings() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav.page {
        case .coverage: CoveragePane(nav: nav)
        case .horizon: HorizonStripView()
        case .now: NowView()
        case .review: ReviewView()
        case .documents: DocumentsTable()
        case .recentlyDeleted: RecentlyDeletedTable()
        }
    }
}

/// The areas of the app, with what waits in two of them as badges.
private struct Sidebar: View {
    @Binding var page: MacNavigation.Page
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var binnedCourses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]

    private var toReview: Int { obligations.filter { $0.state == .pendingReview && $0.completedAt == nil }.count }   // done needs no review
    private var binned: Int { binnedCourses.count + deletedDocuments.filter(\.isBinned).count }

    var body: some View {
        List(selection: Binding(get: { Optional(page) }, set: { if let chosen = $0 { page = chosen } })) {
            Section {
                row(.coverage)
                row(.horizon)
                row(.now)
            }
            Section("Library") {
                row(.review).badge(toReview)
                row(.documents)
                row(.recentlyDeleted).badge(binned)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
    }

    /// The icon in the app's accent whatever accent the system is set to (a sidebar's icons otherwise take the
    /// system's, blue by default, and ignore a tint set on the window).
    private func row(_ page: MacNavigation.Page) -> some View {
        Label { Text(page.title) } icon: { Image(systemName: page.symbol).foregroundStyle(Design.accent) }.tag(page)
    }
}

/// Coverage on a Mac: the stories in a pane on the left, the selected course's page on the right, the divider theirs
/// to move. A story stays highlighted while its course is shown; a right-click or the Delete key acts on it.
private struct CoveragePane: View {
    @Bindable var nav: MacNavigation
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]

    /// The user's own order first; courses without one follow, most suspicious first.
    private var stories: [CourseCoverage] {
        let live = obligations.map(ObligationSnapshot.init)
        let docs = documents.map(DocumentSnapshot.init)
        return courses.map { Coverage.assess(course: CourseSnapshot($0), obligations: live, documents: docs) }.sorted { a, b in
            switch (a.course.sortOrder, b.course.sortOrder) {
            case (let x?, let y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.suspicion > b.suspicion
            }
        }
    }
    private var selected: Course? { courses.first { $0.id == nav.course } }

    var body: some View {
        HSplitView {
            List(selection: $nav.course) {
                IntakeStatus(openDocuments: { nav.page = .documents }).selectionDisabled()
                if stories.isEmpty, model.reading == nil {
                    EditorialEmpty(title: "Nothing on file.", deck: "Add a syllabus, a schedule, or a screenshot of an assignment list, or drop one on this window. Horizon reads it, writes the deadlines to Reminders, and tells you where it is still blind.") {
                        ImportMenu().buttonStyle(.borderedProminent)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .selectionDisabled()
                }
                ForEach(stories) { story in
                    CoverageStory(story: story)
                        .tag(story.course.id)
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(Design.rule)
                        .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
                        .contextMenu {
                            Button("Edit Course…") { nav.course = story.course.id; nav.editingCourse = true }
                            Button("Delete Course", role: .destructive) { Task { await model.deleteCourse(story.course.id) } }
                        }
                }
                .onMove { from, to in
                    var order = stories.map(\.course.id)
                    order.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorderCourses(order) }
                }
            }
            .listStyle(.inset)
            .paper()
            .animation(.default, value: courses.map(\.id))
            .onDeleteCommand { if let id = nav.course { Task { await model.deleteCourse(id) } } }
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 560, maxHeight: .infinity)
            Group {
                if let selected {
                    CourseView(course: selected).id(selected.id)
                } else {
                    ContentUnavailableView("No Course Selected", systemImage: "book", description: Text("Choose a course to see its grade table, items and policies."))
                }
            }
            .frame(minWidth: 440, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)   // a small ideal: the pane takes what the list leaves, never more than the column
            .background(Design.paper)
        }
        .navigationTitle("Coverage")
        .navigationSubtitle(selected?.displayName ?? "")
        .onChange(of: courses.map(\.id), initial: true) { _, ids in   // something is always shown when there is something to show
            if nav.course.map({ !ids.contains($0) }) ?? true { nav.course = stories.first?.course.id ?? ids.first }
        }
    }
}

/// Documents as a table: sortable, alternating rows, a context menu and the Delete key on the selection.
struct DocumentsTable: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\SourceDocument.queuedAt, order: .reverse)]
    @State private var confirmDevice: [SourceDocument] = []   // waiting for Claude; the Mac may read them once the user says so

    private var rows: [SourceDocument] { documents.sorted(using: sortOrder) }
    private func chosen(_ ids: Set<UUID>) -> [SourceDocument] { documents.filter { ids.contains($0.id) } }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Document", value: \.displayName) { doc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.displayName).fontWeight(.medium)
                    if doc.displayName != doc.filename { Text(doc.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }   // the file it came as
                    if let failure = doc.failure { Text(failure).font(.caption).foregroundStyle(Design.accent) }
                    if !doc.warnings.isEmpty {   // what the read had to say, on hover
                        Text(doc.warnings.count == 1 ? "1 note from the read" : "\(doc.warnings.count) notes from the read").font(.caption).foregroundStyle(.secondary)
                            .help(doc.warnings.joined(separator: "\n"))
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 220, ideal: 320)
            TableColumn("Status", value: \.statusLabel) { doc in Text(doc.statusLabel) }.width(min: 80, ideal: 120)
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
            TableColumn("Added", value: \.queuedAt) { doc in Text(doc.queuedAt.formatted(date: .abbreviated, time: .shortened)) }.width(min: 130, ideal: 160)
            TableColumn("Read") { doc in
                if doc.status == .parsed {
                    Text("\(doc.inputTokens) in · \(doc.outputTokens) out · \(doc.durationMs / 1000) s · \(Self.routeName(doc.route))").monospacedDigit().foregroundStyle(.secondary)
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 200, ideal: 300)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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
        }
        .onDeleteCommand { delete(selection) }
        .opacity(documents.isEmpty ? 0 : 1)
        .overlay {
            if documents.isEmpty {
                ContentUnavailableView("No Documents", systemImage: "doc.text", description: Text("Add a syllabus, a schedule or a screenshot, or drop one on this window."))
                    .background(Design.paper)
            }
        }
        .navigationTitle("Documents")
    }

    static func routeName(_ raw: String?) -> String {
        switch raw { case "onDevice": "on this Mac"; case "claude": "Claude"; case "privateCloudCompute": "Private Cloud Compute"; case "openAI": "OpenAI"; default: raw ?? "" }   // the last two: documents read before Claude
    }

    private func delete(_ ids: Set<UUID>) {   // straight to Recently Deleted, restorable for 30 days
        for id in ids { Task { await model.deleteDocument(id) } }
        selection.subtract(ids)
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
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Restore") { restore(ids) }
            Button("Delete Now…", role: .destructive) { erasing = chosen(ids) }
        } primaryAction: { ids in
            restore(ids)
        }
        .onDeleteCommand { erasing = chosen(selection) }
        .toolbar {
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
    var body: some View {
        ZStack {
            Design.paper.opacity(0.88)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc").font(.system(size: 44, weight: .light)).foregroundStyle(Design.accent)
                Text("Drop to read").deck()
                Text("A syllabus, a schedule, a screenshot.").foregroundStyle(.secondary)
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Document…") { nav?.importing = true }.keyboardShortcut("o").disabled(nav == nil)
            Button("Add Item…") { nav?.addingItem = true }.keyboardShortcut("n").disabled(nav == nil)
            Button("New Course…") { nav?.addingCourse = true }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(nav == nil)
            Divider()
            Button("Sync with Reminders") { Task { await model.drainAndSync() } }.keyboardShortcut("r")
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
        CommandMenu("Course") {
            Button("Edit Course…") { nav?.editingCourse = true }.keyboardShortcut("e").disabled(nav?.course == nil)
            Button("Delete Course") { if let id = nav?.course { Task { await model.deleteCourse(id) } } }
                .keyboardShortcut(.delete, modifiers: .command).disabled(nav?.course == nil)
        }
        CommandMenu("Item") {   // the item highlighted on the course's page
            Button(item?.done == true ? "Mark Not Done" : "Mark Done") { if let item { Task { await model.setCompleted(item.id, !item.done) } } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(item == nil)
        }
        CommandMenu("Plan") {
            Button(model.plan == nil ? "Plan Today" : "Plan Again") {
                if model.planEdited, model.plan != nil { nav?.confirmingReplan = true } else { Task { await model.planToday() } }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.planning)
            Button("Tell the Planner…") { nav?.tellingPlanner = true }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(nav == nil)
            Button("Add Block…") { nav?.addingBlock = true }.disabled(nav == nil)
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
        Toggle(page.title, isOn: Binding(get: { nav?.page == page }, set: { if $0 { nav?.page = page } }))
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
