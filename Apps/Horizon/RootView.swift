import SwiftUI
import SwiftData
import AppIntents
import HorizonCore
#if canImport(UIKit)
import UIKit
#endif

/// The pages the home stack can push. One typed path, so a push can refuse to double up (a link that fires twice, a
/// flag and a tap): `RootView.open` pushes a route only when it is not already on the path.
enum Route: Hashable {
    case course(UUID)
    case documents
    case recentlyDeleted
    case settings
    /// Review as a page of its own, for the app's destinations; the list's own row still pushes it by a link.
    case review
    /// An item's details (`ItemDetail`): a row tapped on any page, a reminder's link, Spotlight, Siri's Open Item.
    case item(UUID)
}

/// Pushes a route on the home stack; pages down the stack (Documents, Recently Deleted) use it instead of links. The closure
/// rides in a struct, the shape of SwiftUI's own actions (OpenURLAction): the environment cannot compare a bare closure.
struct OpenRouteAction {
    let open: @MainActor (Route) -> Void
    @MainActor func callAsFunction(_ route: Route) { open(route) }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
}

/// What intake has to say, above the stories: the document being read, else one notice at a time (documents waiting for
/// Claude, Reminders access turned off, the Horizon list gone, a document that could not be read: from the store, so it
/// stays until the document reads or is retried), with the sync's status line in a row under it.
struct IntakeStatus: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Environment(\.openURL) private var openURL
    /// Opens Documents, where a failed read can be retried.
    var openDocuments: () -> Void
    /// Opens the app's settings, where the Claude key is (a key Claude refused is fixed there, not by trying again).
    var openSettings: () -> Void
    @State private var confirmDevice: SourceDocument?

    /// Documents that could not be read, in one line: a failure must not vanish into Documents unannounced.
    var readFailure: String? {
        let failed = documents.filter { $0.status == .failed }
        guard let first = failed.first else { return nil }
        guard failed.count == 1 else { return "\(failed.count) documents could not be read. See them in Documents." }
        return "Could not read \(first.displayName): \(first.failure ?? "")" + (first.retryHelps ? " Retry it from Documents." : "")
    }

    /// Documents Claude could not read yet, in one line, with the way out: try again, or let the device read one.
    var waitingForClaude: [SourceDocument] { documents.filter { $0.status == .awaitingCloudParse } }

    /// The wait is over the key or the model (none, one Claude refused, a model the key may not use): trying again cannot
    /// help, Settings can. (Out of credit is the Anthropic Console's to fix, then Try Again.)
    private func keyProblem(_ document: SourceDocument) -> Bool {
        document.failure.map(IngestCoordinator.isKeyOrModelProblem) ?? false   // the drain's own test: a retired model is the key's page's too
    }

    #if os(macOS)
    private static let device = "Mac"   // what the Mac's own pages call it (Documents: "Read on This Mac")
    private static let deviceInText = "Mac"   // a proper noun mid-sentence keeps its capital
    #else
    private static let device = "Device"
    private static let deviceInText = "device"
    #endif

    /// What stands on the page until it is dealt with, one at a time, in this order.
    private enum Notice: Hashable { case waiting, remindersOff, listGone, failed }
    private var notice: Notice? {
        if !waitingForClaude.isEmpty { return .waiting }
        if model.remindersAuthorized == false { return .remindersOff }
        if model.remindersListGone { return .listGone }
        if readFailure != nil { return .failed }
        return nil
    }
    /// What just happened (a duplicate shared, a sync's result, an error): a row of its own under any notice, never hidden by it.
    private var status: String? { model.statusLine ?? model.lastError }

    var body: some View {
        if let reading = model.reading {
            ReadingSection(reading: reading, cancel: { model.cancelReading() })
        } else if notice != nil || status != nil {
            Section {
                if let notice {
                    // One place: a notice giving way to another fades through it, never over it.
                    ZStack(alignment: .topLeading) { noticeView(notice).id(notice).transition(.fadeThrough) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .macRow(top: 16, bottom: 4)
                }
                if let status {
                    Label { Text(status).id(status).transition(.fadeThrough) } icon: {
                        if model.lastError != nil, model.statusLine == nil { Image(systemName: "exclamationmark.triangle") }
                        else if model.busy { ProgressView().controlSize(.small) }   // syncing: something is happening
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .foregroundStyle(model.lastError != nil && model.statusLine == nil ? Design.accentInk : .secondary)
                    .macRow(top: notice == nil ? 16 : 6, bottom: 4)
                }
            }
            .listRowSeparator(.hidden)
            .onPaper()
            .confirmationDialog("Read on this \(Self.deviceInText) instead?", isPresented: Binding(get: { confirmDevice != nil }, set: { if !$0 { confirmDevice = nil } }), titleVisibility: .visible) {
                Button(waitingForClaude.count == 1 ? "Read on This \(Self.device)" : "Read All on This \(Self.device)") {
                    let ids = waitingForClaude.map(\.id)
                    Task { for id in ids { await model.readOnDevice(documentID: id) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The device model is less sure of tables and pictures than Claude, and it takes minutes on a long document. Nothing is sent to Anthropic.")
            }
        }
    }

    @ViewBuilder private func noticeView(_ notice: Notice) -> some View {
        switch notice {
        case .waiting:
            if let first = waitingForClaude.first {
                VStack(alignment: .leading, spacing: 10) {
                    let count = waitingForClaude.count
                    Label(count == 1 ? "\(first.displayName.sentenceStart) is waiting for Claude: \(first.failure ?? "it could not be reached")." : "\(count) documents are waiting for Claude: \(first.failure ?? "it could not be reached").",
                          systemImage: "cloud").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if keyProblem(first) {
                            Button("Check Key…", action: openSettings).buttonStyle(.bordered).controlSize(.small).reachable()
                        } else {
                            Button("Try Again") { Task { await model.drainAndSync() } }.buttonStyle(.bordered).controlSize(.small).reachable()
                        }
                        Button(count == 1 ? "Read on This \(Self.device)…" : "Read Them on This \(Self.device)…") { confirmDevice = first }.buttonStyle(.bordered).controlSize(.small).reachable()
                    }
                }
            }
        case .remindersOff:
            VStack(alignment: .leading, spacing: 8) {
                Label("Reminders access is off, so deadlines stay in Horizon and never reach your lists.", systemImage: "exclamationmark.triangle").foregroundStyle(Design.accentInk)
                #if os(iOS)
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.buttonStyle(.bordered).controlSize(.small).reachable()
                #else
                Button("Open System Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { openURL(url) } }.controlSize(.small)
                #endif
            }
        case .listGone:
            VStack(alignment: .leading, spacing: 8) {
                Label("The Horizon list is gone from Reminders, so deadlines stay in Horizon until it is back.", systemImage: "exclamationmark.triangle").foregroundStyle(Design.accentInk)
                Button("Recreate List") { Task { await model.recreateRemindersList() } }.buttonStyle(.bordered).controlSize(.small).reachable()
            }
        case .failed:
            if let failure = readFailure {
                Button(action: openDocuments) {
                    HStack {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Design.accentInk)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Documents")
            }
        }
    }
}

#if os(iOS)
/// The home screen is Coverage (SPEC §6.1). Intake status and the review queue sit above it; the strip and the day
/// plan are the next tabs. Pulling the page down reads what is queued and syncs with Reminders. Where the display is
/// wide (iPhone Duo open, an iPad) the page a row opens stands beside Coverage, as Mail sets a message beside its list;
/// where it is not, it is pushed over Coverage as ever (`ListBesidePage`).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.course == nil && $0.deletedAt == nil }) private var looseDocuments: [SourceDocument]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var binnedCourses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]
    @State private var addingByHand = false
    @State private var addingCourse = false
    /// The page Coverage has open: beside it, or pushed over it; nil is Coverage alone.
    @State private var selection: Route?
    /// What that page has pushed over itself (an item from a course's page).
    @State private var path: [Route] = []
    @State private var editing: EditMode = .inactive   // owned here and handed to the list, so the toolbar and the rows agree

    private var live: [Obligation] { obligations.filter { $0.deletedAt == nil } }
    /// What sits in Recently Deleted: courses, and documents deleted on their own.
    private var binned: Int { binnedCourses.count + deletedDocuments.filter(\.isBinned).count }
    /// The page a row of Coverage opens, in place of whatever was open, pushed over it or not: once (a second tap while
    /// it is up changes nothing).
    private func open(_ route: Route) {
        guard selection != route || !path.isEmpty else { return }
        path = []
        selection = route
    }
    /// The row's page is the one open beside the list, or under what it opened there (HIG: the selection that leads to
    /// the detail stays marked); never marked where pages are pushed over the list instead.
    private func isOpen(_ route: Route) -> Bool { sizeClass == .regular && selection == route }

    /// A page the app was asked for (`AppModel.destination`: a link, an intent, Spotlight): that page alone over (or
    /// beside) Coverage, whatever was open before.
    private func go(_ destination: AppDestination?) {
        let route: Route?
        switch destination {
        case .page(.coverage): route = nil
        case .page(.review): route = .review
        case .page(.documents): route = .documents
        case .page(.recentlyDeleted): route = .recentlyDeleted
        case .page(.settings): route = .settings
        case .course(let id), .policies(let id):
            guard courses.contains(where: { $0.id == id }) else { model.destination = nil; model.lastError = "That course is no longer in Horizon."; return }
            route = .course(id)
        case .item(let id):   // the item where it lives: its details over its course's page, so Back goes to the course
            model.destination = nil
            guard let item = live.first(where: { $0.id == id }) else { model.lastError = "That item is no longer in Horizon."; return }
            guard let course = item.course, courses.contains(where: { $0.id == course.id }) else { selection = .item(id); path = []; return }
            let page = Route.course(course.id)
            if selection == page { path = [.item(id)]; return }
            // The course's page first, the item over it once that page is up: on a phone the split view pushes the
            // course's page as the selection changes, and an item asked for in the same moment was dropped.
            path = []
            selection = page
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                if selection == page, path.isEmpty { path = [.item(id)] }
            }
            return
        default: return
        }
        model.destination = nil
        selection = route
        path = []
    }
    private var pending: [Obligation] { live.filter { $0.state == .pendingReview && $0.completedAt == nil } }   // done needs no review

    var body: some View {
        ListBesidePage(selection: $selection, path: $path) {
            List(selection: $selection) {
                IntakeStatus(openDocuments: { open(.documents) }, openSettings: { open(.settings) })
                if !pending.isEmpty {
                    Button { open(.review) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(pending.count == 1 ? "One item to review" : "\(pending.count) items to review").font(.system(.title3, design: .serif, weight: .semibold))
                                .contentTransition(.numericText())
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Review")
                    .listRowSeparator(.hidden)
                    .onPaper(selected: isOpen(.review))
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20))
                }
                let unfiled = looseDocuments.filter { doc in doc.status == .parsed && obligations.contains { $0.deletedAt == nil && $0.sourceDocument?.id == doc.id } }   // through the query, not the relationship
                if !unfiled.isEmpty {
                    Button { open(.documents) } label: {
                        HStack {
                            Text(unfiled.count == 1 ? "One document has no course yet" : "\(unfiled.count) documents have no course yet")
                                .font(.system(.title3, design: .serif, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Documents")
                    .listRowSeparator(.hidden)
                    .onPaper(selected: isOpen(.documents))
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
                CoverageList(reading: model.reading != nil, hasUnfiled: !unfiled.isEmpty, open: open, isOpen: isOpen)
                if binned > 0 {
                    RecentlyDeletedRow(count: binned, selected: isOpen(.recentlyDeleted)) { open(.recentlyDeleted) }
                }
            }
            .listStyle(.plain)
            .paper()
            .refreshable { await model.drainAndSync() }   // the page pulled down reads the queue and syncs with Reminders
            // Whatever comes or goes above the stories comes or goes animated: the read, the sync's line, a banner
            // (waiting for Claude, a failed read, Reminders off, the list gone), the review and unfiled lines.
            .animation(.default, value: model.reading != nil)
            .animation(.default, value: model.statusLine)
            .animation(.default, value: documents.map(\.status))
            .animation(.default, value: model.lastError)
            .animation(.default, value: model.remindersAuthorized)
            .animation(.default, value: model.remindersListGone)
            .animation(.default, value: pending.count)
            .animation(.default, value: looseDocuments.count)
            .animation(.default, value: courses.map(\.id))
            .animation(.default, value: binned)
            .onChange(of: model.destination, initial: true) { _, destination in go(destination) }
            .onChange(of: courses.map(\.id)) { _, ids in   // a course deleted while its page is open: the page goes too
                let gone: (Route) -> Bool = { if case .course(let id) = $0 { !ids.contains(id) } else { false } }
                if let selection, gone(selection) { withAnimation { self.selection = nil; path = [] } }
                else if path.contains(where: gone) { withAnimation { path.removeAll(where: gone) } }
            }
            .onChange(of: courses.count, initial: true) { _, count in
                if MainTabs.debugFlag("--open-course"), count > 0, selection == nil, let first = courses.first { open(.course(first.id)) }
            }
            .onAppear {   // once per launch: coming back to Coverage must not push or bin again
                if MainTabs.debugOnce("--open-documents") { open(.documents) }
                if MainTabs.debugOnce("--open-settings") { open(.settings) }
                if MainTabs.debugOnce("--open-recently-deleted") { open(.recentlyDeleted) }
                if MainTabs.debugOnce("--delete-first-course"), let first = courses.first { Task { await model.deleteCourse(first.id) } }   // DEBUG: the bin without a tap
                if MainTabs.debugOnce("--restore-first-course"), let first = binnedCourses.first { Task { await model.restoreCourse(first.id) } }
                if MainTabs.debugOnce("--restore-first-document"), let first = deletedDocuments.first(where: \.isBinned) { Task { await model.restoreDocument(first.id) } }
                #if DEBUG
                // SiriOnDeviceTests' own course, set up and cleared without Siri (which took "add a course" for a search).
                if MainTabs.debugOnce("--seed-siri-test"), !courses.contains(where: { $0.displayName == AppModel.siriTestCourse }) { Task { await model.seedSiriTest() } }
                if MainTabs.debugOnce("--clear-siri-test") { for course in courses where course.displayName == AppModel.siriTestCourse { Task { await model.deleteCourse(course.id) } } }
                #endif
            }
            .navigationTitle("Coverage")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if editing.isEditing {
                    ToolbarItem(placement: .primaryAction) { Button { withAnimation { editing = .inactive } } label: { BarLabel("Done", systemImage: "checkmark") } }
                } else {
                    ToolbarItem(placement: .primaryAction) { ImportMenu() }
                        .visibilityPriority(.high)   // the page's way in: the last to go to the overflow menu on a crowded side bar
                    // The system's overflow menu (HIG: one overflow, the ellipsis kept for it), so iPhone Duo's side bar
                    // never shows two.
                    ToolbarOverflowMenu {
                        Section {
                            Button { open(.documents) } label: { Label("Documents", systemImage: "doc.text") }
                            Button { open(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                        }
                        Section {
                            Button { addingByHand = true } label: { Label("Add Item…", systemImage: "square.and.pencil") }
                            Button { addingCourse = true } label: { Label("Add Course…", systemImage: "book") }
                            if !courses.isEmpty {
                                Button { withAnimation { editing = .active } } label: { Label("Edit Courses", systemImage: "arrow.up.arrow.down") }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editing)
            .onAppear { if MainTabs.debugOnce("--edit-courses") { editing = .active } }
            .sheet(isPresented: $addingByHand) { ObligationEditor(mode: .manual, courses: courses) }
            .sheet(isPresented: $addingCourse) { CourseEditor(course: nil) }
        } aside: {
            PageAside()
        }
    }
}

/// A list beside the page it opens where the display is wide (iPhone Duo open, an iPad), and the page pushed over the
/// list where it is not (a phone, the Duo closed): one `NavigationSplitView`, which collapses to a stack at a compact
/// width and keeps what is open as the device opens and closes (HIG: with room, show another level, as Mail sets a
/// message beside its list, and keep the hierarchy the same; HIG: the system keeps a split view's columns clear of
/// the fold). The list is a `List(selection:)` on `selection`, which is what the split view expands and collapses by,
/// and its rows set it; a page's own links push over it on `path` (`openRoute`).
struct ListBesidePage<Sidebar: View, Aside: View>: View {
    @Binding var selection: Route?
    @Binding var path: [Route]
    let sidebar: Sidebar
    /// The page's place before anything is chosen, where it stands beside the list.
    let aside: Aside

    init(selection: Binding<Route?>, path: Binding<[Route]>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder aside: () -> Aside) {
        _selection = selection; _path = path
        self.sidebar = sidebar(); self.aside = aside()
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 300, ideal: 360)   // no maximum: folded, the system splits the display evenly at the fold
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if let selection { RoutePage(route: selection).id(selection) } else { aside }
                }
                .navigationDestination(for: Route.self) { RoutePage(route: $0) }
            }
            // On the stack, not its first page: the pages pushed onto it take their environment from the stack, and set
            // on the first page it never reached them (a tapped item on a course's page went nowhere).
            .environment(\.openRoute, OpenRouteAction { route in
                guard route != selection, !path.contains(route) else { return }   // pushed once: a second tap while it goes up is ignored
                path.append(route)
            })
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// A route's page: what a stack pushes, and what a split view's detail shows.
struct RoutePage: View {
    let route: Route
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]

    var body: some View {
        switch route {
        case .course(let id):
            if let course = courses.first(where: { $0.id == id }) { CourseView(course: course) }
        case .documents: DocumentsView()
        case .recentlyDeleted: RecentlyDeletedView()
        case .settings: SettingsView()
        case .review: ReviewView()
        case .item(let id): ItemDetail(id: id)
        }
    }
}

/// The page beside a list before anything in it is chosen: the paper alone. The list beside it says what there is to
/// open; a line here telling the user to choose would only say it again. Nothing is chosen for them either: closed, a
/// choice made on their behalf would stand over the list they left (the hierarchy would change with the fold).
struct PageAside: View {
    var body: some View {
        Design.paper.ignoresSafeArea()
            .toolbar(removing: .title)
            .accessibilityHidden(true)
    }
}

#endif

/// The quiet way into Recently Deleted, at the foot of a list, only while something is in it.
struct RecentlyDeletedRow: View {
    let count: Int
    /// Its page is the one open beside the list.
    var selected = false
    var open: () -> Void

    var body: some View {
        Section {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("Recently Deleted")
                    Spacer()
                    Text(String(count)).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recently Deleted, \(count == 1 ? "one thing" : "\(count) things")")
            .accessibilityHint("Opens Recently Deleted")
        }
        .listRowSeparator(.hidden)
        .onPaper(selected: selected)
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .transition(.opacity)
    }
}

/// The document resolving into obligations, as the model streams them (SPEC §9's one earned animation): the creeping
/// bar, its one-line caption, and the items as they are written.
/// A spinner, a progress bar that keeps moving while the model thinks, and a cancel button; the rows the model is
/// streaming sit behind a disclosure, closed by default, and the choice is remembered.
struct ReadingSection: View {
    let reading: AppModel.Reading
    var cancel: () -> Void
    @AppStorage("showReadingDetails") private var remembered = false
    @State private var showDetails = false   // local, so the change animates; the choice is remembered separately
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 4) {
                    Text("Reading \(reading.name)").font(.body.weight(.medium))
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)   // one line; at the accessibility sizes a name cut to a few letters says nothing, so it may run on
                    Spacer(minLength: 8)
                    Button { withAnimation(.snappy) { showDetails.toggle() }; remembered = showDetails } label: {
                        Image(systemName: "chevron.down").font(.body.weight(.semibold)).rotationEffect(.degrees(showDetails ? 180 : 0))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel(showDetails ? "Hide what is being read" : "Show what is being read")
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel reading")
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)   // the two buttons keep to their 44 points
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)   // the model is at work even when the bar is not
                    // One line, always: the widest wording that fits the row, down to the count alone.
                    ViewThatFits(in: .horizontal) {
                        ForEach(progressLines, id: \.self) { Text($0).lineLimit(1) }
                        Text(progressLines[progressLines.count - 1]).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(progressLines[0])
                    Spacer(minLength: 0)
                }
                .padding(.top, -6)   // the buttons' 44 points leave air above; the line belongs to the name
                CreepingProgressBar(real: reading.fraction, mark: reading.nextMark)
                    .id(reading.documentID)   // a new document's bar starts from nothing: the bar never goes backwards, so it must not be the last one's
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)   // the section's own rules are enough; a separator under it doubled the one below
            .macRow(top: 8, bottom: 4)
            if showDetails {
                ForEach(reading.items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).foregroundStyle(item.dateAsWritten == nil ? .secondary : .primary)   // the outline's name, until the item is written
                        Spacer()
                        Text(item.dateAsWritten ?? "…").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.subheadline)
                    .macRow(top: 2, bottom: 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .onPaper()
        .animation(.default, value: reading.items)
        .animation(.snappy, value: showDetails)
        .onAppear { showDetails = remembered }
    }

    /// The part, then where the model is in it, in every wording from the widest down (`ReadingProgress.lines`): with
    /// Claude's outline the stage and its count ("What's due · 8 of 18 · Quiz 8"); without one, the rows so far.
    private var progressLines: [String] {
        let total = reading.chunks + reading.images
        let n = min(max(reading.chunk, 1), max(total, 1))
        let pickedUp = reading.resumed > 0 && n == reading.resumed + 1   // a read that stopped goes on from its checkpoint
        return ReadingProgress.lines(reading.progress, part: n, of: total, pickedUp: pickedUp, found: reading.items.count)
    }
}

/// The reading bar: the real figure, creeping toward the end of the current part while nothing arrives, so it never
/// stands still (`ProgressCreep` is the arithmetic; a timeline draws it every frame while it is on screen).
private struct CreepingProgressBar: View {
    let real: Double
    let mark: Double
    @State private var creep: ProgressCreep?

    var body: some View {
        TimelineView(.animation) { context in   // every frame: the bar's motion is the point of it
            ProgressView(value: creep?.value(at: context.date) ?? real).tint(Design.accent)
        }
        .onAppear { creep = ProgressCreep(real: real, mark: mark, at: .now) }
        .onChange(of: real) { _, value in creep?.update(real: value, mark: mark, at: .now) }
        .onChange(of: mark) { _, value in creep?.update(real: real, mark: value, at: .now) }
        .accessibilityValue("\(Int(real * 100)) percent")
    }
}

/// One obligation, wherever it is listed: its name, its course and date, the points at stake. With `mark` the row
/// leads with a ring to press: done is a filled dot with a check and the words crossed off, the way Now crosses off a
/// block; skipped is a dashed ring and "Skipped" where the share of the grade was, the words left as they were (set
/// aside, not done). The check goes to Reminders too (`AppModel.setCompleted`); pressing a skipped item's ring marks it
/// done.
struct ObligationRow: View {
    let obligation: Obligation
    var showCourse = true
    /// Checks the item off, or back on; nil where a row is not the place for it (the review queue).
    var mark: ((Bool) -> Void)? = nil
    /// A tap opens the item's details: a chevron says so (HIG: a disclosure indicator for a row that drills down).
    var disclosure = false
    @State private var pressed = 0   // the haptic answers the user's press, not a check arriving from Reminders

    private var done: Bool { obligation.completedAt != nil && obligation.skippedAt == nil }
    private var skipped: Bool { obligation.skippedAt != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let mark {
                Button { pressed += 1; mark(!done) } label: {   // HIG: 44 by 44 to hit, though the ring is 20; the extra reaches into the row's margin, so the words stay where they were
                    DoneMark(done: done, skipped: skipped).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -12)
                .sensoryFeedback(.selection, trigger: pressed)
                .accessibilityLabel(done ? "Done" : "Mark done")
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(obligation.title).font(.body.weight(.medium)).strikethrough(done, color: .secondary).lineLimit(3)
                    // The course and the date on one line when both fit; else the date under the course (HIG: stack
                    // rather than squeeze). Neither ever wraps: a date broken across lines reads as two facts.
                    let course = showCourse ? obligation.course?.displayName ?? "" : ""
                    let due = Text(Design.due(obligation.due, hasTime: obligation.dueHasTime)).monospacedDigit()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            if !course.isEmpty { Text(course).lineLimit(1) }
                            due.lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 1) {   // the date alone decides: a long course gives way, it does not cost the weekday
                            if !course.isEmpty { Text(course).lineLimit(1).truncationMode(.middle).frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading) }
                            due.lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 1) {   // the largest sizes: the date without its weekday, whole
                            if !course.isEmpty { Text(course).lineLimit(2) }
                            Text(Design.due(obligation.due, hasTime: obligation.dueHasTime, short: true)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                // A skipped item's share is let go: the word takes the figure's place, so the row keeps its height
                // (a line added above the title made it jump as the row was skipped).
                if skipped { Kicker("Skipped") } else { Design.points(obligation.pointsAtStake).font(.title3.weight(.semibold)) }
                if disclosure { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }
            .opacity(done || skipped ? 0.45 : 1)
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: done)
        .animation(.snappy, value: skipped)
        .contentShape(Rectangle())   // the whole row is the tap, its gaps included
        .accessibilityElement(children: .contain)
        .accessibilityValue(done ? "Done" : skipped ? "Skipped" : "")
        .appEntityIdentifier(EntityIdentifier(for: ItemEntity.self, identifier: obligation.id))   // Siri's "this": the item on the row (WWDC26: view annotations)
    }
}

/// Rows just checked off stay where they are for a moment, crossed off, before a list that leads with what is still
/// to do lets them go (the course page moves them down to Done; "Coming up" drops them), so a slip can be undone
/// where it was made. An uncheck lets go at once.
@MainActor @Observable final class Lingering {
    private(set) var ids: Set<UUID> = []
    /// About to leave: the row fades out first, then the list closes over an empty row, so the row below never slides
    /// up through it at half strength (a crossfade).
    private(set) var leaving: Set<UUID> = []
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    func isLeaving(_ id: UUID) -> Bool { leaving.contains(id) }

    func mark(_ id: UUID, done: Bool) {
        guard done else { ids.remove(id); leaving.remove(id); return }
        ids.insert(id)
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard ids.contains(id) else { return }   // unchecked meanwhile: it stays
            withAnimation(.easeIn(duration: 0.12)) { _ = leaving.insert(id) }
            try? await Task.sleep(for: .seconds(0.12))
            ids.remove(id); leaving.remove(id)
        }
    }
}

/// The mark on an obligation's row: a ring to press, a filled dot with a check once done (Now's done dot, at a row's
/// size), a dashed ring once skipped (open, but not to be done: told from an open ring by its shape, not its colour).
struct DoneMark: View {
    let done: Bool
    var skipped = false
    /// The ring's width: a row's 20 points, or smaller in a Mac table's row.
    var size: CGFloat = 20

    var body: some View {
        let line: CGFloat = size > 16 ? 1.5 : 1.25
        ZStack {
            if done {
                Circle().fill(.primary).frame(width: size, height: size)
                Image(systemName: "checkmark").font(.system(size: size / 2, weight: .bold)).foregroundStyle(Design.paper)
            } else if skipped {
                Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: line, dash: [size / 8, size / 8])).frame(width: size, height: size)
            } else {
                Circle().strokeBorder(.secondary, lineWidth: line).frame(width: size, height: size)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
}

/// An item's two states the user sets, as every place that offers them words them: Mark Done or Mark Not Done, Skip or
/// Undo Skip (the plan's own words for a block).
enum ItemActions {
    static func markTitle(done: Bool) -> String { done ? "Mark Not Done" : "Mark Done" }
    static func markImage(done: Bool) -> String { done ? "arrow.uturn.backward" : "checkmark" }
    static func skipTitle(skipped: Bool) -> String { skipped ? "Undo Skip" : "Skip" }
    static func skipImage(skipped: Bool) -> String { skipped ? "arrow.uturn.backward" : "forward.end" }
}

extension View {
    /// What a row of an obligation offers wherever it is listed: a leading swipe to check it off (or back on) or to skip
    /// it (or take the skip back), a trailing swipe that deletes it (undoable: items do not go to the bin), and the same
    /// in a menu with the editor.
    func obligationActions(done: Bool, skipped: Bool, mark: @escaping (Bool) -> Void, skip: @escaping (Bool) -> Void, edit: @escaping () -> Void,
                           delete: @escaping () -> Void) -> some View {
        self
            .swipeActions(edge: .leading) {
                Button(done ? "Not Done" : "Done", systemImage: ItemActions.markImage(done: done)) { mark(!done) }.tint(Design.accentInk)
                Button(ItemActions.skipTitle(skipped: skipped), systemImage: ItemActions.skipImage(skipped: skipped)) { skip(!skipped) }.tint(.gray)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .contextMenu {
                Button(ItemActions.markTitle(done: done), systemImage: ItemActions.markImage(done: done)) { mark(!done) }
                Button(ItemActions.skipTitle(skipped: skipped), systemImage: ItemActions.skipImage(skipped: skipped)) { skip(!skipped) }
                Button("Edit…", systemImage: "pencil", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
    }
}
