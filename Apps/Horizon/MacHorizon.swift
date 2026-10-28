#if os(macOS)
import SwiftUI
import SwiftData
import AppIntents
import HorizonCore

/// Horizon on a Mac (SPEC §6.2, set for a window and a pointer). A phone needs a bar a finger can hit, 44 points, so
/// there the term comes in two levels, weeks to read and days to scroll through. A pointer can point at a day a few
/// points wide, so here there is one: the whole term at the resolution of a day, fitted to the window, and the chart
/// is a single control over its plot (HIG: a chart's hit region is its plot; the pointer scrubs). The day under the
/// pointer reads in the header; a click chooses it, a drag chooses any run of days, a click on a week's date in the
/// axis chooses the week; the arrow keys move the choice and Shift stretches it; Escape lets it go. Under the chart,
/// the items themselves in a table: what was chosen, else what is coming up, sortable, a row's ring checks it off, a
/// double-click edits, Delete deletes, and the items selected there are marked on the chart.
struct MacHorizonPage: View {
    @Environment(AppModel.self) private var model
    @Environment(MacNavigation.self) private var nav
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.due != nil }, sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var filter: Band.Kind = .all      // the course the page is narrowed to; everything until the user (or an intent) says otherwise, and again whenever the page is left
    @State private var chosen: DateInterval?         // a day, a week or any run of days
    @State private var pointer = ChartPointer()      // the day under the pointer: read by the header and the chart, never by the page
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\ItemRow.due)]
    @State private var editing: Obligation?
    @State private var lingering = Lingering()       // just checked off under "Coming up": crossed off for a moment before it leaves
    private let calendar = Calendar.current

    /// The chosen run of days' items, else what is coming up from today (what is done drops out once its moment is over).
    private func listed(_ data: StripData) -> [Obligation] {
        let ids: Set<UUID>
        if let chosen {
            ids = Set(data.items.filter { chosen.holds($0.due) }.map(\.id))
        } else {
            let today = calendar.startOfDay(for: Date())
            ids = Set(data.items.filter { $0.due >= today && (!$0.completed || lingering.contains($0.id)) }.map(\.id))
        }
        return obligations.filter { ids.contains($0.id) }
    }

    var body: some View {
        let data = StripData(obligations: obligations, courses: courses, level: .days, filter: filter, calendar: calendar)
        let listed = listed(data)
        let rows = listed.map { ItemRow($0, lingering: lingering) }.sorted(using: sortOrder)
        let marked = Set(listed.filter { selection.contains($0.id) }.compactMap { $0.due.map { calendar.startOfDay(for: $0) } })
        Group {
            if data.items.isEmpty {
                ScrollView {
                    EditorialEmpty(title: "Nothing on the horizon.", deck: "Add a syllabus or a schedule, or drop one on this window, and its term appears here.") {
                        ImportMenu().prominent()
                    }
                    .padding(.horizontal, Design.margin)
                }
                .keyboardStaysInSidebar()   // no rows to move through: the arrows keep moving the sidebar
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ChartHeader(data: data, chosen: chosen, pointer: pointer, calendar: calendar)
                        .padding(.horizontal, Design.margin)
                        .padding(.top, 14)
                        .padding(.bottom, 14)
                    TermChart(data: data, chosen: $chosen, pointer: pointer, marked: marked, calendar: calendar)
                        .padding(.horizontal, Design.margin)
                    listHead(data)
                        .padding(.horizontal, Design.margin)
                        .padding(.top, 22)
                        .padding(.bottom, 6)
                    ItemTable(rows: rows, selection: $selection, sortOrder: $sortOrder, showsCourse: data.narrowedTo == nil,
                              mark: mark, skip: skip, edit: { id in editing = obligations.first { $0.id == id } },
                              delete: { ids in Task { await model.discard(Array(ids)) }; selection.subtract(ids) })   // one undo for them all
                        .animation(.default, value: rows.map(\.id))   // the rows come and go; the words above them change at once
                }
            }
        }
        .background(Design.paper)
        .navigationTitle("Horizon")
        .toolbar {
            if data.choices.count > 1 {   // one course is its own filter
                ToolbarSpacer(.fixed, placement: .primaryAction)   // the page's own control, apart from the window's
                ToolbarItem(placement: .primaryAction) {
                    Picker("Course", selection: Binding(get: { data.narrowedTo?.kind ?? .all }, set: { filter = $0 })) {   // a pop-up button that says what is showing
                        Text("All Courses").tag(Band.Kind.all)
                        Divider()
                        ForEach(data.choices) { Text($0.name).tag($0.kind) }
                    }
                    .pickerStyle(.menu)
                    .help("Show one course, or all of them")
                }
            }
        }
        .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        .onAppear {
            if MainTabs.debugOnce("--filter-second-course"), data.choices.count > 1 { filter = data.choices[1].kind }   // DEBUG: narrowed to a course without a click
            if MainTabs.debugOnce("--scrub-week"), let heavy = data.collisions.first?.day ?? data.items.first(where: { $0.due >= Date() })?.due {   // DEBUG: a week chosen without a click
                chosen = calendar.dateInterval(of: .weekOfYear, for: heavy)
            }
        }
        .onChange(of: nav.horizonRequest, initial: true) { _, request in   // asked for from outside: the course, and the day chosen
            guard let request else { return }
            nav.horizonRequest = nil
            let kind: Band.Kind = request.course.map { .course($0) } ?? .all
            filter = data.choices.contains { $0.kind == kind } ? kind : .all
            if let day = request.day { chosen = calendar.dateInterval(of: .day, for: day) }
        }
    }

    /// The table's kicker: what it lists, and the way back to what is coming up.
    private func listHead(_ data: StripData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let chosen {
                Kicker(ChartHeader.name(of: chosen, calendar: calendar, style: .short))
                Spacer()
                Button("Show Coming Up") { self.chosen = nil }
                    .bordered()
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("List what is coming up instead (Escape)")
            } else {
                Kicker(data.narrowedTo.map { "Coming up · \($0.name)" } ?? "Coming up").lineLimit(1)
                Spacer()
            }
        }
    }

    private func mark(_ id: UUID, _ done: Bool) {
        lingering.mark(id, done: done)
        Task { await model.setCompleted(id, done) }
    }

    /// A skip lingers under "Coming up" as a check does, then the row leaves.
    private func skip(_ id: UUID, _ skipped: Bool) {
        lingering.mark(id, done: skipped)
        Task { await model.setSkipped(id, skipped) }
    }
}

/// The day under the pointer. Only the chart and its header read it, so a pointer moving over the chart redraws
/// those two and nothing else.
@MainActor @Observable final class ChartPointer {
    var day: DateInterval?
}

/// An obligation as a table row, with what it sorts by.
struct ItemRow: Identifiable {
    let id: UUID
    let title: String
    let course: String
    /// When it is due; an item with no date sorts after every dated one.
    let due: Date
    let hasDue: Bool
    let dueHasTime: Bool
    let component: String
    /// Share of the grade at stake; -1 when unknown, so it sorts under every known weight.
    let weight: Double
    /// Checked off as done (not skipped).
    let done: Bool
    /// Set aside, not done: closed, with a dashed ring.
    let skipped: Bool
    /// Just checked off, still listed for a moment.
    let lingering: Bool
    /// The document it was read from, for Open Document.
    let document: SourceDocument?

    @MainActor init(_ o: Obligation, lingering: Lingering) {
        id = o.id
        title = o.title
        course = o.course?.displayName ?? ""
        due = o.due ?? .distantFuture
        hasDue = o.due != nil
        dueHasTime = o.dueHasTime
        component = o.componentName ?? ""
        weight = o.pointsAtStake ?? -1
        done = o.completedAt != nil && o.skippedAt == nil
        skipped = o.skippedAt != nil
        self.lingering = lingering.contains(o.id)
        document = o.sourceDocument
    }
}

/// Items in a table: a ring to check one off (dashed once it is skipped), its name, course, due date, the grade row it
/// counts toward and its weight. Sortable by every column but the ring; a double-click edits, Delete deletes the
/// selection, the context menu does those, skips, and opens the document an item was read from, and one selected item
/// is what the Item menu acts on while the table has the keyboard. Ideal widths fit the narrowest window with every
/// column in view (a table lays its columns out at their ideal widths and scrolls sideways rather than shrink them); a
/// wider one shares out the rest.
struct ItemTable: View {
    let rows: [ItemRow]
    @Binding var selection: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<ItemRow>]
    /// False when every row is one course's (the page is narrowed, or it is the course's own page).
    var showsCourse = true
    /// Beside a column of its own (a course's page, its rail): narrower ideal widths.
    var compact = false
    /// What an empty table says in its place.
    var emptyText = "Nothing due."
    /// A row to bring into view (a link asked for it; the page selects it).
    var reveal: UUID? = nil
    var mark: (UUID, Bool) -> Void
    var skip: (UUID, Bool) -> Void
    var edit: (UUID) -> Void
    var delete: (Set<UUID>) -> Void
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var preview: URL?   // the document an item was read from, in Quick Look

    var body: some View {
        ScrollViewReader { proxy in
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { row in
                    Button { mark(row.id, !row.done) } label: { DoneMark(done: row.done, skipped: row.skipped, size: 15).frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help(row.done ? "Mark not done" : row.skipped ? "Skipped: mark done" : "Mark done")
                        .accessibilityLabel(row.done ? "Done" : "Mark done")
                        .accessibilityValue(row.skipped ? "Skipped" : "")
                }
                .width(24)
                TableColumn("Item", value: \.title) { row in
                    Text(row.title).fontWeight(.medium).strikethrough(row.done, color: .secondary).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(row.skipped ? AnyShapeStyle(.rowSecondary) : AnyShapeStyle(.primary))   // set aside: quieter, not crossed off
                        .help(row.skipped ? "\(row.title) (skipped)" : row.title)
                }
                .width(min: compact ? 90 : 120, ideal: compact ? 110 : 160)
                if showsCourse {
                    TableColumn("Course", value: \.course) { row in Text(row.course).foregroundStyle(.rowSecondary).lineLimit(1).help(row.course) }
                        .width(min: 80, ideal: 110)
                }
                TableColumn("Due", value: \.due) { row in
                    let due = Design.due(row.hasDue ? row.due : nil, hasTime: row.dueHasTime)
                    Text(due).monospacedDigit().lineLimit(1).foregroundStyle(row.hasDue ? AnyShapeStyle(.primary) : AnyShapeStyle(.rowSecondary)).help(due)
                }
                .width(min: 80, ideal: compact ? 100 : 130)
                TableColumn("Counts Toward", value: \.component) { row in
                    Text(row.component.isEmpty ? "—" : row.component).foregroundStyle(row.component.isEmpty ? .rowTertiary : .rowSecondary).lineLimit(1).help(row.component)
                }
                .width(min: 50, ideal: compact ? 70 : 90)
                TableColumn("Weight", value: \.weight) { row in
                    Group { if row.weight >= 0 { Design.points(row.weight).fontWeight(.semibold) } else { Text("—").foregroundStyle(.rowTertiary) } }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 46, ideal: 50, max: 80)
                .alignment(.trailing)   // the header over its figures
            }
            .paperTable()
            .appEntityIdentifier(forSelectionType: UUID.self) { EntityIdentifier(for: ItemEntity.self, identifier: $0) }   // Siri's "this": the rows, by their selection (WWDC26: collection annotations)
            .takesKeyboard($focused, hasRows: !rows.isEmpty)
            .opacity(rows.isEmpty ? 0.001 : 1)   // kept in the layout (its height), but an empty table's header says nothing
            .overlay(alignment: .top) {
                if rows.isEmpty { Text(emptyText).foregroundStyle(.secondary).padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Design.margin) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                let chosen = rows.filter { ids.contains($0.id) }
                if !chosen.isEmpty {
                    let allDone = chosen.allSatisfy(\.done)
                    Button(ItemActions.markTitle(done: allDone)) { for row in chosen { mark(row.id, !allDone) } }
                    let allSkipped = chosen.allSatisfy(\.skipped)
                    Button(ItemActions.skipTitle(skipped: allSkipped)) { for row in chosen { skip(row.id, !allSkipped) } }
                    if chosen.count == 1, let one = chosen.first {
                        Button("Edit…") { edit(one.id) }
                        if let open = openDocument(one) { Button("Open Document", action: open) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { delete(ids) }
                }
            } primaryAction: { ids in
                if let first = ids.first, ids.count == 1 { edit(first) }
            }
            .onDeleteCommand { delete(visibleSelection) }
            // A row chosen with the pointer takes the keyboard with it: after the chart above had it (it is focusable,
            // for its arrow keys), a click on a row selected it but left the keys with the chart, so Delete and ⌘⌫
            // did nothing until Tab.
            .onChange(of: selection) { _, chosen in if !chosen.isEmpty, !focused { focused = true } }
            .onChange(of: rows.map(\.id)) { _, ids in selection.formIntersection(ids) }   // a row that left the table (a filter, Show Done, another period) leaves the selection too, so nothing unseen is acted on
            .task(id: reveal) {   // once the rows are laid out: a row asked for before then is nowhere to scroll to
                guard let reveal else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                proxy.scrollTo(reveal, anchor: .center)
            }
            // The table's own. It stays published under a sheet, so the Item menu checks `keyboardIsElsewhere` first: ⌘⌫ in
            // a sheet's field deletes words, never the item behind the sheet.
            .focusedValue(\.selectedItem, visibleSelection.count == 1 ? rows.first { visibleSelection.contains($0.id) }.map { row in
                SelectedItem(id: row.id, done: row.done, skipped: row.skipped, mark: { mark(row.id, $0) }, skip: { skip(row.id, $0) }, edit: { edit(row.id) },
                             openDocument: openDocument(row), delete: { delete([row.id]) })   // Item ▸ Mark Done, the way a click on the ring does it; ⌘⌫ as Delete does
            } : nil)
            .quickLookPreview($preview)
        }
    }

    /// The selection, of the rows that are here.
    private var visibleSelection: Set<UUID> { selection.intersection(rows.map(\.id)) }

    /// Shows the document a row was read from in Quick Look, when its file is on this Mac.
    private func openDocument(_ row: ItemRow) -> (() -> Void)? {
        guard let doc = row.document, model.hasFile(doc) else { return nil }
        return { preview = model.previewFile(for: doc) }
    }
}

/// What the chart is showing, set above it: a kicker, the deck (the day or the run of days under the pointer, else
/// the one chosen, else the term), a line of figures, and on the trailing side the legend of what the colour means.
private struct ChartHeader: View {
    let data: StripData
    let chosen: DateInterval?
    let pointer: ChartPointer
    let calendar: Calendar

    enum Style { case long, short }

    /// A run of days by name: a day, a week (Monday to Sunday, or however the calendar runs), or from one day to another.
    static func name(of period: DateInterval, calendar: Calendar, style: Style) -> String {
        let days = calendar.dateComponents([.day], from: period.start, to: period.end).day ?? 1
        let last = period.end.addingTimeInterval(-1)
        if days <= 1 { return period.start.formatted(style == .long ? .dateTime.weekday(.wide).month(.wide).day() : .dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        if let week = calendar.dateInterval(of: .weekOfYear, for: period.start), week == period {
            return "Week of \(period.start.formatted(style == .long ? .dateTime.month(.wide).day() : .dateTime.month(.abbreviated).day()))"
        }
        let month: Date.FormatStyle = style == .long ? .dateTime.month(.wide).day() : .dateTime.month(.abbreviated).day()
        return "\(period.start.formatted(month)) – \(last.formatted(month))"
    }

    var body: some View {
        let shown = pointer.day ?? chosen
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                if let shown {
                    let items = data.items.filter { shown.holds($0.due) }
                    let points = items.filter { !$0.completed }.reduce(0) { $0 + ($1.points ?? 0) }
                    let pileup = data.collisions.contains { shown.holds($0.day) }
                    let days = calendar.dateComponents([.day], from: shown.start, to: shown.end).day ?? 1
                    let kind = pileup ? "Pileup" : days <= 1 ? "Day" : calendar.dateInterval(of: .weekOfYear, for: shown.start) == shown ? "Week" : "\(days) days"
                    Text(kicker(kind)).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(pileup ? Design.accentInk : .secondary).lineLimit(1)
                    Text(Self.name(of: shown, calendar: calendar, style: .long)).deck().lineLimit(1).contentTransition(.numericText())
                    Text(items.isEmpty ? "Nothing due." : "\(items.count) item\(items.count == 1 ? "" : "s"), \(points.formatted(.number.precision(.fractionLength(0...1))))% of grades at stake.")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(kicker("Term")).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(.secondary).lineLimit(1)
                    Text(summary).deck().lineLimit(1)
                    ViewThatFits(in: .horizontal) {   // the widest wording the header has room for, never cut short
                        Text("Point at a day to read it. Click to choose it, drag across days to choose a stretch, or click a week's date.")
                        Text("Point at a day to read it. Click to choose it, or drag across days.")
                        Text("Point at a day to read it.")
                    }
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HeatLegend()
        }
        // No animation: a chart's reading changes at once as the pointer moves (a crossfade would lay one day's words
        // over the next's while scrubbing).
    }

    private func kicker(_ word: String) -> String { data.narrowedTo.map { "\(word) · \($0.name)" } ?? word }

    /// The term in a line, as the iPhone's strip says it: everything on the page, what of it is still ahead (the
    /// table's "Coming up"), the pileups.
    private var summary: String {
        let total = data.items.count, count = data.collisions.count
        let today = calendar.startOfDay(for: Date())
        let ahead = data.items.filter { $0.due >= today && !$0.completed }.count
        let items = total == 1 ? "1 item" : "\(total) items"
        let still = ahead == 0 ? "none still ahead" : ahead == total && total > 1 ? "all still ahead" : "\(ahead) still ahead"
        let pileups = count == 0 ? "no pileups" : count == 1 ? "1 pileup" : "\(count) pileups"
        return "\(items), \(still), \(pileups)."
    }
}

/// The term, day by day, one band per course. Top to bottom: the months, the weeks (each week's first date), the
/// bands, and a foot for "Today". Left to right: the bands' names, then the days, each as wide as the window allows.
/// Load is colour, never size (`Strip.heat`).
private struct TermChart: View {
    let data: StripData
    @Binding var chosen: DateInterval?
    let pointer: ChartPointer
    /// Days of the items selected in the table, marked under the bands.
    let marked: Set<Date>
    let calendar: Calendar
    @FocusState private var focused: Bool
    /// Where the choice was begun and where its moving end is, as days along the chart: Shift and an arrow move the
    /// moving end, so a run stretches or shrinks either way from where it began.
    @State private var anchor: Int?
    @State private var cursor: Int?

    fileprivate struct Geometry {
        static let labelWidth: CGFloat = 176, monthTier: CGFloat = 22, weekTier: CGFloat = 18, row: CGFloat = 38, foot: CGFloat = 22
        let width: CGFloat
        let days: Int
        let bands: Int
        var plotX: CGFloat { Self.labelWidth }
        var dayWidth: CGFloat { max(width - plotX, 1) / CGFloat(max(days, 1)) }
        var bandsTop: CGFloat { Self.monthTier + Self.weekTier }
        var bandsBottom: CGFloat { bandsTop + CGFloat(max(bands, 1)) * Self.row }
        var height: CGFloat { bandsBottom + Self.foot }
        func x(_ day: Int) -> CGFloat { plotX + CGFloat(day) * dayWidth }
        /// The day at a point along the chart; a point left of the plot (over the bands' names) is the first day.
        func day(at x: CGFloat) -> Int? { days == 0 ? nil : min(max(Int(floor((x - plotX) / dayWidth)), 0), days - 1) }
        func rowTop(_ band: Int) -> CGFloat { bandsTop + CGFloat(band) * Self.row }
    }

    private var height: CGFloat { Geometry(width: 0, days: data.periods.count, bands: data.bands.count).height }

    var body: some View {
        GeometryReader { geo in
            let g = Geometry(width: geo.size.width, days: data.periods.count, bands: data.bands.count)
            ChartCanvas(data: data, g: g, chosen: chosen, pointer: pointer, marked: marked, calendar: calendar)
                .overlay(alignment: .topLeading) { bandNames(g) }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):   // over the axis the week reads, as a click there chooses it; over the bands, the day
                        guard point.x >= g.plotX, point.y < g.bandsBottom + 4, let i = g.day(at: point.x) else { pointer.day = nil; return }
                        pointer.day = point.y < g.bandsTop ? calendar.dateInterval(of: .weekOfYear, for: data.periods[i].start) : data.periods[i]
                    case .ended: pointer.day = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard value.startLocation.x >= g.plotX, value.startLocation.y >= g.bandsTop, value.startLocation.y < g.bandsBottom + 4, abs(value.translation.width) >= 4,
                              let a = g.day(at: value.startLocation.x), let b = g.day(at: value.location.x) else { return }
                        pointer.day = nil   // the header reads the choice while it is being made
                        choose(from: a, to: b)   // a drag chooses the run of days it covers
                    }
                    .onEnded { value in
                        focused = true
                        guard abs(value.translation.width) < 4, value.startLocation.x >= g.plotX, value.startLocation.y < g.bandsBottom + 4,   // under the bands (the foot, "Today") is nothing to choose, as the pointer reads nothing there
                              let a = g.day(at: value.startLocation.x) else { return }
                        pointer.day = nil   // the header reads what was just chosen; the next move of the pointer reads again
                        let day = data.periods[a]
                        if value.startLocation.y < g.bandsTop, let week = calendar.dateInterval(of: .weekOfYear, for: day.start),   // a click on the axis: the week
                           let first = data.periods.firstIndex(where: { $0.end > week.start }), let last = data.periods.lastIndex(where: { $0.start < week.end }) {
                            choose(from: first, to: last)
                        } else if chosen == day {
                            chosen = nil; anchor = nil; cursor = nil   // the same day again lets it go
                        } else {
                            choose(from: a, to: a)
                        }
                    })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("The term, day by day")
                .accessibilityChildren { weekElements(g) }
        }
        .frame(height: height)
        .focusable()
        .focusEffectDisabled()   // a click focuses the chart for the arrow keys; the chosen day's ground shows where they act, a ring round the whole chart would say nothing
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            step(press.key == .leftArrow ? -1 : 1, stretch: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.escape) { guard chosen != nil else { return .ignored }; chosen = nil; anchor = nil; cursor = nil; return .handled }
    }

    /// VoiceOver's path through the term: each week with something in it, over its own days in the chart (so the
    /// cursor outlines the week it names), choosing it as its action.
    private func weekElements(_ g: Geometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(weeks, id: \.start) { week in
                let items = data.items.filter { week.holds($0.due) }
                let points = items.filter { !$0.completed }.reduce(0) { $0 + ($1.points ?? 0) }
                let first = data.periods.firstIndex { $0.end > week.start } ?? 0
                let last = data.periods.lastIndex { $0.start < week.end } ?? first
                let width = max(g.x(last + 1) - g.x(first), 1), height = g.bandsBottom - g.bandsTop
                Rectangle()
                    .frame(width: width, height: height)
                    .position(x: g.x(first) + width / 2, y: g.bandsTop + height / 2)
                    .accessibilityLabel("Week of \(week.start.formatted(.dateTime.month(.wide).day()))")
                    .accessibilityValue("\(items.count) item\(items.count == 1 ? "" : "s"), \(points.formatted(.number.precision(.fractionLength(0...1)))) percent of grades at stake")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { choose(from: first, to: last) }
            }
        }
        .frame(width: g.width, height: g.height, alignment: .topLeading)
    }

    /// The weeks with anything due in them.
    private var weeks: [DateInterval] {
        var seen: [Date: DateInterval] = [:]
        for item in data.items { if let week = calendar.dateInterval(of: .weekOfYear, for: item.due) { seen[week.start] = week } }
        return seen.values.sorted { $0.start < $1.start }
    }

    /// The days from one to another, whichever way round, as the choice; `from` is where it was begun.
    private func choose(from start: Int, to end: Int) {
        let days = data.periods
        chosen = DateInterval(start: days[min(start, end)].start, end: days[max(start, end)].end)
        anchor = start; cursor = end
    }

    /// The arrow keys: the chosen day moves a day, and Shift stretches the choice from where it was begun (either
    /// way); with nothing chosen, today is.
    private func step(_ by: Int, stretch: Bool) {
        let days = data.periods
        guard !days.isEmpty else { return }
        pointer.day = nil   // the header reads the choice as the keys move it
        let today = calendar.startOfDay(for: Date())
        guard let chosen, let first = days.firstIndex(where: { $0.end > chosen.start }), let last = days.lastIndex(where: { $0.start < chosen.end }) else {
            let at = days.firstIndex { $0.start == today } ?? 0
            choose(from: at, to: at)
            return
        }
        // The begun end and the moving one, unless the choice was made some other way (then from its start to its end).
        var from = first, to = last
        if let anchor, let cursor, min(anchor, cursor) == first, max(anchor, cursor) == last { from = anchor; to = cursor }
        if stretch {
            choose(from: from, to: min(max(to + by, 0), days.count - 1))
        } else {
            let at = min(max((by < 0 ? min(from, to) : max(from, to)) + by, 0), days.count - 1)
            choose(from: at, to: at)
        }
    }

    /// The bands' names, in the column beside their days.
    private func bandNames(_ g: Geometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data.bands) { band in
                Text(band.name).font(.caption2.weight(.semibold)).textCase(.uppercase).kerning(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)   // a long name takes a second line in its band (two fit in a row) rather than lose its middle
                    .frame(width: Geometry.labelWidth - 16, height: Geometry.row, alignment: .leading)
            }
        }
        .padding(.top, g.bandsTop)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The chart's drawing: the ground of the chosen days and the one under the pointer, the months and weeks, the cells,
/// the pileups, today, and the marks of the items selected in the table.
private struct ChartCanvas: View {
    let data: StripData
    let g: TermChart.Geometry
    let chosen: DateInterval?
    let pointer: ChartPointer
    let marked: Set<Date>
    let calendar: Calendar

    private func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)) }
    }

    /// The first and last day of a run, as indices along the chart.
    private func indices(_ period: DateInterval) -> ClosedRange<Int>? {
        guard let first = data.periods.firstIndex(where: { $0.end > period.start }),
              let last = data.periods.lastIndex(where: { $0.start < period.end }), first <= last else { return nil }
        return first...last
    }

    var body: some View {
        let hover = pointer.day
        Canvas { context, size in
            let days = data.periods
            guard !days.isEmpty else { return }
            let today = calendar.startOfDay(for: Date())

            // Grounds, behind everything: the chosen run of days, and the day under the pointer.
            if let chosen, let run = indices(chosen) {
                context.fill(Path(CGRect(x: g.x(run.lowerBound), y: g.bandsTop - 2, width: g.x(run.upperBound + 1) - g.x(run.lowerBound), height: g.bandsBottom - g.bandsTop + 4)),
                             with: .color(.primary.opacity(0.1)))
            }
            if let hover, let run = indices(hover) {
                context.fill(Path(CGRect(x: g.x(run.lowerBound), y: g.bandsTop - 2, width: g.x(run.upperBound + 1) - g.x(run.lowerBound), height: g.bandsBottom - g.bandsTop + 4)),
                             with: .color(.primary.opacity(0.07)))
            }

            // Weeks: a faint rule at each week's first day, its date on the lower tier of the axis.
            let weekWidth = g.dayWidth * 7
            var flags: [ClosedRange<CGFloat>] = []   // where the pileups' dates sit, which the weeks' dates give way to
            for collision in data.collisions {
                guard let i = days.firstIndex(where: { $0.start == collision.day }) else { continue }
                let label = context.resolve(Text(collision.day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accentInk))
                let w = label.measure(in: CGSize(width: 120, height: 30)).width
                let cx = min(max(g.x(i) + g.dayWidth / 2, g.plotX + w / 2), size.width - w / 2)
                if flags.contains(where: { $0.overlaps((cx - w / 2 - 4)...(cx + w / 2 + 4)) }) { continue }
                flags.append((cx - w / 2 - 4)...(cx + w / 2 + 4))
                context.draw(label, at: CGPoint(x: cx, y: TermChart.Geometry.monthTier + TermChart.Geometry.weekTier / 2), anchor: .center)
            }
            for (i, day) in days.enumerated() where calendar.component(.weekday, from: day.start) == calendar.firstWeekday {
                let x = g.x(i)
                context.stroke(vertical(x, TermChart.Geometry.monthTier + 3, g.bandsBottom), with: .color(.secondary.opacity(0.14)), lineWidth: 1)
                guard weekWidth >= 22 else { continue }
                let label = context.resolve(Text(day.start.formatted(.dateTime.day())).font(.caption2).foregroundStyle(day.start == today ? .primary : .secondary))
                let w = label.measure(in: CGSize(width: 40, height: 20)).width
                guard x + 3 + w <= size.width, !flags.contains(where: { $0.overlaps((x + 2)...(x + 4 + w)) }) else { continue }   // never cut at the chart's edge
                context.draw(label, at: CGPoint(x: x + 3, y: TermChart.Geometry.monthTier + TermChart.Geometry.weekTier / 2), anchor: .leading)
            }

            // Months: a rule where each begins, its name on the upper tier in the widest spelling its room allows.
            var index = 0
            while index < days.count {
                let month = calendar.dateInterval(of: .month, for: days[index].start)
                let next = days.firstIndex { $0.start >= (month?.end ?? .distantFuture) } ?? days.count
                let from = g.x(index), to = g.x(next)
                let begins = calendar.component(.day, from: days[index].start) == 1
                if begins { context.stroke(vertical(from, 0, g.bandsBottom), with: .color(.secondary.opacity(0.35)), lineWidth: 1) }
                for face in [Date.FormatStyle.dateTime.month(.wide), .dateTime.month(.abbreviated)] {
                    let name = context.resolve(Text(days[index].start.formatted(face)).font(.system(.subheadline, design: .serif, weight: .semibold)).foregroundStyle(.primary))
                    guard name.measure(in: CGSize(width: 300, height: 30)).width <= to - from - 10 else { continue }
                    context.draw(name, at: CGPoint(x: from + (begins ? 6 : 0), y: 1), anchor: .topLeading)
                    break
                }
                index = next
            }

            // Lanes: a band's run of days as one soft ground, so a course reads across the term; then its cells: a day
            // with anything due.
            let cellHeight = TermChart.Geometry.row - 10
            for band in 0..<data.bands.count {
                let lane = CGRect(x: g.plotX, y: g.rowTop(band) + 5, width: g.x(days.count) - g.plotX, height: cellHeight)
                context.fill(Path(roundedRect: lane, cornerRadius: 4), with: .color(.primary.opacity(0.035)))
            }
            for band in 0..<data.bands.count where band < data.cells.count {
                for (i, day) in days.enumerated() {
                    guard let cell = data.cells[band][day.start] else { continue }
                    let rect = CGRect(x: g.x(i) + 0.5, y: g.rowTop(band) + 5, width: max(g.dayWidth - 1, 2), height: cellHeight)
                    let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.width / 2))
                    context.fill(shape, with: .color(Design.paper))
                    context.fill(shape, with: .color(Design.accent.opacity(Strip.heat(points: cell.points))))
                    if rect.width >= 16 {   // a day wide enough carries its count
                        let ink: Color = Strip.heat(points: cell.points) > 0.55 ? .black.opacity(0.75) : .primary
                        context.draw(Text("\(cell.count)").font(.caption2.weight(.semibold)).foregroundStyle(ink), at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }

            // Pileups: a rule through the day, over the cells, so a heavy day is never lost among its neighbours.
            for collision in data.collisions {
                guard let i = days.firstIndex(where: { $0.start == collision.day }) else { continue }
                context.stroke(vertical(g.x(i) + g.dayWidth / 2, g.bandsTop - 2, g.bandsBottom), with: .color(.primary.opacity(0.65)), lineWidth: 1)
            }

            // The items selected in the table: a mark under their days.
            for (i, day) in days.enumerated() where marked.contains(day.start) {
                let rect = CGRect(x: g.x(i) + 0.5, y: g.bandsBottom + 2, width: max(g.dayWidth - 1, 3), height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Design.accent))
            }

            // Today, over everything.
            if let i = days.firstIndex(where: { $0.start == today }) {
                let tx = g.x(i) + g.dayWidth / 2
                context.stroke(vertical(tx, g.bandsTop - 2, g.bandsBottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: tx, y: size.height), anchor: .bottom)
            }
        }
    }
}
#endif
