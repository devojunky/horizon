import SwiftUI
import SwiftData
import HorizonCore
#if canImport(UIKit)
import UIKit
#endif

/// The home screen is Coverage (SPEC §6.1). Intake status and the review queue sit above it; the strip and the day
/// plan arrive in M4 and M5.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.course == nil }) private var looseDocuments: [SourceDocument]
    @Query private var documents: [SourceDocument]
    @State private var addingByHand = false
    @State private var addingCourse = false
    @State private var linked: Obligation?
    @State private var path = NavigationPath()
    @State private var editing: EditMode = .inactive   // owned here and handed to the list, so the toolbar and the rows agree
    @Environment(\.openURL) private var openURL

    private var live: [Obligation] { obligations.filter { $0.deletedAt == nil } }
    /// Documents that could not be read, in one line: a failure must not vanish into Documents unannounced.
    private var readFailure: String? {
        let failed = documents.filter { $0.status == .failed }
        guard let first = failed.first else { return nil }
        return failed.count == 1 ? "Could not read \(first.filename): \(first.failure ?? "") Retry it from Documents." : "\(failed.count) documents could not be read. Retry them from Documents."
    }
    private var pending: [Obligation] { live.filter { $0.state == .pendingReview } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let reading = model.reading {
                    ReadingSection(reading: reading, cancel: { model.cancelReading() })
                } else if model.remindersAuthorized == false {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Reminders access is off, so deadlines stay in Horizon and never reach your lists.", systemImage: "exclamationmark.triangle").foregroundStyle(Design.accent)
                            #if os(iOS)
                            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.buttonStyle(.bordered).controlSize(.small)
                            #endif
                        }
                    }
                    .listRowSeparator(.hidden)
                    .onPaper()
                } else if let failure = readFailure {   // from the store, so it stays until the document reads or is retried
                    Section {
                        NavigationLink(value: "documents") {
                            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Design.accent)
                        }
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
                    NavigationLink { DocumentsView() } label: {
                        Text(unfiled.count == 1 ? "One document has no course yet" : "\(unfiled.count) documents have no course yet")
                            .font(.system(.title3, design: .serif, weight: .semibold))
                    }
                    .listRowSeparator(.hidden)
                    .onPaper()
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
                CoverageList(reading: model.reading != nil, hasUnfiled: !unfiled.isEmpty)
            }
            .listStyle(.plain)
            .paper()
            .animation(.default, value: model.reading != nil)
            .animation(.default, value: model.statusLine)
            .animation(.default, value: readFailure)
            .animation(.default, value: model.lastError)
            .navigationDestination(for: Course.self) { CourseView(course: $0) }
            .navigationDestination(for: String.self) { _ in DocumentsView() }   // "documents", for the debug flag
            .onChange(of: courses.count, initial: true) { _, count in
                if MainTabs.debugFlag("--open-course"), count > 0, path.isEmpty, let first = courses.first { path.append(first) }
            }
            .onAppear { if MainTabs.debugFlag("--open-documents"), path.isEmpty { path.append("documents") } }
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
                        Button { Task { await model.drainAndSync() } } label: { Label("Sync with Reminders", systemImage: "arrow.triangle.2.circlepath") }
                        NavigationLink { DocumentsView() } label: { Label("Documents", systemImage: "doc.text") }
                        Toggle(isOn: Binding(get: { model.readInCloud }, set: { model.readInCloud = $0 })) {
                            Label("Read in Private Cloud Compute", systemImage: "cloud")
                        }
                        .disabled(model.cloudUnavailableReason != nil)
                        Divider()
                        Button { addingByHand = true } label: { Label("Add Item…", systemImage: "square.and.pencil") }
                        Button { addingCourse = true } label: { Label("Add Course…", systemImage: "book") }
                        if courses.count > 1 || !courses.isEmpty {
                            Button { withAnimation { editing = .active } } label: { Label("Edit Courses", systemImage: "arrow.up.arrow.down") }
                        }
                        #if DEBUG
                        Divider()
                        Button {
                            if let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") {
                                Task { await model.importFiles([sample]) }
                            }
                        } label: { Label("Ingest sample syllabus", systemImage: "ladybug") }
                        #endif
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

/// The document resolving into obligations, as the model streams them (SPEC §9's one earned animation, plainly for now).
/// A spinner, a progress bar that keeps moving while the model thinks, and a cancel button; the rows the model is
/// streaming sit behind a disclosure, closed by default, and the choice is remembered.
struct ReadingSection: View {
    let reading: AppModel.Reading
    var cancel: () -> Void
    @AppStorage("showReadingDetails") private var showDetails = false

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
                    Button { withAnimation { showDetails.toggle() } } label: {
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
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
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
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
