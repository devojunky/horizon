#if os(macOS)
import SwiftUI
import SwiftData
import PDFKit
import HorizonCore

/// Review on a Mac (SPEC §4.1 step 6): the items the reader was unsure of, in a table, each with what its date was
/// read as, why it waits, how sure the reader was and where it came from. Confirm, Edit and Discard act on the
/// selection (the toolbar, the context menu, the Item menu, the Delete key), so a run of right readings goes through
/// in one go; Open Document shows the file an item came from, to check it against.
struct MacReviewPage: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\ReviewRow.due)]
    @State private var editing: Obligation?
    @State private var preview: URL?

    private var pending: [Obligation] { obligations.filter { $0.deletedAt == nil && $0.state == .pendingReview && $0.completedAt == nil } }   // done needs no review
    private var chosen: [Obligation] { pending.filter { selection.contains($0.id) } }
    /// The one selected item's document, when its file is on this Mac.
    private var chosenDocument: SourceDocument? {
        guard chosen.count == 1, let doc = chosen.first?.sourceDocument, model.hasFile(doc) else { return nil }
        return doc
    }

    var body: some View {
        let rows = pending.map(ReviewRow.init).sorted(using: sortOrder)
        Group {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialEmpty(title: "Nothing to review.", deck: "Everything the reader found was sure enough to go straight to Reminders.") { EmptyView() }
                        .padding(.horizontal, Design.margin)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rows.count == 1 ? "One item the reader was unsure of." : "\(rows.count) items the reader was unsure of. Select several to confirm or discard them together.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Design.margin)
                            .padding(.top, 16)
                            .padding(.bottom, 12)
                        table(rows)
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)
                    ReviewDetail(items: chosen, confirm: { confirm(selection) }, edit: { editing = chosen.first }, discard: { discard(selection) },
                                 open: { doc in preview = model.previewFile(for: doc) })
                        .frame(width: 340)
                }
            }
        }
        .background(Design.paper)
        .navigationTitle("Review")
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)   // the page's own, apart from the window's Add Document and Sync
            ToolbarItemGroup(placement: .primaryAction) {   // each is in the Item menu too
                Button { confirm(selection) } label: { Label("Confirm", systemImage: "checkmark") }
                    .help("Confirm the selection as it was read (⌘↩)").disabled(selection.isEmpty)
                Button { editing = chosen.first } label: { Label("Edit", systemImage: "pencil") }
                    .help("Fix the selected item").disabled(chosen.count != 1)
                Button { if let chosenDocument { preview = model.previewFile(for: chosenDocument) } } label: { Label("Open Document", systemImage: "doc.text.magnifyingglass") }
                    .help("Open the document the item was read from").disabled(chosenDocument == nil)
                Button { discard(selection) } label: { Label("Discard", systemImage: "trash") }
                    .help("Discard the selection: it was never an item").disabled(selection.isEmpty)
            }
        }
        .focusedSceneValue(\.reviewActions, selection.isEmpty ? nil : ReviewActions(count: selection.count, confirm: { confirm(selection) }, discard: { discard(selection) }))
        .sheet(item: $editing) { ObligationEditor(mode: .review($0), courses: courses) }
        .quickLookPreview($preview)
        .onAppear {   // the first item is up for review at once, its page beside it
            if selection.isEmpty, let first = rows.first { selection = [first.id] }
        }
    }

    /// The items, lean: what, whose, when, and what it is worth. Why each waits is beside the table, in full.
    private func table(_ rows: [ReviewRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Item", value: \.title) { row in Text(row.title).fontWeight(.medium).lineLimit(1).help(row.title) }
                .width(min: 120, ideal: 200)
            TableColumn("Course", value: \.course) { row in Text(row.course).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 150)
            TableColumn("Due", value: \.due) { row in
                Text(row.hasDue ? Design.due(row.due, hasTime: row.dueHasTime) : "Date TBA").monospacedDigit().lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Weight", value: \.weight) { row in
                Group { if row.weight >= 0 { Design.points(row.weight).fontWeight(.semibold) } else { Text("—").foregroundStyle(.tertiary) } }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 52, ideal: 60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)   // under the page's line, not the toolbar
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Confirm" : "Confirm \(ids.count) Items") { confirm(ids) }
                if ids.count == 1, let id = ids.first { Button("Edit…") { editing = pending.first { $0.id == id } } }
                if ids.count == 1, let id = ids.first, let doc = pending.first(where: { $0.id == id })?.sourceDocument, model.hasFile(doc) {
                    Button("Open Document") { preview = model.previewFile(for: doc) }
                }
                Divider()
                Button(ids.count == 1 ? "Discard" : "Discard \(ids.count) Items", role: .destructive) { discard(ids) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { editing = pending.first { $0.id == id } }
        }
        .onDeleteCommand { discard(selection) }
    }

    private func confirm(_ ids: Set<UUID>) {
        let next = following(ids)
        for id in ids { Task { await model.confirm(id) } }
        selection = next.map { [$0] } ?? []
    }

    private func discard(_ ids: Set<UUID>) {
        let next = following(ids)
        for id in ids { Task { await model.discard(id) } }
        selection = next.map { [$0] } ?? []
    }

    /// The row after the ones just dealt with, in the table's order, so the next item is up at once.
    private func following(_ ids: Set<UUID>) -> UUID? {
        let rows = pending.map(ReviewRow.init).sorted(using: sortOrder)
        guard let last = rows.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        return rows[(last + 1)...].first { !ids.contains($0.id) }?.id ?? rows[..<last].last { !ids.contains($0.id) }?.id
    }
}

/// Beside the table: the item under review, in full. Its name and course, when it is due and what that was read
/// as, why it waits and how sure the reader was, and the page it was read from with the words of its date marked on
/// it, so the reading can be checked without leaving the page; then Confirm, Edit and Discard. With several
/// selected, what can be done to all of them at once.
private struct ReviewDetail: View {
    let items: [Obligation]
    var confirm: () -> Void
    var edit: () -> Void
    var discard: () -> Void
    var open: (SourceDocument) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.count == 1, let item = items.first {
                    single(item)
                } else if items.count > 1 {
                    Text("\(items.count) items selected").deck()
                    Text("Confirm them as they were read, or discard them.").foregroundStyle(.secondary).padding(.top, 6)
                    actions(several: true).padding(.top, 18)
                } else {
                    Text("Select an item to see why it waits and the page it was read from.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.trailing, Design.margin)
            .padding(.vertical, 18)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder private func single(_ item: Obligation) -> some View {
        Kicker(item.course?.displayName ?? "No course")
        Text(item.title).font(.system(.title2, design: .serif, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow { label("Due"); Text(item.due.map { Design.due($0, hasTime: item.dueHasTime) } ?? "Date TBA").monospacedDigit() }
            if let written = item.dateAsWritten, !written.isEmpty { GridRow { label("Read as"); Text("“\(written)”") } }
            if let component = item.componentName, !component.isEmpty { GridRow { label("Counts toward"); Text(component) } }
            if let points = item.pointsAtStake { GridRow { label("Weight"); Design.points(points) } }
        }
        .font(.subheadline)
        .padding(.top, 14)
        RailSection("Why it waits") {
            VStack(alignment: .leading, spacing: 4) {
                if let note = item.changeNote { Text(note).foregroundStyle(Design.accent) }
                ForEach(item.reviewFlags, id: \.self) { Text($0.prefix(1).uppercased() + $0.dropFirst() + ".") }
                Text("The reader was \(Int((item.confidence * 100).rounded()))% sure.").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        if let doc = item.sourceDocument {
            RailSection("Read from") {
                Text([doc.displayName, item.sourcePage.map { "page \($0 + 1)" }].compactMap { $0 }.joined(separator: ", ")).font(.subheadline)   // pages are kept from 0
                SourcePage(document: doc, page: item.sourcePage, mark: item.dateAsWritten)
                    .onTapGesture { if model.hasFile(doc) { open(doc) } }
                    .help("Open the document")
                    .padding(.top, 4)
            }
            .padding(.top, 24)
        }
        actions(several: false).padding(.top, 24)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private func actions(several: Bool) -> some View {
        HStack(spacing: 10) {
            Button(several ? "Confirm All" : "Confirm", action: confirm).buttonStyle(.borderedProminent)
            if !several { Button("Edit…", action: edit) }
            Spacer(minLength: 0)
            Button(several ? "Discard All" : "Discard", role: .destructive, action: discard)
        }
    }
}

/// The page an item was read from: a PDF's page drawn small, with the words its date was read from marked in the
/// accent where the page has them; a picture as it is. Nothing for a document with no pages to draw (Word, text).
private struct SourcePage: View {
    let document: SourceDocument
    let page: Int?
    let mark: String?
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var marks: [CGRect] = []   // where the words are, in fractions of the page, from its top left

    var body: some View {
        VStack(spacing: 0) {   // a container that is there before the page is: a task on an empty group never runs
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { g in
                            ForEach(marks.indices, id: \.self) { i in
                                let r = marks[i]
                                RoundedRectangle(cornerRadius: 2).fill(Design.accent.opacity(0.4))
                                    .frame(width: r.width * g.size.width + 4, height: r.height * g.size.height + 2)
                                    .position(x: r.midX * g.size.width, y: r.midY * g.size.height)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)   // a sheet laid on the paper
                    .accessibilityLabel("The page the item was read from")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
        .task(id: "\(document.sha256)-\(page ?? 0)-\(mark ?? "")") { load() }
    }

    private func load() {
        image = nil; marks = []
        let url = model.storage.url(sha256: document.sha256, extension: document.kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if document.kind.lowercased() == "pdf", let pdf = PDFDocument(url: url), pdf.pageCount > 0,
           let p = pdf.page(at: min(max(page ?? 0, 0), pdf.pageCount - 1)) {   // pages are kept from 0
            let bounds = p.bounds(for: .mediaBox)
            image = p.thumbnail(of: CGSize(width: 680, height: 680 * bounds.height / max(bounds.width, 1)), for: .mediaBox)
            if let mark, !mark.isEmpty {
                marks = pdf.findString(mark, withOptions: [.caseInsensitive]).filter { $0.pages.contains(p) }.map { selection in
                    let r = selection.bounds(for: p)
                    return CGRect(x: (r.minX - bounds.minX) / bounds.width, y: 1 - (r.maxY - bounds.minY) / bounds.height,
                                  width: r.width / bounds.width, height: r.height / bounds.height)
                }
            }
        } else if let picture = NSImage(contentsOf: url) {   // a screenshot, a photo
            image = picture
        }
    }
}

/// What the Item menu can do with the items selected in Review.
struct ReviewActions {
    var count: Int
    var confirm: () -> Void
    var discard: () -> Void
}

/// An item waiting for review, as a table row.
struct ReviewRow: Identifiable {
    let id: UUID
    let title: String
    let course: String
    let due: Date
    let hasDue: Bool
    let dueHasTime: Bool
    let readAs: String
    /// What the guards found, or what a later read changed.
    let why: String
    let changed: Bool
    let confidence: Double
    /// Share of the grade at stake; -1 when unknown.
    let weight: Double
    /// The document and page it was read from.
    let source: String

    @MainActor init(_ o: Obligation) {
        id = o.id
        title = o.title
        course = o.course?.displayName ?? ""
        due = o.due ?? .distantFuture
        hasDue = o.due != nil
        dueHasTime = o.dueHasTime
        readAs = o.dateAsWritten ?? ""
        changed = o.changeNote != nil
        let flags = o.reviewFlags
        why = o.changeNote ?? (flags.isEmpty ? "Low confidence" : (flags.joined(separator: ", ").prefix(1).uppercased() + flags.joined(separator: ", ").dropFirst()))
        confidence = o.confidence
        weight = o.pointsAtStake ?? -1
        source = [o.sourceDocument?.displayName, o.sourcePage.map { "p. \($0 + 1)" }].compactMap { $0 }.joined(separator: " · ")
    }
}
#endif
