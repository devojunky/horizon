import SwiftUI
import SwiftData
import HorizonCore

/// SPEC §4.3: a small debug view showing token counts, per document.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SourceDocument.queuedAt, order: .reverse) private var documents: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]

    var body: some View {
        List {
            Section {
                LabeledContent("Reminders access", value: model.remindersAuthorized.map { $0 ? "Granted" : "Denied" } ?? "Not asked")
                LabeledContent("Device", value: AppModel.deviceName)
                LabeledContent("Reads documents", value: model.readInCloud ? "In Private Cloud Compute" : "On device")
                if let why = model.cloudUnavailableReason {
                    Text("Private Cloud Compute is unavailable: \(why).").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Kicker("This device") }
            Section {
                ForEach(documents) { doc in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.filename).font(.body.weight(.medium))
                        Text("\(status(doc)) · \(doc.deviceName) · \(doc.queuedAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                        if let course = doc.course {
                            Text(course.displayName).font(.footnote).foregroundStyle(.secondary)
                        } else if doc.status == .parsed, !courses.isEmpty {
                            Menu {
                                ForEach(courses) { course in Button(course.displayName) { Task { await model.assignDocument(doc.id, to: course.id) } } }
                            } label: {
                                Label("File under a course", systemImage: "folder.badge.questionmark").font(.footnote)
                            }
                            .padding(.top, 2)
                        }
                        if doc.status == .parsed {
                            Text("\(doc.inputTokens) in · \(doc.outputTokens) out · \(doc.durationMs / 1000) s · \(doc.route ?? "")").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let failure = doc.failure { Text(failure).font(.footnote).foregroundStyle(Design.accent) }
                        if doc.status == .failed || doc.status == .awaitingCloudParse || doc.status == .cancelled {
                            Button("Retry", systemImage: "arrow.clockwise") { Task { await model.retry(documentID: doc.id) } }.buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
                        }
                        ForEach(doc.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if documents.isEmpty { Text("No documents yet.").foregroundStyle(.secondary) }
            } header: { Kicker("Documents") }
        }
        .listStyle(.plain)
        .listRowSeparatorTint(Design.rule)
        .listRowBackground(Color.clear)
        .paper()
        .navigationTitle("Documents")
    }

    private func status(_ doc: SourceDocument) -> String {
        switch doc.status { case .queued: "Queued"; case .parsed: "Parsed"; case .failed: "Failed"; case .awaitingCloudParse: "Waiting for Private Cloud Compute"; case .cancelled: "Cancelled" }
    }
}
