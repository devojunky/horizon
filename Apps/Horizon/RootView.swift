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

/// Pushes a route on the home stack; pages down the stack (Documents, Recently Deleted) use it instead of links. The closure
/// rides in a struct, the shape of SwiftUI's own actions (OpenURLAction): the environment cannot compare a bare closure.
struct OpenRouteAction {
    let open: @MainActor (Route) -> Void
    @MainActor func callAsFunction(_ route: Route) { open(route) }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
}

/// What intake has to say, above the stories: the document being read, Reminders access turned off, a document that
/// could not be read (from the store, so it stays until the document reads or is retried), or the sync's status line.
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
        guard let failure = document.failure else { return false }
        return failure == "no API key" || failure.contains("rejected") || failure.contains("does not let this key")
    }

    #if os(macOS)
    private static let device = "Mac"   // what the Mac's own pages call it (Documents: "Read on This Mac")
    #else
    private static let device = "Device"
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
            .confirmationDialog("Read on this \(Self.device.lowercased()) instead?", isPresented: Binding(get: { confirmDevice != nil }, set: { if !$0 { confirmDevice = nil } }), titleVisibility: .visible) {
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
    private var pending: [Obligation] { live.filter { $0.state == .pendingReview && $0.completedAt == nil } }   // done needs no review

    var body: some View {
        NavigationStack(path: $path) {
            List {
                IntakeStatus(openDocuments: { open(.documents) }, openSettings: { open(.settings) })
                if !pending.isEmpty {
                    NavigationLink { ReviewView() } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(pending.count == 1 ? "One item to review" : "\(pending.count) items to review").font(.system(.title3, design: .serif, weight: .semibold))
                                .contentTransition(.numericText())
                            Spacer()
                        }
                    }
                    .listRowSeparator(.hidden)
                    .onPaper()
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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .course(let id):
                    if let course = courses.first(where: { $0.id == id }) { CourseView(course: course) } else { EmptyView() }
                case .documents: DocumentsView()
                case .recentlyDeleted: RecentlyDeletedView()
                case .settings: SettingsView()
                }
            }
            .environment(\.openRoute, OpenRouteAction(open: open))
            .onChange(of: courses.map(\.id)) { _, ids in   // a course deleted while its page is open: the page goes too
                let gone = path.contains { if case .course(let id) = $0 { !ids.contains(id) } else { false } }
                if gone { withAnimation { path.removeAll { if case .course(let id) = $0 { !ids.contains(id) } else { false } } } }
            }
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

/// One obligation, wherever it is listed: its name, its course and date, the points at stake. With `mark` the row
/// leads with a ring to press: done is a filled dot with a check and the words crossed off, the way Now crosses off a
/// block. The check goes to Reminders too (`AppModel.setCompleted`).
struct ObligationRow: View {
    let obligation: Obligation
    var showCourse = true
    /// Checks the item off, or back on; nil where a row is not the place for it (the review queue).
    var mark: ((Bool) -> Void)? = nil
    @State private var pressed = 0   // the haptic answers the user's press, not a check arriving from Reminders

    private var done: Bool { obligation.completedAt != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let mark {
                Button { pressed += 1; mark(!done) } label: {   // HIG: 44 by 44 to hit, though the ring is 20; the extra reaches into the row's margin, so the words stay where they were
                    DoneMark(done: done).frame(width: 44, height: 44).contentShape(Rectangle())
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
                        VStack(alignment: .leading, spacing: 1) {
                            if !course.isEmpty { Text(course).lineLimit(1).truncationMode(.middle) }
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
                Design.points(obligation.pointsAtStake).font(.title3.weight(.semibold))
            }
            .opacity(done ? 0.45 : 1)
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: done)
        .accessibilityElement(children: .contain)
        .accessibilityValue(done ? "Done" : "")
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

/// The mark on an obligation's row: a ring to press, a filled dot with a check once done (Now's done dot, at a row's size).
struct DoneMark: View {
    let done: Bool
    /// The ring's width: a row's 20 points, or smaller in a Mac table's row.
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            if done {
                Circle().fill(.primary).frame(width: size, height: size)
                Image(systemName: "checkmark").font(.system(size: size / 2, weight: .bold)).foregroundStyle(Design.paper)
            } else {
                Circle().strokeBorder(.secondary, lineWidth: size > 16 ? 1.5 : 1.25).frame(width: size, height: size)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
}

extension View {
    /// What a row of an obligation offers wherever it is listed: a leading swipe to check it off (or back on), a
    /// trailing swipe to the bin, and the same in a menu with the editor.
    func obligationActions(done: Bool, mark: @escaping (Bool) -> Void, edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        self
            .swipeActions(edge: .leading) {
                Button(done ? "Not Done" : "Done", systemImage: done ? "arrow.uturn.backward" : "checkmark") { mark(!done) }.tint(Design.accentInk)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .contextMenu {
                Button(done ? "Mark Not Done" : "Mark Done", systemImage: done ? "arrow.uturn.backward" : "checkmark") { mark(!done) }
                Button("Edit…", systemImage: "pencil", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
    }
}
