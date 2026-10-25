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
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }) private var binnedCourses: [Course]
    @State private var confirmDevice: SourceDocument?
    @State private var preview: URL?

    /// What Recently Deleted holds, counted as Coverage counts it (its courses and documents alike).
    private var binned: Int { deletedDocuments.filter(\.isBinned).count + binnedCourses.count }

    var body: some View {
        List {
            Section {
                ForEach(documents) { doc in
                    VStack(alignment: .leading, spacing: 3) {
                        // The name opens the file in Quick Look, as a document's row on its course's page does.
                        Button { preview = model.previewFile(for: doc) } label: {
                            Text(doc.displayName).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)   // ink, not the tint: a name, as on the course page, that opens what it names
                        .disabled(!model.hasFile(doc))
                        .accessibilityHint("Opens the document")
                        if doc.displayName != doc.filename { Text(doc.filename).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }   // the file it came as
                        Text([status(doc), doc.deviceName, Self.figure(doc.queuedAt.formatted(date: .abbreviated, time: .shortened))].joined(separator: Self.separator)).font(.footnote).foregroundStyle(.secondary)
                        if let course = doc.course {
                            Text(course.displayName).font(.footnote).foregroundStyle(.secondary)
                        } else if doc.status == .parsed, !courses.isEmpty {
                            Menu {
                                fileUnder(doc)
                            } label: {
                                Label("File Under a Course", systemImage: "folder.badge.questionmark").font(.footnote)
                            }
                            .padding(.top, 2)
                        }
                        if doc.status == .parsed {   // each figure kept whole on its line, whatever the text size
                            Text([Self.figure("\(doc.inputTokens) in"), Self.figure("\(doc.outputTokens) out"), Self.figure("\(doc.durationMs / 1000) s"),
                                  doc.route == "onDevice" ? "on the device" : doc.route == "claude" ? "Claude" : doc.route ?? ""].joined(separator: Self.separator))
                                .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let failure = doc.failure { Text(failure).font(.footnote).foregroundStyle(Design.accentInk) }
                        if doc.retryHelps, doc.status == .failed || doc.status == .awaitingCloudParse || doc.status == .cancelled {
                            HStack(spacing: 10) {
                                Button("Retry", systemImage: "arrow.clockwise") { Task { await model.retry(documentID: doc.id) } }.reachable()
                                if doc.status == .awaitingCloudParse, !doc.readOnDevice {
                                    Button("Read on This Device…", systemImage: "iphone") { confirmDevice = doc }.reachable()
                                }
                            }
                            .bordered().controlSize(.small).padding(.top, 2)
                        }
                        ForEach(doc.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .swipeActions(edge: .trailing) {   // straight to Recently Deleted, restorable for 30 days: no dialog
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
                    }
                    .contextMenu {
                        Button("Open", systemImage: "eye") { preview = model.previewFile(for: doc) }.disabled(!model.hasFile(doc))
                        if doc.status == .parsed, doc.course == nil, !courses.isEmpty {
                            Menu("File Under", systemImage: "folder") { fileUnder(doc) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
                    }
                }
                if documents.isEmpty { Text("No documents yet.").foregroundStyle(.secondary) }
            }
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
        .quickLookPreview($preview)
        .onAppear { if MainTabs.debugFlag("--delete-first-document"), let first = documents.first { Task { await model.deleteDocument(first.id) } } }
    }

    @ViewBuilder private func fileUnder(_ doc: SourceDocument) -> some View {
        ForEach(courses) { course in
            Button(course.displayName) { Task { await model.assignDocument(doc.id, to: course.id) } }
        }
    }

    /// Between figures: the dot stays with the figure before it, so a broken line never starts with one.
    static let separator = "\u{00A0}· "

    /// A figure that never breaks inside itself ("12 s", "Oct 5, 2026 at 2:11 AM"): its spaces are non-breaking.
    static func figure(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "\u{00A0}") }

    private func status(_ doc: SourceDocument) -> String {
        switch doc.status {
        case .queued: doc.readSoFar.map { "Queued · \($0.finished) of \($0.total) parts read" } ?? "Queued"   // paused mid-read: it goes on from there
        case .parsed: "Parsed"; case .failed: "Failed"; case .awaitingCloudParse: "Waiting for Claude"; case .cancelled: "Cancelled"
        }
    }
}
