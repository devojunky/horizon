import SwiftUI
import SwiftData
import HorizonCore

/// SPEC §4.3: a small debug view showing token counts, per document. Deleting sends a document to Recently Deleted;
/// pulling the page down reads what is queued.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }, sort: \SourceDocument.queuedAt, order: .reverse) private var documents: [SourceDocument]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }) private var deletedDocuments: [SourceDocument]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var confirmDevice: SourceDocument?

    private var binned: Int { deletedDocuments.filter(\.isBinned).count }

    var body: some View {
        List {
            Section {
                ForEach(documents) { doc in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.displayName).font(.body.weight(.medium))
                        if doc.displayName != doc.filename { Text(doc.filename).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }   // the file it came as
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
                            HStack(spacing: 10) {
                                Button("Retry", systemImage: "arrow.clockwise") { Task { await model.retry(documentID: doc.id) } }
                                if doc.status == .awaitingCloudParse, !doc.readOnDevice {
                                    Button("Read on This Device…", systemImage: "iphone") { confirmDevice = doc }
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
                        }
                        ForEach(doc.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .swipeActions(edge: .trailing) {   // straight to Recently Deleted, restorable for 30 days: no dialog
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
                    }
                }
                if documents.isEmpty { Text("No documents yet.").foregroundStyle(.secondary) }
            } header: { Kicker("Documents") }
            .onPaper()
            if binned > 0 {
                RecentlyDeletedRow(count: binned) { open(.recentlyDeleted) }
            }
        }
        .listStyle(.plain)
        .paper()
        .refreshable { await model.drainAndSync() }
        .confirmationDialog("Read on this device instead?", isPresented: Binding(get: { confirmDevice != nil }, set: { if !$0 { confirmDevice = nil } }), titleVisibility: .visible, presenting: confirmDevice) { doc in
            Button("Read on This Device") { Task { await model.readOnDevice(documentID: doc.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The device model is less sure of tables and pictures than Claude, and it takes minutes on a long document. Nothing is sent to Anthropic.")
        }
        .animation(.default, value: documents.map(\.id))
        .animation(.default, value: documents.map(\.status))   // a document read, failed or waiting: its row's lines change animated, not in one frame
        .animation(.default, value: binned)
        .navigationTitle("Documents")
        .onAppear { if MainTabs.debugFlag("--delete-first-document"), let first = documents.first { Task { await model.deleteDocument(first.id) } } }
    }

    private func status(_ doc: SourceDocument) -> String {
        switch doc.status {
        case .queued: doc.readSoFar.map { "Queued · \($0.finished) of \($0.total) parts read" } ?? "Queued"   // paused mid-read: it goes on from there
        case .parsed: "Parsed"; case .failed: "Failed"; case .awaitingCloudParse: "Waiting for Claude"; case .cancelled: "Cancelled"
        }
    }
}
