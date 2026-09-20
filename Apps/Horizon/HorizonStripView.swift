import SwiftUI
import SwiftData
import HorizonCore

/// The app's screens (SPEC §6): Coverage, the Horizon strip, and Now.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    /// `--tab-horizon` / `--tab-now` (DEBUG) open on a tab, for screenshots from the command line.
    @State private var tab = Self.debugFlag("--tab-horizon") ? 1 : Self.debugFlag("--tab-now") ? 2 : 0

    var body: some View {
        #if os(iOS)
        TabView(selection: $tab) {
            Tab("Coverage", systemImage: "eye", value: 0) { RootView() }
            Tab("Horizon", systemImage: "chart.bar.xaxis", value: 1) { HorizonStripView() }
            Tab("Now", systemImage: "sun.horizon", value: 2) { NowView() }
        }
        .onChange(of: model.openNowRequested) { _, wanted in   // a tap on the plan's Live Activity
            if wanted { tab = 2; model.openNowRequested = false }
        }
        #else
        MacRootView()
        #endif
    }

    static func debugFlag(_ flag: String) -> Bool {
        #if DEBUG
        CommandLine.arguments.contains(flag)
        #else
        false
        #endif
    }

    /// A DEBUG flag that acts, rather than shows: true once per launch, however often the view that reads it appears.
    static func debugOnce(_ flag: String) -> Bool {
        guard debugFlag(flag), !spentFlags.contains(flag) else { return false }
        spentFlags.insert(flag)
        return true
    }
    private static var spentFlags: Set<String> = []
}

/// The three stops of the range control, by the days across the screen.
private enum Stop: Hashable, CaseIterable {
    case semester, month, twoWeeks
    var title: String { switch self { case .semester: "Semester"; case .month: "Month"; case .twoWeeks: "Two Weeks" } }
}

/// A band of the strip: everything together, a course, or the items filed under none.
private struct Band: Identifiable, Equatable {
    enum Kind: Hashable { case all, course(UUID), unfiled }
    var kind: Kind
    var name: String
    var id: Kind { kind }
}

/// Where things sit in the strip. Top to bottom: an axis of two tiers (the months; under them the day numbers and the
/// pileups' dates, so neither is ever drawn over the other), one row per band (a line for its name, its cells, a gap),
/// and a foot for "Today". Left to right: the page's margin inside the canvas at both ends, then `scale` points a day.
private struct StripGeometry: Equatable {
    var rows: Int
    var rowHeight: CGFloat
    var labelHeight: CGFloat
    var scale: CGFloat
    let monthTier: CGFloat = 20
    let flagTier: CGFloat = 18
    let gap: CGFloat = 8
    let foot: CGFloat = 16
    let inset: CGFloat = 20

    var axisHeight: CGFloat { monthTier + flagTier }
    func rowTop(_ i: Int) -> CGFloat { axisHeight + rowHeight * CGFloat(i) }
    /// A band's cells stand on its baseline, and its name sits right on top of them: what a roomy band has to spare
    /// goes above the name, between the bands. A cell stops growing at 56 points, so a lone course is not a wall of colour.
    var cellsHeight: CGFloat { min(56, rowHeight - labelHeight - gap) }
    func baseline(_ i: Int) -> CGFloat { rowTop(i) + rowHeight - gap }
    /// From a row's top to its name's line.
    var labelOffset: CGFloat { rowHeight - gap - cellsHeight - labelHeight }
    var bottom: CGFloat { axisHeight + rowHeight * CGFloat(max(rows, 1)) }
    var height: CGFloat { bottom + foot }
    func x(_ date: Date, from start: Date) -> CGFloat { inset + CGFloat(date.timeIntervalSince(start) / 86_400) * scale }
}

/// SPEC §6.2: one continuous strip of the term, one band per course, and above them (when there are several) a band
/// for everything, where the shape of the term shows. What it shows follows the zoom, the way Health's charts change
/// with their range: the whole semester reads as weeks, a month as days, and only two weeks or less as the items
/// themselves. Load is colour, not size: the accent deepens with the points at stake in a week, a day or an item, and
/// a cell carries its count. Days where heavy items pile up are called out.
///
/// The page is one scroll (HIG: no competing scroll regions; the strip scrolls sideways inside it, which is fine):
/// the range, the header, the strip, then the list, so the list has the whole page when the user wants it and the
/// large title folds away. The strip fits the load: its bands share what the screen can spare (`Strip.rowHeight`),
/// so a full course load still leaves the head of the list in view. A tap or a press-and-drag scrubs a week or a day
/// into the header and the list (what is coming up when nothing is scrubbed); a tap brings the list's first rows
/// into view if they are under the fold, and the same tap again, or the list's own button, lets the period go.
struct HorizonStripView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.due != nil }, sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var zoom: CGFloat = 1            // 1 = the whole semester across the width
    @State private var pinchBase: CGFloat = 1
    @State private var pinch: PinchAnchor?
    @State private var scrollOffset: CGFloat = 0
    @State private var position = ScrollPosition()
    @State private var scrub: Date?
    @State private var hover: Date?                  // macOS: the day under the pointer reads in the header without a click
    @State private var reveals: [UUID: Date] = [:]  // when each mark first appeared, so new ones fade in
    @State private var seeded = false
    @State private var animating = false
    @State private var centreOn: Date?               // a stop lands on the scrubbed day, else today
    @State private var previousLevel: (level: Strip.Level, at: Date)?   // the level just left, for the crossfade
    @State private var editing: Obligation?
    @State private var lingering = Lingering()       // just checked off under "Coming up": crossed off for a moment before it leaves, so a slip can be undone
    @State private var listHeadY: CGFloat = 0        // where the list begins on the screen, to know when a scrub's items are under the fold
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 16
    private let calendar = Calendar.current
    /// What sits above the strip on the page (the range and the header), and what the list needs to show its head
    /// (its kicker and two rows): the strip's bands share the rest.
    private let chromeAbove: CGFloat = 190, listHead: CGFloat = 170

    /// Where the fingers came down, in content points, so zooming keeps that day under them.
    private struct PinchAnchor { var contentX: CGFloat; var offset: CGFloat; var zoom: CGFloat }

    private var items: [StripItem] {
        obligations.compactMap { o in
            guard let due = o.due else { return nil }
            return StripItem(id: o.id, title: o.title, courseID: o.course?.id, courseCode: o.course?.code ?? "", courseName: o.course?.title, due: due, dueHasTime: o.dueHasTime,
                             points: o.pointsAtStake, state: o.state, completed: o.completedAt != nil)
        }
    }
    /// A band for everything when there are several to add up, one per course with items, and one for items filed
    /// under no course (documents nobody has filed yet).
    private var bands: [Band] {
        let known = Set(courses.map(\.id))
        var bands = courses.filter { c in obligations.contains { $0.course?.id == c.id } }.map { Band(kind: .course($0.id), name: $0.displayName) }
        if obligations.contains(where: { $0.course.map { !known.contains($0.id) } ?? true }) { bands.append(Band(kind: .unfiled, name: "Unfiled")) }
        if Strip.showsTotal(bands: bands.count) { bands.insert(Band(kind: .all, name: "All courses"), at: 0) }
        return bands
    }
    private func items(in band: Band) -> [StripItem] {
        switch band.kind {
        case .all: return items
        case .course(let id): return items.filter { $0.courseID == id }
        case .unfiled:
            let known = Set(courses.map(\.id))
            return items.filter { $0.courseID.map { !known.contains($0) } ?? true }
        }
    }
    private var span: ClosedRange<Date> {
        Strip.span(termStarts: courses.compactMap(\.termStart), termEnds: courses.compactMap(\.termEnd), items: items, now: Date(), calendar: calendar)
    }
    private var days: Int { max(1, calendar.dateComponents([.day], from: span.lowerBound, to: span.upperBound).day ?? 1) }
    private var maxZoom: CGFloat { max(1, CGFloat(days) / 14) }                 // two weeks across the width
    private var clampedZoom: CGFloat { min(max(zoom, 1), maxZoom) }
    private var level: Strip.Level { Strip.level(daysAcross: Double(days) / Double(clampedZoom)) }
    private var collisions: [Strip.Collision] { Strip.collisions(items, calendar: calendar) }
    private func zoom(for stop: Stop) -> CGFloat {
        switch stop { case .semester: 1; case .month: min(maxZoom, CGFloat(days) / 30); case .twoWeeks: maxZoom }
    }
    /// The stop nearest the current zoom, so a pinch keeps the control honest without snapping the zoom to it.
    private var stop: Binding<Stop> {
        Binding(get: { Stop.allCases.min { abs(log(zoom(for: $0) / clampedZoom)) < abs(log(zoom(for: $1) / clampedZoom)) } ?? .semester },
                set: { zoomTo(zoom(for: $0)) })
    }
    /// The scrubbed period at this level, with its items; on the Mac the day under the pointer takes precedence in the header.
    private var scrubbed: Strip.Cell? { cell(for: hover ?? scrub, among: items) }
    private func cell(for day: Date?, among items: [StripItem]) -> Strip.Cell? {
        guard let day else { return nil }
        let period = Strip.period(containing: day, level: level, calendar: calendar)
        return Strip.cells(items.filter { period.contains($0.due) }, level: level, calendar: calendar).first ?? Strip.Cell(period: period, items: [], points: 0)
    }
    /// Under the strip: the scrubbed period's items, else what is coming up from today; in time order, heavier first
    /// on a tie, and what is done last, once its moment is over.
    private var listed: [Obligation] {
        let byID = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0) })
        let chosen: [StripItem]
        if let clicked = cell(for: scrub, among: items) { chosen = clicked.items } else {
            let today = calendar.startOfDay(for: Date())
            chosen = items.filter { $0.due >= today && (!$0.completed || lingering.contains($0.id)) }
        }
        let settled: (StripItem) -> Bool = { $0.completed && !lingering.contains($0.id) }
        return chosen.sorted { settled($0) != settled($1) ? !settled($0) : $0.due != $1.due ? $0.due < $1.due : ($0.points ?? 0) > ($1.points ?? 0) }.compactMap { byID[$0.id] }
    }

    private func geometry(in size: CGSize) -> StripGeometry {
        let rows = max(bands.count, 1)
        let spare = Double(size.height - chromeAbove - listHead) - 38 - 16   // less the axis and the foot
        let row = CGFloat(Strip.rowHeight(rows: rows, available: spare, minimum: Double(labelHeight) + 28))
        let fit = max(size.width - 40, 100) / CGFloat(days)
        return StripGeometry(rows: rows, rowHeight: row, labelHeight: labelHeight, scale: fit * clampedZoom)
    }

    var body: some View {
        PageStack {
            GeometryReader { geo in
                let g = geometry(in: geo.size)
                ScrollViewReader { page in
                    List {
                        Section {
                            #if os(iOS)
                            RangeTabs(selection: stop)
                                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            #endif
                            StripHeader(scrub: hover ?? scrub, level: level, cell: scrubbed, total: items.count, collisions: collisions, calendar: calendar)
                                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                            strip(g, width: geo.size.width, page: page, viewportBottom: geo.frame(in: .global).maxY)
                                .listRowInsets(EdgeInsets())
                        }
                        .listRowSeparator(.hidden)
                        .onPaper()
                        Section {
                            ForEach(listed) { obligation in
                                Button { editing = obligation } label: { ObligationRow(obligation: obligation, mark: { mark(obligation.id, $0) }) }
                                    .buttonStyle(.plain)
                                    .id(obligation.id)   // what `reveal` scrolls to
                                    .obligationActions(done: obligation.completedAt != nil, mark: { mark(obligation.id, $0) }, edit: { editing = obligation },
                                                       delete: { Task { await model.discard(obligation.id) } })
                                    .accessibilityHint("Opens the editor")
                            }
                            if listed.isEmpty { Text(scrub == nil ? "Nothing coming up." : "Nothing due.").foregroundStyle(.secondary).id("nothing") }
                        } header: {
                            listHeader.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { listHeadY = $0 }
                        }
                        .onPaper()
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 1)
                    .paper()
                    .animation(.default, value: scrub)
                    .animation(.default, value: listed.map(\.id))
                }
                .overlay {
                    if items.isEmpty {
                        ScrollView {
                            EditorialEmpty(title: "Nothing on the horizon.", deck: "Add a syllabus or a schedule and the term appears here as one strip: weeks, then days, then the work itself as you zoom in.") {
                                ImportMenu().buttonStyle(.borderedProminent)
                            }
                            .padding(.horizontal, 20)
                        }
                        .background(Design.paper)
                    }
                }
                .onAppear {
                    if MainTabs.debugFlag("--zoom-two-weeks"), zoom == 1 { zoomTo(maxZoom) }
                    if MainTabs.debugFlag("--zoom-month"), zoom == 1 { zoomTo(zoom(for: .month)) }
                    if MainTabs.debugOnce("--scrub-week"), let heavy = collisions.first?.day ?? items.first?.due { scrub = heavy }   // DEBUG: a period read without a tap
                    if MainTabs.debugOnce("--check-first-coming-up"), let first = listed.first {   // DEBUG: a check without a tap, to see the row linger and leave
                        Task { try? await Task.sleep(for: .seconds(2)); mark(first.id, true) }
                    }
                }
                .onChange(of: centreOn) { _, target in
                    guard let target else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))   // after the zoom animation, once the wider content exists
                        // Values captured by this closure can predate the first layout; read the geometry live.
                        let live = geometry(in: geo.size)
                        let x = live.x(target, from: span.lowerBound) + live.scale / 2 - geo.size.width / 2
                        withAnimation { position.scrollTo(x: max(0, x)) }
                        centreOn = nil
                    }
                }
            }
            .background(Design.paper.ignoresSafeArea())
            .navigationTitle("Horizon")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .principal) {   // the range as a segmented control in the toolbar, where a Mac keeps a view's options
                    Picker("Range", selection: stop) {
                        ForEach(Stop.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("How much of the term is across the window")
                }
            }
            #endif
            .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
            .onChange(of: level) { old, _ in
                previousLevel = (old, Date())   // the old level fades out under the new one
                runAnimation(for: 0.35)
            }
            .onChange(of: obligations.map(\.id), initial: true) { _, ids in
                let now = Date()
                if !seeded { for id in ids { reveals[id] = .distantPast }; seeded = true; return }   // what is already on file simply is
                let fresh = ids.filter { reveals[$0] == nil }
                guard !fresh.isEmpty else { return }
                for id in fresh { reveals[id] = now }
                runAnimation(for: 0.9)
            }
        }
    }

    /// The strip: the canvas scrolling sideways, and over it the bands' names, which stay put. A name has its own
    /// line above its band's cells, so it never covers a cell; beside it, while a period is scrubbed, what that
    /// course has in it.
    private func strip(_ g: StripGeometry, width: CGFloat, page: ScrollViewProxy, viewportBottom: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
                StripCanvas(bands: bands.map { items(in: $0) }, totalFirst: bands.first?.kind == .all, span: span, geometry: g, level: level, previousLevel: previousLevel,
                            collisions: collisions, scrub: hover ?? scrub, reveals: reveals, now: timeline.date, leadingEdge: max(scrollOffset, 0), calendar: calendar)
            }
            .frame(width: CGFloat(days) * g.scale + g.inset * 2, height: g.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let day = day(atX: location.x, g)
                let again = scrub.map { Strip.period(containing: $0, level: level, calendar: calendar).contains(day) } ?? false
                scrub = again ? nil : day   // the same period again lets it go
                if !again { reveal(page, viewportBottom: viewportBottom) }
            }
            #if os(macOS)
            .onContinuousHover { phase in   // the pointer reads a week or a day; a click keeps it
                switch phase {
                case .active(let point): hover = day(atX: point.x, g)
                case .ended: hover = nil
                }
            }
            #endif
            .gesture(LongPressGesture(minimumDuration: 0.2).sequenced(before: DragGesture(minimumDistance: 0)).onChanged { value in
                if case .second(true, let drag?) = value { scrub = day(atX: drag.location.x, g) }
            })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    // Keep the day under the fingers where it is: scroll so that its screen position holds as the scale changes.
                    let anchor = pinch ?? PinchAnchor(contentX: value.startLocation.x, offset: scrollOffset, zoom: pinchBase)
                    if pinch == nil { pinch = anchor }
                    let level = min(max(anchor.zoom * value.magnification, 1), maxZoom)
                    zoom = level
                    let screenX = anchor.contentX - anchor.offset
                    position.scrollTo(x: max(0, (anchor.contentX - g.inset) / anchor.zoom * level + g.inset - screenX))
                }
                .onEnded { _ in pinchBase = zoom; pinch = nil })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityChildren {   // one stop per week or day with something in it, along the axis (HIG: a logical path, not every mark)
                ForEach(Strip.cells(items, level: level == .weeks ? .weeks : .days, calendar: calendar)) { cell in
                    Rectangle()
                        .accessibilityLabel(level == .weeks ? "Week of \(cell.period.start.formatted(.dateTime.month(.wide).day()))" : cell.period.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .accessibilityValue("\(cell.count) item\(cell.count == 1 ? "" : "s"), \(cell.points.formatted(.number.precision(.fractionLength(0...1)))) percent of grades at stake")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { scrub = cell.period.start }
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in scrollOffset = offset }
        .overlay(alignment: .topLeading) { bandLabels(g) }
    }

    /// The bands' names, in the page's margin, each on the line above its cells; while a period is scrubbed, a
    /// course's line ends with what it has there. The paper behind the words lets the strip's rules pass under them.
    private func bandLabels(_ g: StripGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bands) { band in
                HStack(spacing: 8) {
                    Text(band.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(band.kind == .all ? .primary : .secondary)
                        .padding(.trailing, 6).background(Design.paper)
                    Spacer(minLength: 0)
                    if band.kind != .all, let cell = cell(for: hover ?? scrub, among: items(in: band)), cell.count > 0 {
                        Text(cell.points > 0 ? "\(cell.count) · \(cell.points.formatted(.number.precision(.fractionLength(0...1))))%" : "\(cell.count)").monospacedDigit()
                            .foregroundStyle(.secondary).padding(.leading, 6).background(Design.paper).transition(.opacity)
                    }
                }
                .font(.caption2.weight(.semibold)).textCase(.uppercase).kerning(0.6)
                .frame(height: g.labelHeight)
                .padding(.top, g.labelOffset)
                .frame(height: g.rowHeight, alignment: .top)
            }
        }
        .padding(.horizontal, g.inset)
        .padding(.top, g.axisHeight)
        .animation(.default, value: hover ?? scrub)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Over the list: what it is a list of, and, for a scrubbed period, the way back to what is coming up.
    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            if let scrub, let cell = cell(for: scrub, among: items) {
                Kicker(level == .weeks ? "Week of \(cell.period.start.formatted(.dateTime.month(.abbreviated).day()))" : scrub.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                Spacer()
                Button("Coming Up", systemImage: "xmark.circle.fill") { self.scrub = nil }
                    .labelStyle(.titleAndIcon).font(.caption.weight(.medium)).buttonStyle(.borderless)
                    .accessibilityHint("Lists what is coming up instead")
            } else {
                Kicker("Coming up")
                Spacer()
            }
        }
    }

    /// A tap has chosen a period: if the head of its list is under the fold, the page moves just far enough to show
    /// its first rows (HIG: scroll automatically only as much as necessary). A drag never moves the page under the finger.
    private func reveal(_ page: ScrollViewProxy, viewportBottom: CGFloat) {
        guard listHeadY + listHead > viewportBottom + 8 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))   // once the list holds the period's items
            if listed.isEmpty { withAnimation(.snappy) { page.scrollTo("nothing", anchor: .bottom) } }
            else { let id = listed[min(1, listed.count - 1)].id; withAnimation(.snappy) { page.scrollTo(id, anchor: .bottom) } }   // the second row at the foot: two rows of the period in view
        }
    }

    /// A check under "Coming up" stays on the page for a moment, crossed off, then the row leaves; unchecked, it stays.
    private func mark(_ id: UUID, _ done: Bool) {
        lingering.mark(id, done: done)
        Task { await model.setCompleted(id, done) }
    }

    private func runAnimation(for seconds: Double) {
        animating = true
        Task { try? await Task.sleep(for: .seconds(seconds)); animating = false }
    }

    /// A stop lands on the scrubbed day, else today.
    private func zoomTo(_ level: CGFloat) {
        withAnimation { zoom = level; pinchBase = level }
        centreOn = scrub ?? Date()
    }

    /// The day under a touch; when a day is a few points wide, an empty day yields to a neighbour with items.
    private func day(atX x: CGFloat, _ g: StripGeometry) -> Date {
        let position = min(max((x - g.inset) / g.scale, 0), CGFloat(days))
        let hit = calendar.date(byAdding: .day, value: Int(position), to: span.lowerBound) ?? span.lowerBound
        guard level != .weeks, g.scale < 12, Strip.items(on: hit, in: items, calendar: calendar).isEmpty else { return hit }
        let fraction = position.truncatingRemainder(dividingBy: 1)
        for offset in fraction < 0.5 ? [-1, 1] : [1, -1] {
            if let day = calendar.date(byAdding: .day, value: offset, to: hit), !Strip.items(on: day, in: items, calendar: calendar).isEmpty { return day }
        }
        return hit
    }

    private var accessibilitySummary: String {
        let names = bands.filter { $0.kind != .all }.map(\.name).joined(separator: ", ")
        let showing = switch level { case .weeks: "by week"; case .days: "by day"; case .items: "item by item" }
        return "Semester strip \(showing), \(items.count) obligations across \(names). \(collisions.isEmpty ? "No pileups." : "\(collisions.count) pileups.")"
    }
}

/// The three stops as a row of tabs with a sliding accent underline, the way a magazine names its sections; a pinch
/// keeps the underline honest without snapping the zoom to a stop.
private struct RangeTabs: View {
    @Binding var selection: Stop
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(Stop.allCases, id: \.self) { stop in
                    let selected = stop == selection
                    Button { withAnimation(.snappy) { selection = stop } } label: {
                        VStack(spacing: 8) {
                            Text(stop.title).font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(selected ? .primary : .secondary)
                            ZStack {
                                Color.clear.frame(height: 2)
                                if selected { Rectangle().fill(Design.accent).frame(height: 2).matchedGeometryEffect(id: "underline", in: underline) }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
            }
            Hairline()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }
}

/// The scrubbed week or day, or the semester at a glance: a kicker, a two-line deck, one line under it. Always the same
/// height, so the strip below never moves; the accent marks a pileup.
private struct StripHeader: View {
    let scrub: Date?
    let level: Strip.Level
    let cell: Strip.Cell?
    let total: Int
    let collisions: [Strip.Collision]
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scrub, let cell {
                let pileup = collisions.contains { cell.period.contains($0.day) }
                let kicker = pileup ? "Pileup" : level == .weeks ? "Week" : "Day"
                Text(kicker).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(pileup ? Design.accent : .secondary)
                Text(title(scrub, period: cell.period)).deck().lineLimit(2, reservesSpace: true).contentTransition(.numericText())
                Text(cell.items.isEmpty ? "Nothing due." : "\(cell.count) item\(cell.count == 1 ? "" : "s"), \(cell.points.formatted(.number.precision(.fractionLength(0...1))))% of grades at stake.")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Semester").font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(.secondary)
                Text(summary).deck().lineLimit(2, reservesSpace: true)
                #if os(macOS)
                Text("Point at a week or a day to read it; click to keep it. Pinch to zoom.").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                #else
                Text("Tap to read a week or a day. Pinch to zoom.").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: scrub)
        .animation(.default, value: level)
    }

    private func title(_ scrub: Date, period: DateInterval) -> String {
        level == .weeks ? "Week of \(period.start.formatted(.dateTime.month(.wide).day()))" : scrub.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private var summary: String {
        let pileups = collisions.count == 0 ? "no pileups" : collisions.count == 1 ? "one pileup" : "\(collisions.count) pileups"
        return "\(total) obligation\(total == 1 ? "" : "s") on the horizon, \(pileups)."
    }
}

/// The strip itself. An axis of two tiers: the months (shortened when a month is narrow), and under them the day
/// numbers and, in the accent, the dates of the pileups, which take precedence over a day number in their way. One
/// row per band under its name's line: at the weeks and days levels a cell per period whose colour is its load and
/// which carries its count; at the items level a mark per item, its colour its weight, named when the band is tall
/// enough (the band for everything stays cells at every level). Pileup hairlines, today, the scrubbed period.
private struct StripCanvas: View {
    /// The items of each band, in the bands' order.
    let bands: [[StripItem]]
    /// The first band is the one for everything.
    let totalFirst: Bool
    let span: ClosedRange<Date>
    let geometry: StripGeometry
    let level: Strip.Level
    let previousLevel: (level: Strip.Level, at: Date)?
    let collisions: [Strip.Collision]
    let scrub: Date?
    let reveals: [UUID: Date]
    let now: Date
    /// How far the strip has scrolled: the month in view keeps its name at the leading edge, the way a calendar's does.
    let leadingEdge: CGFloat
    let calendar: Calendar
    private let crossfade = 0.3

    private var g: StripGeometry { geometry }
    private var scale: CGFloat { g.scale }
    private func x(_ date: Date) -> CGFloat { g.x(date, from: span.lowerBound) }
    private func vertical(_ px: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: px, y: y0)); p.addLine(to: CGPoint(x: px, y: y1)) }
    }
    /// How far a new mark has faded in (0.6 s); what was already on file is 1.
    private func grow(_ item: StripItem) -> Double {
        guard let start = reveals[item.id], start != .distantPast else { return 1 }
        let t = min(1, max(0, now.timeIntervalSince(start) / 0.6))
        return 1 - pow(1 - t, 3)
    }

    var body: some View {
        Canvas { context, size in
            let pileupIDs = Set(collisions.flatMap { $0.items.map(\.id) })

            // The scrubbed week or day: a soft column behind everything else.
            if let scrub {
                let period = Strip.period(containing: scrub, level: level, calendar: calendar)
                let sx = x(period.start)
                context.fill(Path(roundedRect: CGRect(x: sx, y: g.axisHeight - 2, width: max(x(period.end) - sx, 2), height: g.bottom - g.axisHeight + 2), cornerRadius: 3), with: .color(.primary.opacity(0.08)))
            }

            // The pileups' dates first: they own their place on the lower tier, and a day number gives way to them.
            var flags: [(rect: CGRect, text: GraphicsContext.ResolvedText)] = []
            for collision in collisions {
                let text = context.resolve(Text(collision.day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accent))
                let w = text.measure(in: CGSize(width: 120, height: 30)).width
                let cx = min(max(x(collision.day) + scale / 2, w / 2 + 2), size.width - w / 2 - 2)
                let rect = CGRect(x: cx - w / 2, y: g.monthTier, width: w, height: g.flagTier)
                if let last = flags.last, last.rect.maxX + 6 > rect.minX { continue }   // two pileups a few points apart: the first is named, both are ruled
                flags.append((rect, text))
            }

            // Axis, upper tier: each month's name at its first day, or at the strip's leading edge while that day is
            // off screen (so two weeks in mid-month still say which month), in the widest spelling its room allows.
            var month = calendar.dateInterval(of: .month, for: span.lowerBound)?.start ?? span.lowerBound
            while month <= span.upperBound {
                let next = calendar.date(byAdding: .month, value: 1, to: month) ?? span.upperBound
                let from = x(max(month, span.lowerBound)), to = x(min(next, span.upperBound))
                if month >= span.lowerBound { context.stroke(vertical(from, from: 0, to: g.bottom), with: .color(.secondary.opacity(0.35)), lineWidth: 1) }
                let lead = max(from + (month >= span.lowerBound ? 6 : 0), leadingEdge + g.inset)
                let faces: [Date.FormatStyle] = [.dateTime.month(.wide), .dateTime.month(.abbreviated)]   // a sliver of a month goes unnamed: a lone letter says nothing
                for face in faces {
                    let name = context.resolve(Text(month.formatted(face)).font(.system(.subheadline, design: .serif, weight: .semibold)).foregroundStyle(.primary))
                    guard lead + name.measure(in: CGSize(width: 300, height: 30)).width <= to - 8 else { continue }
                    context.draw(name, at: CGPoint(x: lead, y: 1), anchor: .topLeading)
                    break
                }
                month = next
            }
            // Lower tier and rules: week lines from a month's zoom; day numbers once a day is wide enough, giving way to a pileup's date.
            var cursor = calendar.startOfDay(for: span.lowerBound)
            while cursor <= span.upperBound {
                let comps = calendar.dateComponents([.day, .weekday], from: cursor)
                if comps.day != 1, comps.weekday == calendar.firstWeekday, scale >= 6 {
                    context.stroke(vertical(x(cursor), from: g.axisHeight - 6, to: g.bottom), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                }
                if scale >= 24 || (scale >= 12 && comps.weekday == calendar.firstWeekday) {
                    let number = context.resolve(Text(cursor.formatted(.dateTime.day())).font(.caption2).foregroundStyle(.secondary))
                    let w = number.measure(in: CGSize(width: 40, height: 30)).width
                    let rect = CGRect(x: x(cursor) + scale / 2 - w / 2, y: g.monthTier, width: w, height: g.flagTier)
                    if !flags.contains(where: { $0.rect.insetBy(dx: -4, dy: 0).intersects(rect) }) {
                        context.draw(number, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            for flag in flags { context.draw(flag.text, at: CGPoint(x: flag.rect.midX, y: flag.rect.midY), anchor: .center) }

            // Pileups: a hairline across every band, under the date on the axis, and behind the cells so that no count is struck through.
            for collision in collisions {
                let cx = x(collision.day) + scale / 2
                context.stroke(vertical(cx, from: g.axisHeight - 2, to: g.bottom), with: .color(.primary.opacity(0.65)), lineWidth: 1)
            }
            // Bands: a baseline each, under its cells.
            for i in 0..<max(bands.count, 1) {
                context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: g.baseline(i))); p.addLine(to: CGPoint(x: size.width, y: g.baseline(i))) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            }
            // The content of the level, crossfading from the level just left.
            var alpha = 1.0
            if let previousLevel {
                let t = min(1, max(0, now.timeIntervalSince(previousLevel.at) / crossfade))
                if t < 1 { draw(previousLevel.level, alpha: 1 - t, pileupIDs: pileupIDs, in: &context); alpha = t }
            }
            draw(level, alpha: alpha, pileupIDs: pileupIDs, in: &context)
            // Today: a dashed line with its name at the foot, in the primary colour so it reads over the cells.
            let today = Date()
            if span.contains(today) {
                let tx = x(calendar.startOfDay(for: today)) + scale / 2
                context.stroke(vertical(tx, from: g.axisHeight - 2, to: g.bottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: tx, y: size.height), anchor: .bottom)
            }
        }
    }

    private func draw(_ level: Strip.Level, alpha: Double, pileupIDs: Set<UUID>, in context: inout GraphicsContext) {
        for (band, mine) in bands.enumerated() {
            let total = totalFirst && band == 0
            let shown: Strip.Level = total && level == .items ? .days : level   // the band for everything adds up; it never lists
            let cells = Strip.cells(mine, level: shown, calendar: calendar)
            switch shown {
            case .weeks, .days: drawCells(cells, band: band, alpha: alpha, in: &context)
            case .items: drawMarks(cells, band: band, alpha: alpha, pileupIDs: pileupIDs, in: &context)
            }
        }
    }

    /// One block per week or day, standing on the baseline: the accent at the load's intensity, the count inside when it fits.
    private func drawCells(_ cells: [Strip.Cell], band: Int, alpha: Double, in context: inout GraphicsContext) {
        let height = g.cellsHeight
        for cell in cells {
            let x0 = x(cell.period.start) + 1, x1 = x(cell.period.end) - 1
            let width = max(x1 - x0, 2)
            let opacity = Strip.heat(points: cell.points) * alpha * (cell.items.map(grow).max() ?? 1)
            let rect = CGRect(x: x0, y: g.baseline(band) - height, width: width, height: height)
            let shape = Path(roundedRect: rect, cornerRadius: min(4, width / 3))
            context.fill(shape, with: .color(Design.paper.opacity(alpha)))   // the paper first: a rule behind a pale cell must not show through its count
            context.fill(shape, with: .color(Design.accent.opacity(opacity)))
            if width >= 12, height >= 16 {
                let ink: Color = Strip.heat(points: cell.points) > 0.55 ? .black.opacity(0.75) : .primary
                context.draw(Text("\(cell.count)").font(.caption2.weight(.semibold)).foregroundStyle(ink.opacity(alpha)), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    /// The items themselves. In a band with room for words: one mark per item, stacked on the baseline, the heaviest
    /// named when the name does not run into the last one. In a compact band: the day's cell divided among its items,
    /// each part its own item's weight, so the band reads as it does at the other levels and nothing sits lost at the
    /// bottom of an empty row. Review items are outlines, done items grey, at either size.
    private func drawMarks(_ cells: [Strip.Cell], band: Int, alpha: Double, pileupIDs: Set<UUID>, in context: inout GraphicsContext) {
        let named = g.cellsHeight >= 50
        let room = named ? g.cellsHeight - 14 : g.cellsHeight
        let w = named ? min(scale * 0.6, 16) : max(min(scale - 4, 26), 4), gap: CGFloat = named ? 3 : 2
        let most = max(1, Int((room + gap) / ((named ? 12 : 9) + gap)))
        var lastLabelEnd: CGFloat = -.infinity
        for cell in cells {
            let cx = x(cell.period.start) + scale / 2
            let shown = Array(cell.items.prefix(most))
            let h = named ? 12 : (room - gap * CGFloat(shown.count - 1)) / CGFloat(shown.count)
            var top = g.baseline(band)
            for item in shown {
                let grown = grow(item)
                let rect = CGRect(x: cx - w / 2, y: top - h * grown, width: w, height: h * grown)
                let path = Path(roundedRect: rect, cornerRadius: min(named ? 3 : 4, w / 3))
                let color: Color = item.completed ? .secondary : Design.accent
                let opacity = (item.completed ? 0.35 : Strip.heat(points: item.points)) * alpha
                context.fill(path, with: .color(Design.paper.opacity(alpha)))   // as the cells: no rule shows through
                switch item.state {
                case .pendingReview, .awaitingDate: context.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: min(named ? 3 : 4, w / 3)), with: .color(color.opacity(max(opacity, 0.6 * alpha))), lineWidth: 1.5)
                default: context.fill(path, with: .color(color.opacity(opacity)))
                }
                top = rect.minY - gap
            }
            guard let first = cell.items.first, grow(first) >= 1 else { continue }
            let more = cell.count - shown.count
            if named {
                guard cx - 30 >= lastLabelEnd else { continue }
                let heavy = (first.points ?? 0) >= Strip.heavyPoints
                let label = Text(first.title + (cell.count > 1 ? " +\(cell.count - 1)" : "")).font(.caption2.weight(heavy ? .semibold : .regular))
                    .foregroundStyle((pileupIDs.contains(first.id) ? Design.accent : .primary).opacity((first.completed ? 0.4 : 1) * alpha))
                let resolved = context.resolve(label)
                let width = resolved.measure(in: CGSize(width: 140, height: 30)).width
                context.draw(resolved, at: CGPoint(x: cx, y: top - 1), anchor: .bottom)
                lastLabelEnd = cx + width / 2 + 6
            } else if more > 0, h >= 12, w >= 16 {   // more than the cell can divide among: the top part says how many
                context.draw(Text("+\(more)").font(.caption2.weight(.semibold)).foregroundStyle(.primary.opacity(alpha)), at: CGPoint(x: cx, y: top + gap + h / 2))
            }
        }
    }
}
