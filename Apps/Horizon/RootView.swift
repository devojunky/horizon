import SwiftUI
import SwiftData
import HorizonCore
import UniformTypeIdentifiers

/// M2 shell: intake status, the review queue, and what is on file. The three real screens arrive in M3–M5.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var importing = false
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
                if let status = model.statusLine ?? model.lastError {
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
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Ingest document", systemImage: "doc.badge.plus") }
                }
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
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, .plainText, UTType("org.openxmlformats.wordprocessingml.document") ?? .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await model.importFiles(urls) } }
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
