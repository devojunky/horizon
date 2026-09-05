import SwiftUI
import SwiftData
import HorizonCore
import UniformTypeIdentifiers

/// M2 shell: intake status, the review queue, and what is on file. The three real screens arrive in M3–M5.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var addingByHand = false
    @State private var linked: Obligation?

    private var live: [Obligation] { obligations.filter { $0.deletedAt == nil } }
    private var pending: [Obligation] { live.filter { $0.state == .pendingReview } }
    private var upcoming: [Obligation] {
        live.filter { $0.state != .pendingReview && $0.completedAt == nil && ($0.due ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }   // TBD last
    }

    var body: some View {
        NavigationStack {
            List {
                if let reading = model.reading {
                    ReadingSection(reading: reading)
                } else if let status = model.statusLine ?? model.lastError {
                    Section { Label(status, systemImage: model.lastError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle").foregroundStyle(model.lastError == nil ? .secondary : Design.accent) }
                }
                if !pending.isEmpty {
                    Section {
                        NavigationLink { ReviewView() } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Review").deck()
                                Spacer()
                                Text(pending.count, format: .number).monospacedDigit().foregroundStyle(Design.accent)
                            }
                        }
                    } footer: { Text("Items the parser was not sure about, and dates that moved in a reissued document.") }
                }
                Section("Next up") {
                    if upcoming.isEmpty {
                        ContentUnavailableView("Nothing on file", systemImage: "doc.text.magnifyingglass", description: Text("Share a syllabus, a screenshot of an assignment list, or drop a file into Horizon Inbox on your Mac."))
                    }
                    ForEach(upcoming.prefix(12)) { ObligationRow(obligation: $0) }
                }
                Section("Courses") {
                    ForEach(courses) { course in
                        NavigationLink { CourseView(course: course) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.code.isEmpty ? course.title : course.code).font(.headline)
                                Text(course.title).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink("Documents and usage") { DocumentsView() }
                }
            }
            .navigationTitle("Horizon")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ImportMenu() }
                ToolbarItem(placement: .primaryAction) {   // its own glass button, not an overflow "More" row
                    Menu {
                        Button { Task { await model.drainAndSync() } } label: { Label("Sync with Reminders", systemImage: "arrow.triangle.2.circlepath") }
                        Divider()
                        Button { addingByHand = true } label: { Label("Add by hand…", systemImage: "square.and.pencil") }
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
            .sheet(isPresented: $addingByHand) { ObligationEditor(mode: .manual, courses: courses) }
            .sheet(item: $linked) { ObligationEditor(mode: .review($0), courses: courses) }
            .onChange(of: model.linkedObligationID) { _, id in
                linked = id.flatMap { id in live.first { $0.id == id } }
                model.linkedObligationID = nil
            }
            .overlay(alignment: .bottom) {
                if model.busy { ProgressView().padding(.bottom, 24) }
            }
        }
    }
}

/// The document resolving into obligations, as the model streams them (SPEC §9's one earned animation, plainly for now).
struct ReadingSection: View {
    let reading: AppModel.Reading

    var body: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading \(reading.filename)").font(.body.weight(.medium))
                    Text(progressLine).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(reading.items) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                    Spacer()
                    Text(item.dateAsWritten ?? "…").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.subheadline)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } footer: {
            Text("Dates are checked against the document before anything is written to Reminders.")
        }
        .animation(.default, value: reading.items)
    }

    private var progressLine: String {
        let total = reading.chunks + reading.images
        let part = total > 1 ? "part \(min(max(reading.chunk, 1), total)) of \(total) · " : ""
        return part + "\(reading.items.count) found so far"
    }
}

struct ObligationRow: View {
    let obligation: Obligation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(obligation.title).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let code = obligation.course?.code, !code.isEmpty { Text(code) }
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
