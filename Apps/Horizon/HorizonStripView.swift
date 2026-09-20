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

/// A band of the strip: everything together, a course, or the items filed under none.
private struct Band: Identifiable, Equatable {
    enum Kind: Hashable { case all, course(UUID), unfiled }
    var kind: Kind
    var name: String
    var id: Kind { kind }
}

/// Where things sit in the strip. Top to bottom: an axis of two tiers (a month's name where it begins; under it each
/// bar's own date, so nothing is ever drawn over anything), one row per band (what a roomy band has to spare, then
/// its name's line seated on its cells, then a gap), and a foot for "Today". Left to right: bars of one width, a week
/// or a day each, never narrower than the HIG's control size (`Strip.barWidth`).
private struct StripGeometry: Equatable {
    var rows: Int
    var rowHeight: CGFloat
    var labelHeight: CGFloat
    var barWidth: CGFloat
    var level: Strip.Level
    let monthTier: CGFloat = 20
    let dateTier: CGFloat = 18
    let gap: CGFloat = 8
    let foot: CGFloat = 16
    let inset: CGFloat = 20

    var axisHeight: CGFloat { monthTier + dateTier }
    var dayWidth: CGFloat { level == .weeks ? barWidth / 7 : barWidth }
    func rowTop(_ i: Int) -> CGFloat { axisHeight + rowHeight * CGFloat(i) }
    /// A band's cells stand on its baseline, and its name sits right on top of them: what a roomy band has to spare
    /// goes above the name, between the bands. A cell stops growing at 56 points, so a lone course is not a wall of colour.
    var cellsHeight: CGFloat { min(56, rowHeight - labelHeight - gap) }
    func baseline(_ i: Int) -> CGFloat { rowTop(i) + rowHeight - gap }
    /// From a row's top to its name's line.
    var labelOffset: CGFloat { rowHeight - gap - cellsHeight - labelHeight }
    var bottom: CGFloat { axisHeight + rowHeight * CGFloat(max(rows, 1)) }
    var height: CGFloat { bottom + foot }
}

/// What moves while the strip is touched: how far it has scrolled (for the overview's window and for keeping a date
/// under the fingers) and a pinch in progress. Kept out of the page's state on purpose: a scroll or a pinch touches
/// only the two small views that read these, never the page, its list, or the bars.
@MainActor @Observable private final class StripMotion {
    var offset: CGFloat = 0
    var pinch: CGFloat = 1
    var pinchAnchor: CGFloat = 0.5
    /// When two fingers were last on the strip: a bar under one of them must not take their lifting for a tap.
    var pinchedAt = Date.distantPast
    /// Where the days should scroll to, asked for by the page (opening on today, landing after a change of level) or
    /// by the overview line being scrubbed. `DaysStrip` alone reads it, and owns the scroll view's position.
    var request: ScrollRequest?

    struct ScrollRequest: Equatable {
        var x: CGFloat
        var animated: Bool
        var serial: Int
    }
    private var serial = 0
    func scroll(to x: CGFloat, animated: Bool) { serial += 1; request = ScrollRequest(x: x, animated: animated, serial: serial) }
}

/// The list's rows as of the last pass. A bar that did not change keeps the closure it was made with (`equatable`),
/// so what a tap needs to know about the page now is read from here, not captured then.
@MainActor private final class RowsBox { var ids: [UUID] = [] }

/// Everything the page draws from, worked out once per pass instead of once per use.
private struct StripData {
    var items: [StripItem] = []
    var bands: [Band] = []
    var bandItems: [[StripItem]] = []
    var span: ClosedRange<Date> = Date()...Date()
    var collisions: [Strip.Collision] = []
    var periods: [DateInterval] = []
    /// Per band, the cell of each period that has anything in it, by the period's start.
    var cells: [[Date: Strip.Cell]] = []
    var weeks: Int = 1
    /// At the days level, everything a bar draws from, so the row of them is cheap to build again.
    var bars: [Bar] = []

    struct Bar: Identifiable, Equatable {
        var id: Date { period.start }
        var period: DateInterval
        var cells: [Strip.Cell?]
        var month: StripBar.Month?
        var today: Bool
        var pileupDate: Date?
    }

    init(obligations: [Obligation], courses: [Course], level: Strip.Level, calendar: Calendar) {
        items = obligations.compactMap { o in
            guard let due = o.due else { return nil }
            return StripItem(id: o.id, title: o.title, courseID: o.course?.id, courseCode: o.course?.code ?? "", courseName: o.course?.title, due: due, dueHasTime: o.dueHasTime,
                             points: o.pointsAtStake, state: o.state, completed: o.completedAt != nil)
        }
        // A band for everything when there are several to add up, one per course with items, one for items filed under no course.
        let known = Set(courses.map(\.id))
        let byCourse = Dictionary(grouping: items) { $0.courseID.flatMap { known.contains($0) ? $0 : nil } }
        bands = courses.filter { byCourse[$0.id] != nil }.map { Band(kind: .course($0.id), name: $0.displayName) }
        bandItems = courses.compactMap { byCourse[$0.id] }
        if let loose = byCourse[nil] { bands.append(Band(kind: .unfiled, name: "Unfiled")); bandItems.append(loose) }
        if Strip.showsTotal(bands: bands.count) { bands.insert(Band(kind: .all, name: "All courses"), at: 0); bandItems.insert(items, at: 0) }
        span = Strip.span(termStarts: courses.compactMap(\.termStart), termEnds: courses.compactMap(\.termEnd), items: items, now: Date(), calendar: calendar)
        collisions = Strip.collisions(items, calendar: calendar)
        periods = Strip.periods(in: span, level: level, calendar: calendar)
        weeks = level == .weeks ? periods.count : Strip.periods(in: span, level: .weeks, calendar: calendar).count
        cells = bandItems.map { mine in Dictionary(uniqueKeysWithValues: Strip.cells(mine, level: level, calendar: calendar).map { ($0.period.start, $0) }) }
        guard level == .days else { return }
        let today = calendar.startOfDay(for: Date())
        let pileups = Dictionary(collisions.map { ($0.day, $0.day) }, uniquingKeysWith: { a, _ in a })
        bars = periods.map { period in
            // A month's name where it begins; and since nine days are across a phone and a month's first may be weeks away, each week's first day says the month again, quietly.
            let components = calendar.dateComponents([.day, .weekday], from: period.start)
            let month: StripBar.Month? = components.day == 1 ? .init(name: period.start.formatted(.dateTime.month(.wide)), begins: true)
                : components.weekday == calendar.firstWeekday ? .init(name: period.start.formatted(.dateTime.month(.abbreviated)), begins: false) : nil
            return Bar(period: period, cells: cells.map { $0[period.start] }, month: month, today: period.start == today, pileupDate: pileups[period.start])
        }
    }
}

/// SPEC §6.2: one continuous strip of the term, one band per course, and above them (when there are several) a band
/// for everything, where the shape of the term shows. Load is colour, not size: the accent deepens with the points
/// at stake, and a cell carries its count. Days where heavy items pile up are called out.
///
/// Two levels for two intents. The semester is for reading: the whole term across the screen, as dense as that
/// makes it, drawn once. Its bars are not controls; the whole of it is one, and a touch means "look closer here": the
/// strip goes to days at that week, with the week chosen, so the list under it is that week's work. Days are for
/// working: a bar is a day, a real button the full height of the strip and never narrower than the HIG's control size
/// (44 points for a finger, 28 for a pointer), so the strip scrolls, and a line above it keeps the whole term in
/// view with a window on where the strip is. A pinch goes between the two, keeping the date under the fingers.
///
/// The page is one scroll (HIG: no competing scroll regions; the days scroll sideways inside it): the range, the
/// header, the strip, then the list. Built to cost nothing at rest and little in motion: the overview is one canvas
/// the size of the screen, drawn when the term changes; the days are bars drawn once each and only moved by the
/// scroll; the page's own state never changes while a finger moves (`StripMotion`).
struct HorizonStripView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.due != nil }, sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var level: Strip.Level = MainTabs.debugFlag("--zoom-days") ? .days : .weeks
    @State private var motion = StripMotion()
    @State private var placed = false                // the strip opens on today, once
    @State private var landing: (date: Date, fraction: CGFloat)?   // where a change of level should put which date, once the new bars exist
    @State private var rows = RowsBox()
    @State private var chosen: DateInterval?         // the week (from the overview) or the day (from its bar) whose work the list shows
    @State private var hover: DateInterval?          // macOS: the week or day under the pointer reads in the header without a click
    @State private var editing: Obligation?
    @State private var lingering = Lingering()       // just checked off under "Coming up": crossed off for a moment before it leaves, so a slip can be undone
    @State private var listHeadY: CGFloat = 0        // where the list begins on the screen, to know when a chosen period's items are under the fold
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 16
    private let calendar = Calendar.current
    /// What sits above the strip on the page (the range, the header, the overview), and what the list needs to show
    /// its head (its kicker and two rows): the strip's bands share the rest.
    private let chromeAbove: CGFloat = 230, listHead: CGFloat = 170
    #if os(macOS)
    private let touch = false
    #else
    private let touch = true
    #endif

    private func geometry(in size: CGSize, data: StripData) -> StripGeometry {
        let rows = max(data.bands.count, 1)
        let spare = Double(size.height - chromeAbove - listHead) - 38 - 16   // less the axis and the foot
        let row = CGFloat(Strip.rowHeight(rows: rows, available: spare, minimum: Double(labelHeight) + 28))
        let bar = Strip.barWidth(level, width: Double(size.width) - 40, weeks: data.weeks, minimumBar: Strip.minimumBar(touch: touch))
        return StripGeometry(rows: rows, rowHeight: row, labelHeight: labelHeight, barWidth: CGFloat(bar), level: level)
    }

    /// What a period holds, of these items: a week's or a day's worth as one cell.
    private func cell(for period: DateInterval?, among items: [StripItem]) -> Strip.Cell? {
        guard let period else { return nil }
        let mine = items.filter { $0.due >= period.start && $0.due < period.end }.sorted { ($0.points ?? 0) > ($1.points ?? 0) }
        return Strip.Cell(period: period, items: mine, points: mine.filter { !$0.completed }.reduce(0) { $0 + ($1.points ?? 0) })
    }

    /// Under the strip: the chosen period's items, else what is coming up from today; in time order, heavier first
    /// on a tie, and what is done last, once its moment is over.
    private func listed(_ data: StripData) -> [Obligation] {
        let byID = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0) })
        let shown: [StripItem]
        if let picked = cell(for: chosen, among: data.items) { shown = picked.items } else {
            let today = calendar.startOfDay(for: Date())
            shown = data.items.filter { $0.due >= today && (!$0.completed || lingering.contains($0.id)) }
        }
        let settled: (StripItem) -> Bool = { $0.completed && !lingering.contains($0.id) }
        return shown.sorted { settled($0) != settled($1) ? !settled($0) : $0.due != $1.due ? $0.due < $1.due : ($0.points ?? 0) > ($1.points ?? 0) }.compactMap { byID[$0.id] }
    }

    var body: some View {
        let data = StripData(obligations: obligations, courses: courses, level: level, calendar: calendar)
        let listed = listed(data)
        let _ = rows.ids = listed.map(\.id)
        PageStack {
            GeometryReader { geo in
                let g = geometry(in: geo.size, data: data)
                let contentWidth = CGFloat(data.periods.count) * g.barWidth + g.inset * 2
                ScrollViewReader { page in
                    List {
                        Section {
                            #if os(iOS)
                            RangeTabs(selection: Binding(get: { level }, set: { setLevel($0, data: data, g: g, width: geo.size.width) }))
                                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            #endif
                            StripHeader(level: level, cell: cell(for: hover ?? chosen, among: data.items), total: data.items.count, collisions: data.collisions)
                                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 10, trailing: 20))
                            if contentWidth > geo.size.width + 1 {   // the term does not fit across: a line that shows all of it, and where the strip is in it
                                TermOverview(data: data, motion: motion, contentWidth: contentWidth, viewport: geo.size.width, calendar: calendar)
                                    .transition(.opacity)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 20))
                            }
                            strip(data, g, width: geo.size.width) { period in
                                guard Date().timeIntervalSince(motion.pinchedAt) > 0.4 else { return }   // two fingers lifting are not a tap
                                if level == .weeks {   // the overview: look closer here, with the week chosen so the list is its work
                                    chosen = period
                                    landing = (period.start, (g.inset + 22) / max(geo.size.width, 1))   // the week's first day at the leading margin
                                    level = .days
                                } else {
                                    chosen = chosen == period ? nil : period   // the same day again lets it go
                                }
                                if chosen != nil { reveal(page, viewportBottom: geo.frame(in: .global).maxY) }
                            }
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
                            if listed.isEmpty { Text(chosen == nil ? "Nothing coming up." : "Nothing due.").foregroundStyle(.secondary).id("nothing") }
                        } header: {
                            listHeader(data).onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { listHeadY = $0 }
                        }
                        .onPaper()
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 1)
                    .paper()
                    .animation(.default, value: chosen)
                    .animation(.default, value: level)
                    .animation(.default, value: listed.map(\.id))
                }
                .overlay {
                    if data.items.isEmpty {
                        ScrollView {
                            EditorialEmpty(title: "Nothing on the horizon.", deck: "Add a syllabus or a schedule and the term appears here as one strip: its weeks, and its days when you look closer.") {
                                ImportMenu().buttonStyle(.borderedProminent)
                            }
                            .padding(.horizontal, 20)
                        }
                        .background(Design.paper)
                    }
                }
                .onChange(of: data.periods.isEmpty, initial: true) { _, empty in   // opens on today, a little in from the leading edge: what is ahead matters most
                    guard !empty, !placed else { return }
                    placed = true
                    if level == .days { landing = (Date(), 0.2); land(data, g, width: geo.size.width) }   // DEBUG `--zoom-days`: the days open on today
                    if MainTabs.debugOnce("--scrub-week"), let heavy = data.collisions.first?.day ?? data.items.first?.due {   // DEBUG: a week chosen from the overview without a tap
                        chosen = Strip.period(containing: heavy, level: .weeks, calendar: calendar)
                        landing = (chosen!.start, 0.1); level = .days
                    }
                    if MainTabs.debugOnce("--check-first-coming-up"), let first = listed.first {   // DEBUG: a check without a tap, to see the row linger and leave
                        Task { try? await Task.sleep(for: .seconds(2)); mark(first.id, true) }
                    }
                }
            }
            .background(Design.paper.ignoresSafeArea())
            .navigationTitle("Horizon")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .principal) {   // the range as a segmented control in the toolbar, where a Mac keeps a view's options
                    Picker("Range", selection: Binding(get: { level }, set: { landing = (chosen?.start ?? Date(), 0.2); level = $0 })) {   // the chosen period, else today, a little in from the leading edge
                        Text("Semester").tag(Strip.Level.weeks)
                        Text("Days").tag(Strip.Level.days)
                    }
                    .pickerStyle(.segmented)
                    .help("The whole term to read, or its days to work from")
                }
            }
            #endif
            .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        }
    }

    /// The strip at either level, and over it the bands' names, which stay put. A name has its own line above its
    /// band's cells, so it never covers a cell; beside it, while a period is chosen, what that course has in it.
    private func strip(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (DateInterval) -> Void) -> some View {
        Group {
            if level == .weeks { overview(data, g, width: width, choose: choose) } else { days(data, g, width: width, choose: choose) }
        }
        .onChange(of: level) { _, new in   // the strip now holds the new level: the date that was held goes back where it was
            if new == .weeks { chosen = nil; landing = nil }   // the semester is for reading: what was picked out among the days is let go, and the list is what is coming up
            motion.pinch = new == .days ? 0.94 : 1.06   // the new level settles into place: the step reads as a zoom
            withAnimation(.spring(duration: 0.4)) { motion.pinch = 1 }
            if new == .days { land(data, g, width: width) }
        }
        .overlay(alignment: .topLeading) { bandLabels(data, g) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(data))
    }

    /// The semester, to read: the whole term across the screen in one canvas, drawn when the term changes and not
    /// otherwise. It does not scroll, and its bars are not controls: the whole of it is one, and a touch means "look
    /// closer here" (`Strip.week(at:)` forgives a miss toward a week with something in it). A pinch out does the same
    /// where the fingers are, choosing nothing.
    private func overview(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (DateInterval) -> Void) -> some View {
        let week: (CGFloat) -> DateInterval? = { x in
            Strip.week(at: Double(x - g.inset), barWidth: Double(g.barWidth), weeks: data.periods.count,
                       hasItems: { i in data.cells.contains { $0[data.periods[i].start] != nil } }, reach: Strip.minimumBar(touch: touch) / 2).map { data.periods[$0] }
        }
        return Stretch(motion: motion) {
            OverviewCanvas(data: data, g: g, chosen: hover, calendar: calendar)
                .frame(width: width, height: g.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in if let period = week(location.x) { choose(period) } }
        #if os(macOS)
        .onContinuousHover { phase in   // the pointer reads a week into the header; a click looks closer
            switch phase {
            case .active(let point): hover = week(point.x)
            case .ended: hover = nil
            }
        }
        #endif
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                motion.pinchedAt = Date()
                motion.pinchAnchor = min(max(value.startLocation.x / max(width, 1), 0), 1)
                motion.pinch = min(max(1 + (value.magnification - 1) * 0.2, 0.9), 1.1)
            }
            .onEnded { value in
                motion.pinchedAt = Date()
                if value.magnification > 1.25 { setLevel(.days, data: data, g: g, width: width, anchorX: value.startLocation.x) }
                withAnimation(.spring(duration: 0.35)) { motion.pinch = 1 }
            })
        .accessibilityChildren {   // VoiceOver's path through the term: each week with something in it, and looking closer as its action
            ForEach(data.periods.filter { p in data.cells.contains { $0[p.start] != nil } }, id: \.start) { period in
                let cell = cell(for: period, among: data.items)
                Rectangle()
                    .accessibilityLabel("Week of \(period.start.formatted(.dateTime.month(.wide).day()))")
                    .accessibilityValue("\(cell?.count ?? 0) item\(cell?.count == 1 ? "" : "s"), \((cell?.points ?? 0).formatted(.number.precision(.fractionLength(0...1)))) percent of grades at stake")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows the week's days")
                    .accessibilityAction { choose(period) }
            }
        }
    }

    /// Puts the date that was held (`landing`) where it was on the screen, now that the days are up. Bars are one
    /// width, so where a date sits is arithmetic; an offset lands exactly where an id, in a lazy row whose bars do not
    /// exist yet, did not.
    private func land(_ data: StripData, _ g: StripGeometry, width: CGFloat) {
        guard let landing, let index = data.periods.firstIndex(where: { $0.start == calendar.startOfDay(for: landing.date) }) else { return }
        self.landing = nil
        let x = g.inset + (CGFloat(index) + 0.5) * g.barWidth - landing.fraction * width
        let target = max(0, min(x, CGFloat(data.periods.count) * g.barWidth + g.inset * 2 - width))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))   // once the scroll view has the row's width
            motion.scroll(to: target, animated: false)
        }
    }

    /// The days, to work from (`DaysStrip`).
    private func days(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (DateInterval) -> Void) -> some View {
        DaysStrip(bars: data.bars, totalFirst: data.bands.first?.kind == .all, g: g, width: width, motion: motion, lit: hover ?? chosen, calendar: calendar,
                  choose: choose, hover: { period, inside in hover = inside ? period : (hover == period ? nil : hover) },
                  pinchedIn: { anchorX in setLevel(.weeks, data: data, g: g, width: width, anchorX: anchorX) })
    }

    /// The bands' names, in the page's margin, each on the line above its cells; while a bar is chosen, a course's
    /// line ends with what it has there. The paper behind the words lets the strip's rules pass under them.
    private func bandLabels(_ data: StripData, _ g: StripGeometry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.bands.enumerated()), id: \.element.id) { index, band in
                HStack(spacing: 8) {
                    Text(band.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(band.kind == .all ? .primary : .secondary)
                        .padding(.trailing, 6).background(Design.paper)
                    Spacer(minLength: 0)
                    if band.kind != .all, let cell = cell(for: hover ?? chosen, among: data.bandItems[index]), cell.count > 0 {
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
        .animation(.default, value: hover ?? chosen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Over the list: what it is a list of, and, for a chosen bar, the way back to what is coming up.
    private func listHeader(_ data: StripData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let chosen {
                Kicker(Self.isWeek(chosen) ? "Week of \(chosen.start.formatted(.dateTime.month(.abbreviated).day()))" : chosen.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                Spacer()
                Button("Coming Up", systemImage: "xmark.circle.fill") { self.chosen = nil }
                    .labelStyle(.titleAndIcon).font(.caption.weight(.medium)).buttonStyle(.borderless)
                    .accessibilityHint("Lists what is coming up instead")
            } else {
                Kicker("Coming up")
                Spacer()
            }
        }
    }

    /// A chosen period is a week when it runs longer than a day (from the overview), else a day (from its bar).
    static func isWeek(_ period: DateInterval) -> Bool { period.duration > 36 * 3600 }

    /// The date at a point along the strip: the bar's own at the days level, the day within the week on the overview.
    private func date(atContentX x: CGFloat, data: StripData, g: StripGeometry) -> Date {
        let index = min(max(Int((x - g.inset) / g.barWidth), 0), data.periods.count - 1)
        let period = data.periods[index]
        guard g.level == .weeks else { return period.start }
        let day = min(max(Int((x - g.inset - CGFloat(index) * g.barWidth) / g.dayWidth), 0), 6)
        return calendar.date(byAdding: .day, value: day, to: period.start) ?? period.start
    }

    /// The semester to days or back, keeping a date where it was on the screen: the one under the fingers for a
    /// pinch; for the range's stops the chosen period's, else the one in the middle, brought to the middle.
    private func setLevel(_ new: Strip.Level, data: StripData, g: StripGeometry, width: CGFloat, anchorX: CGFloat? = nil) {
        guard new != level, !data.periods.isEmpty else { return }
        if let anchorX {   // a pinch: the date under the fingers stays under them
            landing = (date(atContentX: anchorX, data: data, g: g), min(max((anchorX - (level == .days ? motion.offset : 0)) / max(width, 1), 0), 1))
        } else {           // the range's stop: the chosen period, else today, a little in from the leading edge (what is ahead matters most)
            landing = (chosen?.start ?? Date(), 0.2)
        }
        level = new   // `onChange(of: level)` lands the held date once the days are up
    }

    /// A tap has chosen a bar: if the head of its list is under the fold, the page moves just far enough to show its
    /// first rows (HIG: scroll automatically only as much as necessary).
    private func reveal(_ page: ScrollViewProxy, viewportBottom: CGFloat) {
        guard listHeadY + listHead > viewportBottom + 8 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))   // once the list holds the period's items
            let ids = rows.ids
            if ids.isEmpty { withAnimation(.snappy) { page.scrollTo("nothing", anchor: .bottom) } }
            else { let id = ids[min(1, ids.count - 1)]; withAnimation(.snappy) { page.scrollTo(id, anchor: .bottom) } }   // the second row at the foot: two rows of the period in view
        }
    }

    /// A check under "Coming up" stays on the page for a moment, crossed off, then the row leaves; unchecked, it stays.
    private func mark(_ id: UUID, _ done: Bool) {
        lingering.mark(id, done: done)
        Task { await model.setCompleted(id, done) }
    }

    private func accessibilitySummary(_ data: StripData) -> String {
        let names = data.bands.filter { $0.kind != .all }.map(\.name).joined(separator: ", ")
        return "Semester strip by \(level == .weeks ? "week" : "day"), \(data.items.count) obligations across \(names). \(data.collisions.isEmpty ? "No pileups." : "\(data.collisions.count) pileups.")"
    }
}

/// The days, to work from: a lazy row of bars scrolling sideways, each a button. The scroll view's position lives here
/// and nowhere else: it is by offset only, and neither the system's writes to it as a finger scrolls nor the
/// overview line's as it is scrubbed re-evaluate anything but this row, whose bars are already worked out
/// (`StripData.Bar`) and skipped when equal. (A position that tracked the bar in view, kept in the page's state, was
/// rewritten bar by bar as the strip moved; each write re-ran the page and stopped the scroll's inertia dead.)
private struct DaysStrip: View {
    let bars: [StripData.Bar]
    let totalFirst: Bool
    let g: StripGeometry
    let width: CGFloat
    let motion: StripMotion
    /// The period chosen, or under the pointer: its days' bars stand on a soft ground.
    let lit: DateInterval?
    let calendar: Calendar
    var choose: (DateInterval) -> Void
    var hover: (DateInterval, Bool) -> Void
    /// A pinch in, with where the fingers were along the row: back to the semester.
    var pinchedIn: (CGFloat) -> Void
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Stretch(motion: motion) {
                LazyHStack(spacing: 0) {
                    ForEach(bars) { bar in
                        StripBar(bar: bar, totalFirst: totalFirst, g: g, chosen: lit.map { bar.period.start >= $0.start && bar.period.start < $0.end } ?? false,
                                 choose: { choose(bar.period) }, hover: { hover(bar.period, $0) })
                            .equatable()
                    }
                }
                .padding(.horizontal, g.inset)
                .frame(height: g.height)
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in   // the row gives a little under the fingers; the level changes when they let go
                    motion.pinchedAt = Date()
                    motion.pinchAnchor = min(max((value.startLocation.x - motion.offset) / max(width, 1), 0), 1)
                    motion.pinch = min(max(1 + (value.magnification - 1) * 0.2, 0.9), 1.1)
                }
                .onEnded { value in
                    motion.pinchedAt = Date()
                    if value.magnification < 0.8 { pinchedIn(value.startLocation.x) }
                    withAnimation(.spring(duration: 0.35)) { motion.pinch = 1 }
                })
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in motion.offset = offset }
        .onChange(of: motion.request) { _, request in
            guard let request else { return }
            if request.animated { withAnimation(.snappy) { position.scrollTo(x: request.x) } } else { position.scrollTo(x: request.x) }
        }
    }
}

/// Applies a pinch in progress to the row of bars: a stretch of the layer, nothing redrawn. Alone in reading
/// `StripMotion.pinch`, so a pinch re-evaluates this and nothing else.
private struct Stretch<Content: View>: View {
    let motion: StripMotion
    @ViewBuilder var content: Content
    var body: some View {
        content.scaleEffect(x: motion.pinch, y: 1, anchor: UnitPoint(x: motion.pinchAnchor, y: 0.5))
    }
}

/// The semester in one canvas the width of the screen: a cell per week per band, as deep as its load, its count
/// inside when it fits. An axis in two tiers, so nothing is drawn over anything: the months above (shortened to fit,
/// never to one letter), the pileups' dates below in the accent (of two a few points apart, the first is named and
/// both are ruled). Rules run behind the cells, and a cell is painted on the paper first, so no count is struck
/// through. Today is a dashed line with its name at the foot. Drawn when the term changes; nothing here moves.
private struct OverviewCanvas: View {
    let data: StripData
    let g: StripGeometry
    /// macOS: the week under the pointer.
    let chosen: DateInterval?
    let calendar: Calendar

    private func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)) }
    }

    var body: some View {
        Canvas { context, size in
            guard let origin = data.periods.first?.start else { return }
            let x: (Date) -> CGFloat = { g.inset + CGFloat($0.timeIntervalSince(origin) / (7 * 86_400)) * g.barWidth }
            let end = g.inset + CGFloat(data.periods.count) * g.barWidth

            if let chosen {   // the week under the pointer: a soft ground behind each band's cells
                for band in 0..<max(data.bands.count, 1) {
                    context.fill(Path(CGRect(x: x(chosen.start), y: g.baseline(band) - g.cellsHeight, width: g.barWidth, height: g.cellsHeight)), with: .color(.primary.opacity(0.1)))
                }
            }
            // Upper tier: each month where it begins, in the widest spelling its room allows; the first, partial one from the strip's start.
            var month = calendar.dateInterval(of: .month, for: origin)?.start ?? origin
            while x(month) < end {
                let next = calendar.date(byAdding: .month, value: 1, to: month) ?? month.addingTimeInterval(31 * 86_400)
                let from = max(x(month), g.inset), to = min(x(next), end)
                if month >= origin { context.stroke(vertical(from, from: 0, to: g.bottom), with: .color(.secondary.opacity(0.35)), lineWidth: 1) }
                for face in [Date.FormatStyle.dateTime.month(.wide), .dateTime.month(.abbreviated)] {
                    let name = context.resolve(Text(month.formatted(face)).font(.system(.subheadline, design: .serif, weight: .semibold)).foregroundStyle(.primary))
                    guard name.measure(in: CGSize(width: 300, height: 30)).width <= to - from - 10 else { continue }
                    context.draw(name, at: CGPoint(x: from + (month >= origin ? 6 : 0), y: 1), anchor: .topLeading)
                    break
                }
                month = next
            }
            // Lower tier: the pileups' dates, and their rules (behind the cells).
            var lastFlagEnd: CGFloat = -.infinity
            for collision in data.collisions {
                let cx = x(collision.day) + g.dayWidth / 2
                context.stroke(vertical(cx, from: g.axisHeight - 2, to: g.bottom), with: .color(.primary.opacity(0.65)), lineWidth: 1)
                let flag = context.resolve(Text(collision.day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accent))
                let w = flag.measure(in: CGSize(width: 120, height: 30)).width
                let fx = min(max(cx, g.inset + w / 2), size.width - w / 2 - 2)
                guard fx - w / 2 >= lastFlagEnd + 6 else { continue }
                context.draw(flag, at: CGPoint(x: fx, y: g.monthTier + g.dateTier / 2), anchor: .center)
                lastFlagEnd = fx + w / 2
            }
            // Bands: a baseline each, and a cell per week with anything in it.
            for band in 0..<max(data.bands.count, 1) {
                let base = g.baseline(band)
                context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: base)); p.addLine(to: CGPoint(x: size.width, y: base)) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                guard band < data.cells.count else { continue }
                for (index, period) in data.periods.enumerated() {
                    guard let cell = data.cells[band][period.start] else { continue }
                    let rect = CGRect(x: g.inset + CGFloat(index) * g.barWidth + 1, y: base - g.cellsHeight, width: max(g.barWidth - 2, 2), height: g.cellsHeight)
                    let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.width / 3))
                    context.fill(shape, with: .color(Design.paper))
                    context.fill(shape, with: .color(Design.accent.opacity(Strip.heat(points: cell.points))))
                    if rect.width >= 12 {
                        let ink: Color = Strip.heat(points: cell.points) > 0.55 ? .black.opacity(0.75) : .primary
                        context.draw(Text("\(cell.count)").font(.caption2.weight(.semibold)).foregroundStyle(ink), at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }
            // Today, over the cells so it is never lost in a busy week.
            let today = calendar.startOfDay(for: Date())
            if today >= origin, x(today) < end {
                let tx = x(today) + g.dayWidth / 2
                context.stroke(vertical(tx, from: g.axisHeight - 2, to: g.bottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: tx, y: size.height), anchor: .bottom)
            }
        }
    }
}

/// One bar of the days: a day, the full height of the strip, and a button (HIG: a control is at least 44 points
/// across for a finger, 28 for a pointer; `Strip.barWidth` sees to the width, the strip's height to the rest).
/// Drawn once and then only moved by the scroll; equal inputs mean it is not drawn again.
private struct StripBar: View, Equatable {
    /// A month's name on the upper tier: where the month begins (with a rule), or a reminder of it on a week's first day.
    struct Month: Equatable { var name: String; var begins: Bool }

    let bar: StripData.Bar
    let totalFirst: Bool
    let g: StripGeometry
    let chosen: Bool
    var choose: () -> Void
    var hover: (Bool) -> Void

    nonisolated static func == (a: StripBar, b: StripBar) -> Bool {
        a.bar == b.bar && a.totalFirst == b.totalFirst && a.g == b.g && a.chosen == b.chosen
    }

    private var summary: String {
        let cells = bar.cells
        let cell = totalFirst ? cells.first ?? nil : cells.compactMap { $0 }.first
        let count = totalFirst ? cell?.count ?? 0 : cells.compactMap { $0?.count }.reduce(0, +)
        let points = totalFirst ? cell?.points ?? 0 : cells.compactMap { $0?.points }.reduce(0, +)
        return count == 0 ? "Nothing due" : "\(count) item\(count == 1 ? "" : "s"), \(points.formatted(.number.precision(.fractionLength(0...1)))) percent of grades at stake\(bar.pileupDate == nil ? "" : ", a pileup")"
    }

    var body: some View {
        Button(action: choose) {
            Canvas { context, size in draw(&context, size) }
                .frame(width: g.barWidth, height: g.height)
                .overlay(alignment: .topLeading) {   // a month's name may run on past its bar; nothing else is on its tier
                    if let month = bar.month {
                        Text(month.name).font(.system(.subheadline, design: .serif, weight: .semibold)).foregroundStyle(month.begins ? .primary : .secondary).fixedSize()
                            .offset(x: 6, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover(perform: hover)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.period.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(summary)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHidden(bar.cells.allSatisfy { $0 == nil })   // VoiceOver steps through the days with something in them
    }

    private func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)) }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        // Chosen: a soft ground behind each band's cells, edge to edge, so the days of a chosen week read as one stretch
        // and the bands' names, on their own lines, stay on plain paper.
        if chosen {
            for band in 0..<max(bar.cells.count, 1) {
                context.fill(Path(CGRect(x: 0, y: g.baseline(band) - g.cellsHeight, width: size.width, height: g.cellsHeight)), with: .color(.primary.opacity(0.1)))   // the cells' own room: a name's line above it is not touched
            }
        }
        // Rules: the day's own leading edge, a month's beginning, a pileup. All behind the cells.
        context.stroke(vertical(0, from: g.axisHeight - 6, to: g.bottom), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        if bar.month?.begins == true { context.stroke(vertical(0, from: 0, to: g.bottom), with: .color(.secondary.opacity(0.35)), lineWidth: 1) }
        if bar.pileupDate != nil { context.stroke(vertical(size.width / 2, from: g.axisHeight - 2, to: g.bottom), with: .color(.primary.opacity(0.65)), lineWidth: 1) }
        // The lower tier: the day's own date, or in the accent the date of the pileup it is.
        let date: Text = if let pileup = bar.pileupDate {
            Text(pileup.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accent)
        } else {
            Text(bar.period.start.formatted(.dateTime.weekday(.abbreviated).day())).font(.caption2.weight(bar.today ? .bold : .regular)).foregroundStyle(bar.today ? .primary : .secondary)
        }
        context.draw(date, at: CGPoint(x: size.width / 2, y: g.monthTier + g.dateTier / 2), anchor: .center)
        // Bands: a baseline each, and what the day holds standing on it.
        for (band, cell) in bar.cells.enumerated() {
            let base = g.baseline(band)
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: base)); p.addLine(to: CGPoint(x: size.width, y: base)) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            guard let cell else { continue }
            let rect = CGRect(x: 1.5, y: base - g.cellsHeight, width: size.width - 3, height: g.cellsHeight)
            if totalFirst && band == 0 { drawCell(cell, in: rect, &context) } else { drawItems(cell, in: rect, &context) }
        }
        // Today: a dashed line with its name at the foot, in the primary colour so it reads over the cells.
        if bar.today {
            let x = size.width / 2
            context.stroke(vertical(x, from: g.axisHeight - 2, to: g.bottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: x, y: size.height), anchor: .bottom)
        }
    }

    /// One block for the period: the accent at the load's intensity, on the paper (so no rule shows through a pale
    /// cell), its count inside.
    private func drawCell(_ cell: Strip.Cell, in rect: CGRect, _ context: inout GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: 5)
        context.fill(shape, with: .color(Design.paper))
        context.fill(shape, with: .color(Design.accent.opacity(Strip.heat(points: cell.points))))
        let ink: Color = Strip.heat(points: cell.points) > 0.55 ? .black.opacity(0.75) : .primary
        context.draw(Text("\(cell.count)").font(.caption.weight(.semibold)).foregroundStyle(ink), at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// A day in a course's band: its cell divided among its items, each part its own item's weight; a review item is
    /// an outline, a done one grey. More than the cell can divide among: the top part says how many.
    private func drawItems(_ cell: Strip.Cell, in rect: CGRect, _ context: inout GraphicsContext) {
        let gap: CGFloat = 2
        let most = max(1, Int((rect.height + gap) / (9 + gap)))
        let shown = Array(cell.items.prefix(most))
        let h = (rect.height - gap * CGFloat(shown.count - 1)) / CGFloat(shown.count)
        var top = rect.maxY
        for item in shown {
            let part = CGRect(x: rect.minX, y: top - h, width: rect.width, height: h)
            let shape = Path(roundedRect: part, cornerRadius: min(5, h / 2))
            let color: Color = item.completed ? .secondary : Design.accent
            let opacity = item.completed ? 0.35 : Strip.heat(points: item.points)
            context.fill(shape, with: .color(Design.paper))
            switch item.state {
            case .pendingReview, .awaitingDate: context.stroke(Path(roundedRect: part.insetBy(dx: 0.75, dy: 0.75), cornerRadius: min(5, h / 2)), with: .color(color.opacity(max(opacity, 0.6))), lineWidth: 1.5)
            default: context.fill(shape, with: .color(color.opacity(opacity)))
            }
            top = part.minY - gap
        }
        let more = cell.count - shown.count
        if more > 0, h >= 12 { context.draw(Text("+\(more)").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: rect.midX, y: top + gap + h / 2)) }
    }
}

/// The whole term in one line above the days, and their scroll bar: a tick per week, the accent as deep as the
/// week's load, today, the pileups, and a window on what the days are showing. Drag along it and the days follow the
/// finger, the window under it; a tap goes there at once. Only the window moves with a scroll; the line itself is
/// drawn when the term changes. It takes a control's 44 points of height, though the line in it is slight.
private struct TermOverview: View {
    let data: StripData
    let motion: StripMotion
    let contentWidth: CGFloat
    let viewport: CGFloat
    let calendar: Calendar
    @State private var scrubbing = false

    /// Where the days scroll to for a touch at `x` along a line `width` wide: the window's middle under the finger.
    private func offset(for x: CGFloat, width: CGFloat) -> CGFloat {
        let span = max(contentWidth - 40, 1)
        return max(0, min(x / max(width, 1) * span + 20 - viewport / 2, contentWidth - viewport))
    }

    var body: some View {
        GeometryReader { geo in
            let weeks = Strip.periods(in: data.span, level: .weeks, calendar: calendar)
            let loads = Dictionary(uniqueKeysWithValues: Strip.cells(data.items, level: .weeks, calendar: calendar).map { ($0.period.start, $0.points) })
            let total = weeks.last.map { $0.end.timeIntervalSince(weeks[0].start) } ?? 1
            let origin = weeks.first?.start ?? data.span.lowerBound
            let place: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(origin) / total) * geo.size.width }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let w = size.width / CGFloat(max(weeks.count, 1))
                    for (i, week) in weeks.enumerated() {
                        let rect = CGRect(x: CGFloat(i) * w + 0.5, y: 17, width: max(w - 1, 1), height: 10)
                        let load = loads[week.start]
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(load == nil ? Color.secondary.opacity(0.12) : Design.accent.opacity(Strip.heat(points: load))))
                    }
                    for collision in data.collisions {   // a pileup: a tick above its week
                        context.fill(Path(CGRect(x: place(collision.day) - 0.5, y: 11, width: 1.5, height: 5)), with: .color(Design.accent))
                    }
                    let today = place(Date())
                    context.stroke(Path { p in p.move(to: CGPoint(x: today, y: 13)); p.addLine(to: CGPoint(x: today, y: 31)) }, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                OverviewWindow(motion: motion, contentWidth: contentWidth, viewport: viewport, width: geo.size.width, held: scrubbing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)   // a scroll bar: the touch is its own from the first point, as a slider's is
                .onChanged { value in
                    if abs(value.translation.width) > 3 { scrubbing = true }
                    if scrubbing { motion.scroll(to: offset(for: value.location.x, width: geo.size.width), animated: false) }
                }
                .onEnded { value in
                    if !scrubbing { motion.scroll(to: offset(for: value.location.x, width: geo.size.width), animated: true) }   // a tap: there at once
                    scrubbing = false
                })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Term")
        .accessibilityHint("Moves the days along the term")
        .accessibilityAdjustableAction { direction in   // VoiceOver's scroll bar: a screenful of days either way
            let step = direction == .increment ? viewport * 0.8 : -viewport * 0.8
            motion.scroll(to: max(0, min(motion.offset + step, contentWidth - viewport)), animated: true)
        }
    }
}

/// The part of the term the days are showing, on the overview: the scroll bar's thumb. Alone in reading
/// `StripMotion.offset`, so a scroll redraws this and nothing else.
private struct OverviewWindow: View {
    let motion: StripMotion
    let contentWidth: CGFloat
    let viewport: CGFloat
    let width: CGFloat
    /// A finger is on it.
    let held: Bool

    var body: some View {
        let span = max(contentWidth - 40, 1)
        let lead = min(max((motion.offset - 20) / span, 0), 1), share = min(viewport / span, 1)
        let thumb = max(share * width, 14)
        RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(held ? 0.9 : 0.55), lineWidth: held ? 2 : 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(held ? 0.08 : 0)))
            .frame(width: thumb, height: 22)
            .offset(x: min(lead * width, width - thumb), y: 11)
            .animation(.snappy(duration: 0.2), value: held)
    }
}

/// The range's two stops as a row of tabs with a sliding accent underline, the way a magazine names its sections.
private struct RangeTabs: View {
    @Binding var selection: Strip.Level
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(Strip.Level.allCases, id: \.self) { stop in
                    let selected = stop == selection
                    Button { withAnimation(.snappy) { selection = stop } } label: {
                        VStack(spacing: 8) {
                            Text(stop == .weeks ? "Semester" : "Days").font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(selected ? .primary : .secondary)
                            ZStack {
                                Color.clear.frame(height: 2)
                                if selected { Rectangle().fill(Design.accent).frame(height: 2).matchedGeometryEffect(id: "underline", in: underline) }
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)   // HIG: a control is at least 44 points either way
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

/// The chosen week or day, or the semester at a glance: a kicker, a two-line deck, one line under it. Always the same
/// height, so the strip below never moves; the accent marks a pileup.
private struct StripHeader: View {
    let level: Strip.Level
    let cell: Strip.Cell?
    let total: Int
    let collisions: [Strip.Collision]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cell {
                let pileup = collisions.contains { $0.day >= cell.period.start && $0.day < cell.period.end }
                let week = HorizonStripView.isWeek(cell.period)
                Text(pileup ? "Pileup" : week ? "Week" : "Day").font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(pileup ? Design.accent : .secondary)
                Text(week ? "Week of \(cell.period.start.formatted(.dateTime.month(.wide).day()))" : cell.period.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .deck().lineLimit(2, reservesSpace: true).contentTransition(.numericText())
                Text(cell.items.isEmpty ? "Nothing due." : "\(cell.count) item\(cell.count == 1 ? "" : "s"), \(cell.points.formatted(.number.precision(.fractionLength(0...1))))% of grades at stake.")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Semester").font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(.secondary)
                Text(summary).deck().lineLimit(2, reservesSpace: true)
                #if os(macOS)
                Text(level == .weeks ? "Point at a week to read it; click to look closer." : "Point at a day to read it; click to keep it.").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                #else
                Text(level == .weeks ? "Tap a week to look closer." : "Tap a day to read it. Pinch for the semester.").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: cell?.period)
        .animation(.default, value: level)
    }

    private var summary: String {
        let pileups = collisions.count == 0 ? "no pileups" : collisions.count == 1 ? "one pileup" : "\(collisions.count) pileups"
        return "\(total) obligation\(total == 1 ? "" : "s") on the horizon, \(pileups)."
    }
}
