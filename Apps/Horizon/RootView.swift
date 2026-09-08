import SwiftUI
import SwiftData
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
}

/// Pushes a route on the home stack; pages down the stack (Documents, Recently Deleted) use it instead of links.
extension EnvironmentValues {
    @Entry var openRoute: @MainActor (Route) -> Void = { _ in }
}

/// What intake has to say, above the stories: the document being read, Reminders access turned off, a document that
/// could not be read (from the store, so it stays until the document reads or is retried), or the sync's status line.
struct IntakeStatus: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Environment(\.openURL) private var openURL
    /// Opens Documents, where a failed read can be retried.
    var openDocuments: () -> Void

    /// Documents that could not be read, in one line: a failure must not vanish into Documents unannounced.
    var readFailure: String? {
        let failed = documents.filter { $0.status == .failed }
        guard let first = failed.first else { return nil }
        return failed.count == 1 ? "Could not read \(first.filename): \(first.failure ?? "") Retry it from Documents." : "\(failed.count) documents could not be read. Retry them from Documents."
    }

    var body: some View {
        if let reading = model.reading {
            ReadingSection(reading: reading, cancel: { model.cancelReading() })
        } else if model.remindersAuthorized == false {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Reminders access is off, so deadlines stay in Horizon and never reach your lists.", systemImage: "exclamationmark.triangle").foregroundStyle(Design.accent)
                    #if os(iOS)
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.buttonStyle(.bordered).controlSize(.small)
                    #else
                    Button("Open System Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { openURL(url) } }.controlSize(.small)
                    #endif
                }
            }
            .listRowSeparator(.hidden)
            .onPaper()
        } else if let failure = readFailure {
            Section {
                Button(action: openDocuments) {
                    HStack {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Design.accent)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Documents")
            }
            .listRowSeparator(.hidden)
            .onPaper()
        } else if let status = model.statusLine ?? model.lastError {
            Section {
                Label { Text(status) } icon: {
                    if model.lastError != nil { Image(systemName: "exclamationmark.triangle") }
                    else if model.busy { ProgressView().controlSize(.small) }   // syncing: something is happening
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .foregroundStyle(model.lastError == nil ? .secondary : Design.accent)
            }
            .listRowSeparator(.hidden)
            .onPaper()
        }
    }
}

#if os(iOS)
/// The home screen is Coverage (SPEC §6.1). Intake status and the review queue sit above it; the strip and the day
/// plan arrive in M4 and M5. Pulling the page down reads what is queued and syncs with Reminders.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.course == nil && $0.deletedAt == nil }) private var looseDocuments: [SourceDocument]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var binnedCourses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]
    @State private var addingByHand = false
    @State private var addingCourse = false
    @State private var linked: Obligation?
    @State private var path: [Route] = []
    @State private var editing: EditMode = .inactive   // owned here and handed to the list, so the toolbar and the rows agree

    private var live: [Obligation] { obligations.filter { $0.deletedAt == nil } }
    /// What sits in Recently Deleted: courses, and documents deleted on their own.
    private var binned: Int { binnedCourses.count + deletedDocuments.filter(\.isBinned).count }
    /// A page, pushed once: a second push while it is up is ignored.
    private func open(_ route: Route) {
        guard !path.contains(route) else { return }
        path.append(route)
    }
    private var pending: [Obligation] { live.filter { $0.state == .pendingReview } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                IntakeStatus(openDocuments: { open(.documents) })
                if !pending.isEmpty {
                    NavigationLink { ReviewView() } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(pending.count == 1 ? "One item to review" : "\(pending.count) items to review").font(.system(.title3, design: .serif, weight: .semibold))
                            Spacer()
                        }
                    }
                    .listRowSeparator(.hidden)
                    .onPaper()
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20))
                }
                let unfiled = looseDocuments.filter { $0.status == .parsed && !($0.obligations ?? []).filter { $0.deletedAt == nil }.isEmpty }
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
                    .onPaper()
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
                CoverageList(reading: model.reading != nil, hasUnfiled: !unfiled.isEmpty, open: open)
                if binned > 0 {
                    RecentlyDeletedRow(count: binned) { open(.recentlyDeleted) }
                }
            }
            .listStyle(.plain)
            .paper()
            .refreshable { await model.drainAndSync() }   // the page pulled down reads the queue and syncs with Reminders
            .animation(.default, value: model.reading != nil)
            .animation(.default, value: model.statusLine)
            .animation(.default, value: documents.filter { $0.status == .failed }.count)
            .animation(.default, value: model.lastError)
            .animation(.default, value: courses.map(\.id))
            .animation(.default, value: binned)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .course(let id):
                    if let course = courses.first(where: { $0.id == id }) { CourseView(course: course) } else { EmptyView() }
                case .documents: DocumentsView()
                case .recentlyDeleted: RecentlyDeletedView()
                case .settings: SettingsView()
                }
            }
            .environment(\.openRoute, open)
            .onChange(of: courses.count, initial: true) { _, count in
                if MainTabs.debugFlag("--open-course"), count > 0, path.isEmpty, let first = courses.first { open(.course(first.id)) }
            }
            .onAppear {
                if MainTabs.debugFlag("--open-documents") { open(.documents) }
                if MainTabs.debugFlag("--open-settings") { open(.settings) }
                if MainTabs.debugFlag("--open-recently-deleted") { open(.recentlyDeleted) }
                if MainTabs.debugFlag("--delete-first-course"), let first = courses.first { Task { await model.deleteCourse(first.id) } }   // DEBUG: the bin without a tap
                if MainTabs.debugFlag("--restore-first-course"), let first = binnedCourses.first { Task { await model.restoreCourse(first.id) } }
                if MainTabs.debugFlag("--restore-first-document"), let first = deletedDocuments.first(where: \.isBinned) { Task { await model.restoreDocument(first.id) } }
            }
            .navigationTitle("Coverage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                if editing.isEditing {
                    ToolbarItem(placement: .primaryAction) { Button("Done") { withAnimation { editing = .inactive } } }
                } else {
                ToolbarItem(placement: .primaryAction) { ImportMenu() }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { open(.documents) } label: { Label("Documents", systemImage: "doc.text") }
                        Button { open(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                        Divider()
                        Button { addingByHand = true } label: { Label("Add Item…", systemImage: "square.and.pencil") }
                        Button { addingCourse = true } label: { Label("Add Course…", systemImage: "book") }
                        if !courses.isEmpty {
                            Button { withAnimation { editing = .active } } label: { Label("Edit Courses", systemImage: "arrow.up.arrow.down") }
                        }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
                }
            }
            .environment(\.editMode, $editing)
            .onAppear { if MainTabs.debugFlag("--edit-courses") { editing = .active } }
            .sheet(isPresented: $addingByHand) { ObligationEditor(mode: .manual, courses: courses) }
            .sheet(isPresented: $addingCourse) { CourseEditor(course: nil) }
            .sheet(item: $linked) { ObligationEditor(mode: .review($0), courses: courses) }
            .onChange(of: model.linkedObligationID) { _, id in
                guard let id else { return }   // the reset below fires this again with nil; it must not close the sheet
                linked = live.first { $0.id == id }
                model.linkedObligationID = nil
            }
        }
    }
}

#endif

/// The quiet way into Recently Deleted, at the foot of a list, only while something is in it.
struct RecentlyDeletedRow: View {
    let count: Int
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
        .onPaper()
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .transition(.opacity)
    }
}

/// The document resolving into obligations, as the model streams them (SPEC §9's one earned animation, plainly for now).
/// A spinner, a progress bar that keeps moving while the model thinks, and a cancel button; the rows the model is
/// streaming sit behind a disclosure, closed by default, and the choice is remembered.
struct ReadingSection: View {
    let reading: AppModel.Reading
    var cancel: () -> Void
    @AppStorage("showReadingDetails") private var remembered = false
    @State private var showDetails = false   // local, so the change animates; the choice is remembered separately

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 4) {
                    ProgressView().padding(.trailing, 10).accessibilityHidden(true)   // the model is at work even when the bar is not
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading \(reading.filename)").font(.body.weight(.medium))
                        Text(progressLine).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
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
                CreepingProgressBar(real: reading.fraction, mark: reading.nextMark)
            }
            .padding(.vertical, 4)
            if showDetails {
                ForEach(reading.items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                        Spacer()
                        Text(item.dateAsWritten ?? "…").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.subheadline)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .onPaper()
        .animation(.default, value: reading.items)
        .animation(.snappy, value: showDetails)
        .onAppear { showDetails = remembered }
    }

    private var progressLine: String {
        let total = reading.chunks + reading.images
        let part = total > 1 ? "part \(min(max(reading.chunk, 1), total)) of \(total) · " : ""
        return part + "\(reading.items.count) found so far"
    }
}

/// The reading bar: the real figure, creeping toward the end of the current part while nothing arrives, so it never
/// stands still (`ProgressCreep` is the arithmetic; a timeline draws it thirty times a second while it is on screen).
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

struct ObligationRow: View {
    let obligation: Obligation
    var showCourse = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(obligation.title).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if showCourse, let name = obligation.course?.displayName, !name.isEmpty { Text(name).lineLimit(1) }
                    Text(Design.due(obligation.due, hasTime: obligation.dueHasTime)).monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Design.points(obligation.pointsAtStake).font(.title3.weight(.semibold))
        }
        .padding(.vertical, 2)
    }
}
