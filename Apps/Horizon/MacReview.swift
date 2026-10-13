#if os(macOS)
import SwiftUI
import SwiftData
import PDFKit
import HorizonCore

/// Review on a Mac (SPEC §4.1 step 6): the items the reader was unsure of, in a table, each with what its date was
/// read as, why it waits, how sure the reader was and where it came from. Confirm, Edit and Discard act on the
/// selection (the toolbar, the context menu, the Item menu, the Delete key), so a run of right readings goes through
/// in one go; Open Document shows the file an item came from, to check it against. An item a later document moved
/// offers its other date instead of Discard (discarding it would delete the item itself), as on iOS.
struct MacReviewPage: View {
    @Environment(AppModel.self) private var model
    @Environment(MacNavigation.self) private var nav
    @FocusState private var tableFocused: Bool
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\ReviewRow.due)]
    @State private var editing: Obligation?
    @State private var preview: URL?

    private var pending: [Obligation] { obligations.filter { $0.deletedAt == nil && $0.state == .pendingReview && $0.completedAt == nil } }   // done needs no review
    /// The selected items that are still waiting: an item that left (confirmed in its editor, read again) is no
    /// longer acted on, whatever the table's selection still holds.
    private var chosen: [Obligation] { pending.filter { selection.contains($0.id) } }
    private var chosenIDs: Set<UUID> { Set(chosen.map(\.id)) }
    /// Those of the selection that can be discarded: not one a later document moved (its choice is between two dates).
    private var discardable: Set<UUID> { Set(chosen.filter { $0.otherDate == nil }.map(\.id)) }
    /// The one selected item's document, when its file is on this Mac.
    private var chosenDocument: SourceDocument? {
        guard chosen.count == 1, let doc = chosen.first?.sourceDocument, model.hasFile(doc) else { return nil }
        return doc
    }

    var body: some View {
        let rows = pending.map(ReviewRow.init).sorted(using: sortOrder)
        Group {
            if rows.isEmpty {
                ScrollView {   // in a scroll view, as every empty page is: alone, its words set the window's minimum height
                    EditorialEmpty(title: "Nothing to review.", deck: "Everything the reader found was sure enough to go straight to Reminders.") { EmptyView() }
                        .padding(.horizontal, Design.margin)
                }
                .keyboardStaysInSidebar()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        PageLine(rows.count == 1 ? "One item the reader was unsure of." : "\(rows.count) items the reader was unsure of. Select several to confirm or discard them together.")
                        table(rows)
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)
                    ReviewDetail(items: chosen, confirm: { confirm(chosenIDs) }, useOther: { use($0) }, edit: { editing = chosen.first }, discard: { discard(discardable) },
                                 open: { doc in preview = model.previewFile(for: doc) })
                        .frame(width: 320)
                }
            }
        }
        .background(Design.paper)
        .navigationTitle("Review")
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)   // the page's own, apart from the window's Add Document and Sync
            ToolbarItemGroup(placement: .primaryAction) {   // each is in the Item menu too
                Button { confirm(chosenIDs) } label: { Label("Confirm", systemImage: "checkmark") }
                    .help("Confirm the selection as it was read (⌘↩)").disabled(chosen.isEmpty)
                Button { editing = chosen.first } label: { Label("Edit", systemImage: "pencil") }
                    .help("Fix the selected item (↩)").disabled(chosen.count != 1)
                Button { if let chosenDocument { preview = model.previewFile(for: chosenDocument) } } label: { Label("Open Document", systemImage: "doc.text.magnifyingglass") }
                    .help("Open the document the item was read from").disabled(chosenDocument == nil)
                Button { discard(discardable) } label: { Label("Discard", systemImage: "trash") }
                    .help("Discard the selection: it was never an item (⌘⌫)").disabled(discardable.isEmpty)
            }
        }
        .sheet(item: $editing) { ObligationEditor(mode: .review($0), courses: courses) }
        .quickLookPreview($preview)
        .onAppear {   // the item a link asked for, else the first, is up for review at once, its page beside it
            if !reveal(), selection.isEmpty, let first = rows.first { selection = [first.id] }
        }
        .onChange(of: nav.reveal) { reveal() }
        .onChange(of: rows.map(\.id)) { old, new in   // an item left the queue (its editor confirmed it, a read changed it): the one in its place comes up
            let kept = selection.intersection(new)
            guard kept.count < selection.count else { return }
            if kept.isEmpty, let gone = old.firstIndex(where: { selection.contains($0) }), !new.isEmpty {
                selection = [new[min(gone, new.count - 1)]]
            } else {
                selection = kept
            }
        }
    }

    /// Selects the item a link asked for, when it is waiting here.
    @discardableResult private func reveal() -> Bool {
        guard let id = nav.reveal, pending.contains(where: { $0.id == id }) else { return false }
        nav.reveal = nil
        selection = [id]
        return true
    }

    /// What the Item menu does with the selection, while the table has the keyboard.
    private var actions: ReviewActions? {
        guard !chosen.isEmpty else { return nil }
        let one = chosen.count == 1 ? chosen.first : nil
        let discardable = discardable
        return ReviewActions(
            count: chosen.count,
            confirm: { confirm(chosenIDs) },
            discardCount: discardable.count,
            discard: discardable.isEmpty ? nil : { discard(discardable) },
            edit: one.map { item in { editing = item } },
            openDocument: chosenDocument.map { doc in { preview = model.previewFile(for: doc) } },
            otherDate: one?.otherDate,
            useOtherDate: one?.otherDate == nil ? nil : { use(one!) })
    }

    /// The items, lean: what, whose, when, and what it is worth. Why each waits is beside the table, in full. Ideal
    /// widths that fit the narrowest window with every column in view; a wider one shares out the rest.
    private func table(_ rows: [ReviewRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Item", value: \.title) { row in Text(row.title).fontWeight(.medium).lineLimit(1).help(row.title) }
                .width(min: 100, ideal: 120)
            TableColumn("Course", value: \.course) { row in Text(row.course).foregroundStyle(.secondary).lineLimit(1).help(row.course) }
                .width(min: 60, ideal: 70)
            TableColumn("Due", value: \.due) { row in
                Text(row.hasDue ? Design.due(row.due, hasTime: row.dueHasTime) : "Date TBA").monospacedDigit().lineLimit(1)
            }
            .width(min: 80, ideal: 90)
            TableColumn("Weight", value: \.weight) { row in
                Group { if row.weight >= 0 { Design.points(row.weight).fontWeight(.semibold) } else { Text("—").foregroundStyle(.tertiary) } }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 46, ideal: 50, max: 80)
            .alignment(.trailing)
        }
        .paperTable()
        .takesKeyboard($tableFocused, hasRows: true)   // ↑ and ↓ go through the items, ⌘↩ and ⌘⌫ act on them, ↩ edits: only Use <date> needs the pointer or the menu
        .animation(.default, value: rows.map(\.id))   // a confirmed or discarded row leaves as a Mac table's rows do, the rest closing up
        .contextMenu(forSelectionType: UUID.self) { ids in
            let items = pending.filter { ids.contains($0.id) }
            if !items.isEmpty {
                Button(items.count == 1 ? "Confirm" : "Confirm \(items.count) Items") { confirm(Set(items.map(\.id))) }
                if items.count == 1, let item = items.first {
                    if let other = item.otherDate { Button("Use \(other.formatted(.dateTime.month(.abbreviated).day()))") { use(item) } }
                    Button("Edit…") { editing = item }
                    if let doc = item.sourceDocument, model.hasFile(doc) { Button("Open Document") { preview = model.previewFile(for: doc) } }
                }
                let gone = Set(items.filter { $0.otherDate == nil }.map(\.id))
                if !gone.isEmpty {
                    Divider()
                    Button(gone.count == 1 ? "Discard" : "Discard \(gone.count) Items", role: .destructive) { discard(gone) }
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { editing = pending.first { $0.id == id } }
        }
        .onDeleteCommand { discard(discardable) }
        .focusedValue(\.reviewActions, actions)   // the table's; it stays published under a sheet, so the commands check `keyboardIsElsewhere` before acting
    }

    private func confirm(_ ids: Set<UUID>) {
        let next = following(ids)
        for id in ids { Task { await model.confirm(id) } }
        selection = next.map { [$0] } ?? []
    }

    /// Confirms an item a later document moved with its other date (the earlier one, or the document's beside the user's).
    private func use(_ item: Obligation) {
        guard let date = item.otherDate else { return }
        let id = item.id, next = following([id])
        Task { await model.confirm(id, edits: ObligationEdits(due: .some(date))) }
        selection = next.map { [$0] } ?? []
    }

    private func discard(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let next = following(ids)
        Task { await model.discard(Array(ids)) }   // one undo for them all
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
    /// Confirms the one item with the other date a later document gave it.
    var useOther: (Obligation) -> Void
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
                    let moved = items.filter { $0.otherDate != nil }.count
                    Text("\(items.count) items selected").deck()
                    Text(moved == 0 ? "Confirm them as they were read, or discard them."
                         : moved == items.count ? "A later document moved each one's date. Confirm them as they are, or choose one at a time."
                         : "Confirm them as they were read, or discard them. Discard leaves out the \(moved == 1 ? "one" : "\(moved)") a later document moved.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    actions(several: true, other: nil, discards: moved < items.count).padding(.top, 18)
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
                if let note = item.changeNote { Text(note).foregroundStyle(Design.accentInk) }
                ForEach(item.reviewFlags, id: \.self) { Text($0.prefix(1).uppercased() + $0.dropFirst() + ".") }
                Text("The reader was \(Int((item.confidence * 100).rounded()))% sure.").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        if let doc = item.sourceDocument {
            RailSection("Read from") {
                SourcePage(document: doc, from: item.sourcePage, words: [item.dateAsWritten, item.title].compactMap { $0 }.filter { !$0.isEmpty })
                    .onTapGesture { if model.hasFile(doc) { open(doc) } }
                    .help("Open the document")
            }
            .padding(.top, 24)
        }
        actions(several: false, other: item.otherDate.map { _ in item }, discards: item.otherDate == nil).padding(.top, 24)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    /// Each with the keys that do it from the table (the Item menu's, and Return for the table's own Edit), so the
    /// keyboard is learned where the buttons are.
    /// An item a later document moved (`other`) offers its other date where Discard would be: discarding it would
    /// delete the item, and the choice is between the two dates.
    private func actions(several: Bool, other: Obligation?, discards: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: confirm) { ShortcutLabel(several ? "Confirm All" : "Confirm", keys: "⌘↩") }.buttonStyle(.borderedProminent)
            if let other, let date = other.otherDate {
                Button { useOther(other) } label: { Text("Use \(date.formatted(.dateTime.month(.abbreviated).day()))") }
                    .help("Confirm it due \(date.formatted(.dateTime.weekday(.wide).month(.wide).day())) instead")
            }
            if !several { Button(action: edit) { ShortcutLabel("Edit…", keys: "↩") } }
            Spacer(minLength: 0)
            if discards { Button(role: .destructive, action: discard) { ShortcutLabel(several ? "Discard All" : "Discard", keys: "⌘⌫") } }
        }
    }
}

/// A button's title with its keyboard shortcut after it, set as the menu bar sets it and a step quieter than the
/// title. VoiceOver hears the title alone: the menu bar already tells it the shortcut.
private struct ShortcutLabel: View {
    let title: String
    let keys: String
    init(_ title: String, keys: String) { self.title = title; self.keys = keys }
    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Text(keys).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// The page an item was read from, named and drawn small: for a PDF, the page where its date is written, found by
/// its words (the part a read began with is all `sourcePage` knows, and Claude reads a whole PDF as one part), those
/// words marked in the accent; a picture as it is. When the words are nowhere in a PDF (a scan with no text), the
/// page the part began with is drawn under the document's name alone, without claiming a page number. For a document
/// with no pages (Word, text), or one whose file is on another device, only its name is drawn. The file is opened and
/// searched off the main thread.
private struct SourcePage: View {
    let document: SourceDocument
    /// Where the part it was read from began, from 0.
    let from: Int?
    /// What to look for on the pages, most telling first: the date's wording, then the item's name.
    let words: [String]
    @Environment(AppModel.self) private var model
    @State private var found: Found?

    struct Found: @unchecked Sendable {   // an image made off the main thread, handed over once and never changed
        var image: NSImage
        /// The page shown, from 0, when the words were found there.
        var page: Int?
        /// Where the words are on it, in fractions of the page from its top left.
        var marks: [CGRect]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {   // a container that is there before the page is: a task on an empty group never runs
            Text([document.displayName, found?.page.map { "page \($0 + 1)" }].compactMap { $0 }.joined(separator: ", ")).font(.subheadline)
            if let found {
                Image(nsImage: found.image).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { g in
                            ForEach(found.marks.indices, id: \.self) { i in
                                let r = found.marks[i]
                                RoundedRectangle(cornerRadius: 2).fill(Design.accent.opacity(0.4))
                                    .frame(width: r.width * g.size.width + 4, height: r.height * g.size.height + 2)
                                    .position(x: r.midX * g.size.width, y: r.midY * g.size.height)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)   // a sheet laid on the paper
                    .accessibilityLabel(found.page.map { "Page \($0 + 1) of the document" } ?? "The document")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(document.sha256)-\(from ?? 0)-\(words.joined(separator: "|"))") {
            found = nil
            let url = model.storage.url(sha256: document.sha256, extension: document.kind)
            let isPDF = document.kind.lowercased() == "pdf", from = from ?? 0, words = words
            found = await Task.detached(priority: .userInitiated) { Self.load(url, isPDF: isPDF, from: from, words: words) }.value
        }
    }

    nonisolated private static func load(_ url: URL, isPDF: Bool, from: Int, words: [String]) -> Found? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard isPDF else { return NSImage(contentsOf: url).map { Found(image: $0, page: nil, marks: []) } }   // a screenshot, a photo
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { return nil }
        // The first of the words the document has, on the first page at or after where the part began (else anywhere).
        var hit: (page: PDFPage, selections: [PDFSelection])?
        for word in words {
            let selections = pdf.findString(word, withOptions: [.caseInsensitive])
            guard !selections.isEmpty else { continue }
            let pages = selections.compactMap(\.pages.first)
            let chosen = pages.first { pdf.index(for: $0) >= from } ?? pages[0]
            hit = (chosen, selections.filter { $0.pages.contains(chosen) })
            break
        }
        let page = hit?.page ?? pdf.page(at: min(max(from, 0), pdf.pageCount - 1))
        guard let page else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: CGSize(width: 680, height: 680 * bounds.height / max(bounds.width, 1)), for: .mediaBox)
        // Marks only on an upright page: a rotated one draws turned, and its words' bounds would not line up.
        let marks = page.rotation != 0 ? [] : (hit?.selections ?? []).map { selection -> CGRect in
            let r = selection.bounds(for: page)
            return CGRect(x: (r.minX - bounds.minX) / bounds.width, y: 1 - (r.maxY - bounds.minY) / bounds.height,
                          width: r.width / bounds.width, height: r.height / bounds.height)
        }
        return Found(image: image, page: hit.map { _ in pdf.index(for: page) }, marks: marks)
    }
}

/// What the Item menu can do with the items selected in Review.
struct ReviewActions {
    var count: Int
    var confirm: () -> Void
    /// How many of the selection Discard would take: not those a later document moved.
    var discardCount: Int
    var discard: (() -> Void)?
    /// The one selected item's editor.
    var edit: (() -> Void)?
    /// The one selected item's document in Quick Look, when its file is on this Mac.
    var openDocument: (() -> Void)?
    /// The other date of the one selected item a later document moved, and confirming it with that date.
    var otherDate: Date?
    var useOtherDate: (() -> Void)?
}

/// An item waiting for review, as a table row: what it sorts by.
struct ReviewRow: Identifiable {
    let id: UUID
    let title: String
    let course: String
    let due: Date
    let hasDue: Bool
    let dueHasTime: Bool
    /// Share of the grade at stake; -1 when unknown.
    let weight: Double

    @MainActor init(_ o: Obligation) {
        id = o.id
        title = o.title
        course = o.course?.displayName ?? ""
        due = o.due ?? .distantFuture
        hasDue = o.due != nil
        dueHasTime = o.dueHasTime
        weight = o.pointsAtStake ?? -1
    }
}
#endif
