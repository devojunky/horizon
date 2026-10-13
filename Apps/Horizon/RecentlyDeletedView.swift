import SwiftUI
import SwiftData
import HorizonCore

/// Recently Deleted: courses and documents wait here for 30 days, restorable, then go for good. A course deleted with
/// its documents is one entry; restoring it brings back exactly what its deletion took (items, their reminders,
/// documents), nothing the user had deleted by hand before. Deleting from here asks first, since it cannot be undone;
/// the only other deletion that asks is the item editor's Delete Item (from an editor the intent is less sure than a
/// swipe), and that one can be undone.
struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Course> { $0.deletedAt != nil && $0.erasedAt == nil }, sort: \Course.deletedAt, order: .reverse) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt != nil }, sort: \SourceDocument.deletedAt, order: .reverse) private var deletedDocuments: [SourceDocument]
    @State private var chosen: BinEntry?     // tapped: restore or erase
    @State private var erasing: BinEntry?    // asked before going for good

    private var documents: [SourceDocument] { deletedDocuments.filter(\.isBinned) }

}

/// One row of the bin: a course with what it holds, or a document on its own.
struct BinEntry: Identifiable, Equatable {
        enum Kind: Equatable { case course, document }
        var id: UUID
        var kind: Kind
        var name: String
        var deletedAt: Date
        var items: Int
        var documents: Int

    init(_ course: Course) {
            id = course.id; kind = .course; name = course.displayName; deletedAt = course.deletedAt ?? .now
            items = course.binnedObligations.count; documents = course.binnedDocuments.count
        }
        init(_ document: SourceDocument) {
            id = document.id; kind = .document; name = document.displayName; deletedAt = document.deletedAt ?? .now
            items = document.binnedObligations.count; documents = 0
        }

        /// What restoring brings back, in words.
        var brings: String {
            var parts: [String] = []
            if items > 0 { parts.append(items == 1 ? "one item" : "\(items) items") }
            if documents > 0 { parts.append(documents == 1 ? "its document" : "its \(documents) documents") }
            switch (kind, parts.isEmpty) {
            case (.course, true): return "Restoring brings the course back."
            case (.course, false): return "Restoring brings back the course with \(parts.joined(separator: " and "))."
            case (.document, true): return "Restoring puts it back on file. Nothing on file came from it."
            case (.document, false): return "Restoring puts it back on file with \(parts.joined(separator: " and ")). Items another document has since updated stay as they are."
            }
        }
}

extension RecentlyDeletedView {
    var body: some View {
        List {
            if courses.isEmpty, documents.isEmpty {
                EditorialEmpty(title: "Nothing deleted lately.", deck: "A course or document you delete waits here for 30 days, and can be put back until then.") {}
                    .listRowSeparator(.hidden)
                    .onPaper()
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            } else {
                Text("Kept for 30 days, then removed for good. Tap one to restore it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                    .onPaper()
            }
            if !courses.isEmpty {
                Section {
                    ForEach(courses) { course in row(BinEntry(course)) }
                } header: { Kicker("Courses") }
                .onPaper()
            }
            if !documents.isEmpty {
                Section {
                    ForEach(documents) { document in row(BinEntry(document)) }
                } header: { Kicker("Documents") }
                .onPaper()
            }
        }
        .listStyle(.plain)
        .paper()
        .animation(.default, value: courses.map(\.id))
        .animation(.default, value: documents.map(\.id))
        .navigationTitle("Recently Deleted")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if MainTabs.debugFlag("--choose-first-deleted") { chosen = courses.first.map(BinEntry.init) ?? documents.first.map(BinEntry.init) }
        }
    }

    private func row(_ entry: BinEntry) -> some View {
        Button { chosen = entry } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.body.weight(.medium))
                    Text(detail(entry)).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(remaining(entry)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Restore or delete for good")
        .swipeActions(edge: .leading) {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(entry) }.tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete Now", systemImage: "trash", role: .destructive) { erasing = entry }
        }
        // On the row, so that where a dialog is drawn as a popover it points at the row it is about.
        .confirmationDialog(entry.name, isPresented: Binding(get: { chosen?.id == entry.id }, set: { if !$0 { chosen = nil } }), titleVisibility: .visible) {
            Button("Restore") { restore(entry) }
            Button("Delete for Good", role: .destructive) { erase(entry) }
        } message: {
            Text(entry.brings + " Deleting it for good cannot be undone.")
        }
        .confirmationDialog("Delete \(entry.name) for good?", isPresented: Binding(get: { erasing?.id == entry.id }, set: { if !$0 { erasing = nil } }), titleVisibility: .visible) {
            Button("Delete for Good", role: .destructive) { erase(entry) }
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// "Deleted 2 hours ago · 12 items · 2 documents"
    private func detail(_ entry: BinEntry) -> String {
        var parts = ["Deleted \(entry.deletedAt.formatted(.relative(presentation: .named)))"]
        if entry.items > 0 { parts.append(entry.items == 1 ? "1 item" : "\(entry.items) items") }
        if entry.documents > 0 { parts.append(entry.documents == 1 ? "1 document" : "\(entry.documents) documents") }
        return parts.joined(separator: " · ")
    }

    /// Days until it goes for good.
    private func remaining(_ entry: BinEntry) -> String {
        let days = max(0, Int((Bin.expiry(of: entry.deletedAt).timeIntervalSinceNow / 86400).rounded(.up)))   // a full 30 right after deleting
        return days == 0 ? "Goes today" : days == 1 ? "1 day left" : "\(days) days left"
    }

    private func restore(_ entry: BinEntry) {
        Task { entry.kind == .course ? await model.restoreCourse(entry.id) : await model.restoreDocument(entry.id) }
    }

    private func erase(_ entry: BinEntry) {
        Task { entry.kind == .course ? await model.eraseCourse(entry.id) : await model.eraseDocument(entry.id) }
    }
}
