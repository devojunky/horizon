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
    }
}

/// SPEC §6.2: one continuous strip of the term, one band per course, and above them (when there are several) a band
/// for everything, where the shape of the term shows. Load is colour, not size: the accent deepens with the points
/// at stake, and a cell carries its count. Days where heavy items pile up are called out.
///
/// The page is one scroll (HIG: no competing scroll regions; the strip scrolls sideways inside it): the range, the
/// header, the term at a glance, the strip, then the list. The strip is a row of bars, a week or a day each, and
/// every bar is a real button the full height of the strip and never narrower than the HIG's control size (44 points
/// for a finger, 28 for a pointer), so what is aimed at is what is hit. That rules out squeezing a month of days or a
/// term of weeks onto a phone: the strip scrolls instead, and a line above it shows the whole term with a window on
/// what is in view. Two levels, not a fluid zoom: a pinch (or the range's two stops) goes from weeks to days and
/// back, keeping the date under the fingers where it was.
///
/// Built to cost nothing at rest and little in motion: the bars are drawn once each and the scroll only moves them
/// (no canvas as wide as the term, redrawn every frame, as there was); the page's own state never changes while a
/// finger moves (`StripMotion`), so neither the list nor the bars are touched by a scroll or a pinch.
struct HorizonStripView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.due != nil }, sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var level: Strip.Level = MainTabs.debugFlag("--zoom-days") ? .days : .weeks
    @State private var position = ScrollPosition(idType: Date.self)
    @State private var motion = StripMotion()
    @State private var placed = false                // the strip opens on today, once
    @State private var landing: (date: Date, fraction: CGFloat)?   // where a change of level should put which date, once the new bars exist
    @State private var rows = RowsBox()
    @State private var scrub: Date?
    @State private var hover: Date?                  // macOS: the bar under the pointer reads in the header without a click
    @State private var editing: Obligation?
    @State private var lingering = Lingering()       // just checked off under "Coming up": crossed off for a moment before it leaves, so a slip can be undone
    @State private var listHeadY: CGFloat = 0        // where the list begins on the screen, to know when a scrub's items are under the fold
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

    /// The period a day falls in at this level, and what it holds across every band.
    private func cell(for day: Date?, among items: [StripItem]) -> Strip.Cell? {
        guard let day else { return nil }
        let period = Strip.period(containing: day, level: level, calendar: calendar)
        return Strip.cells(items.filter { $0.due >= period.start && $0.due < period.end }, level: level, calendar: calendar).first ?? Strip.Cell(period: period, items: [], points: 0)
    }

    /// Under the strip: the chosen period's items, else what is coming up from today; in time order, heavier first
    /// on a tie, and what is done last, once its moment is over.
    private func listed(_ data: StripData) -> [Obligation] {
        let byID = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0) })
        let chosen: [StripItem]
        if let picked = cell(for: scrub, among: data.items) { chosen = picked.items } else {
            let today = calendar.startOfDay(for: Date())
            chosen = data.items.filter { $0.due >= today && (!$0.completed || lingering.contains($0.id)) }
        }
        let settled: (StripItem) -> Bool = { $0.completed && !lingering.contains($0.id) }
        return chosen.sorted { settled($0) != settled($1) ? !settled($0) : $0.due != $1.due ? $0.due < $1.due : ($0.points ?? 0) > ($1.points ?? 0) }.compactMap { byID[$0.id] }
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
                            StripHeader(level: level, cell: cell(for: hover ?? scrub, among: data.items), total: data.items.count, collisions: data.collisions)
                                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 10, trailing: 20))
                            if contentWidth > geo.size.width + 1 {   // the term does not fit across: a line that shows all of it, and where the strip is in it
                                TermOverview(data: data, level: level, motion: motion, contentWidth: contentWidth, viewport: geo.size.width, calendar: calendar) { date in
                                    let period = Strip.period(containing: date, level: level, calendar: calendar)
                                    withAnimation(.snappy) { position.scrollTo(id: period.start, anchor: .center) }
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 20))
                            }
                            strip(data, g, width: geo.size.width) { day in
                                guard Date().timeIntervalSince(motion.pinchedAt) > 0.4 else { return }   // two fingers lifting are not a tap
                                let again = scrub.map { Strip.period(containing: $0, level: level, calendar: calendar).start == Strip.period(containing: day, level: level, calendar: calendar).start } ?? false
                                scrub = again ? nil : day   // the same bar again lets it go
                                if !again { reveal(page, viewportBottom: geo.frame(in: .global).maxY) }
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
                            if listed.isEmpty { Text(scrub == nil ? "Nothing coming up." : "Nothing due.").foregroundStyle(.secondary).id("nothing") }
                        } header: {
                            listHeader(data).onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { listHeadY = $0 }
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
                    position.scrollTo(id: Strip.period(containing: Date(), level: level, calendar: calendar).start, anchor: UnitPoint(x: 0.2, y: 0.5))
                    if MainTabs.debugOnce("--scrub-week"), let heavy = data.collisions.first?.day ?? data.items.first?.due { scrub = heavy }   // DEBUG: a period read without a tap
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
                    Picker("Range", selection: Binding(get: { level }, set: { landing = (scrub ?? Date(), 0.5); level = $0 })) {   // the chosen bar, else today, comes to the middle
                        Text("Weeks").tag(Strip.Level.weeks)
                        Text("Days").tag(Strip.Level.days)
                    }
                    .pickerStyle(.segmented)
                    .help("The term by its weeks, or by its days")
                }
            }
            #endif
            .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        }
    }

    /// The strip: a lazy row of bars scrolling sideways, and over it the bands' names, which stay put. A name has its
    /// own line above its band's cells, so it never covers a cell; beside it, while a bar is chosen, what that course
    /// has in it.
    private func strip(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (Date) -> Void) -> some View {
        let today = calendar.startOfDay(for: Date())
        let chosen = (hover ?? scrub).map { Strip.period(containing: $0, level: level, calendar: calendar).start }
        let totalFirst = data.bands.first?.kind == .all
        return ScrollView(.horizontal, showsIndicators: false) {
            Stretch(motion: motion) {
                LazyHStack(spacing: 0) {
                    ForEach(data.periods, id: \.start) { period in
                        StripBar(period: period, cells: data.cells.map { $0[period.start] }, totalFirst: totalFirst, g: g,
                                 month: monthBeginning(in: period), today: holds(period, today) ? dayIndex(of: today, in: period) : nil,
                                 pileups: data.collisions.filter { holds(period, $0.day) }.map { dayIndex(of: $0.day, in: period) },
                                 pileupDate: data.collisions.first { holds(period, $0.day) }?.day, chosen: chosen == period.start, calendar: calendar,
                                 choose: { choose(period.start) }, hover: { inside in hover = inside ? period.start : (hover == period.start ? nil : hover) })
                            .equatable()
                            .id(period.start)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, g.inset)
                .frame(height: g.height)
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in   // the strip gives a little under the fingers; the level changes when they let go
                    motion.pinchedAt = Date()
                    motion.pinchAnchor = min(max((value.startLocation.x - motion.offset) / max(width, 1), 0), 1)
                    motion.pinch = min(max(1 + (value.magnification - 1) * 0.2, 0.9), 1.1)
                }
                .onEnded { value in
                    motion.pinchedAt = Date()
                    let wanted: Strip.Level? = value.magnification > 1.25 && level == .weeks ? .days : value.magnification < 0.8 && level == .days ? .weeks : nil
                    if let wanted { setLevel(wanted, data: data, g: g, width: width, anchorX: value.startLocation.x) }
                    withAnimation(.spring(duration: 0.35)) { motion.pinch = 1 }
                })
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in motion.offset = offset }
        .onChange(of: level) { _, new in   // the row now holds the new level's bars: the date that was held goes back where it was
            guard let landing else { return }
            self.landing = nil
            let start = Strip.period(containing: landing.date, level: new, calendar: calendar).start
            guard let index = data.periods.firstIndex(where: { $0.start == start }) else { return }
            // Bars are one width, so where a date sits is arithmetic; an offset lands exactly where an id, in a lazy row whose bars do not exist yet, did not.
            let day = new == .weeks ? CGFloat(dayIndex(of: landing.date, in: data.periods[index])) : 0
            let x = g.inset + CGFloat(index) * g.barWidth + (day + 0.5) * g.dayWidth - landing.fraction * width
            let target = max(0, min(x, CGFloat(data.periods.count) * g.barWidth + g.inset * 2 - width))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))   // once the scroll view has the new row's width
                position.scrollTo(x: target)
                motion.pinch = new == .days ? 0.94 : 1.06   // the new bars settle into place: the step reads as a zoom
                withAnimation(.spring(duration: 0.4)) { motion.pinch = 1 }
            }
        }
        .overlay(alignment: .topLeading) { bandLabels(data, g) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(data))
    }

    /// A period holds a date from its start up to, not including, its end: `DateInterval.contains` counts the end too,
    /// which would put midnight in two bars at once.
    private func holds(_ period: DateInterval, _ date: Date) -> Bool { date >= period.start && date < period.end }

    /// The month that begins inside a period, and the day of the period it begins on. At the days level, where nine
    /// days are across a phone and a month's first may be weeks away, each week's first day says the month again, quietly.
    private func monthBeginning(in period: DateInterval) -> StripBar.Month? {
        if let first = calendar.dateInterval(of: .month, for: period.end.addingTimeInterval(-1))?.start, holds(period, first) {
            return StripBar.Month(name: first.formatted(.dateTime.month(.wide)), day: dayIndex(of: first, in: period), begins: true)
        }
        guard level == .days, calendar.component(.weekday, from: period.start) == calendar.firstWeekday else { return nil }
        return StripBar.Month(name: period.start.formatted(.dateTime.month(.abbreviated)), day: 0, begins: false)
    }

    private func dayIndex(of date: Date, in period: DateInterval) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: period.start), to: calendar.startOfDay(for: date)).day ?? 0)
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
                    if band.kind != .all, let cell = cell(for: hover ?? scrub, among: data.bandItems[index]), cell.count > 0 {
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

    /// Over the list: what it is a list of, and, for a chosen bar, the way back to what is coming up.
    private func listHeader(_ data: StripData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let scrub, let cell = cell(for: scrub, among: data.items) {
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

    /// The date at a point along the row of bars: the bar's own at the days level, the day within the week at the weeks level.
    private func date(atContentX x: CGFloat, data: StripData, g: StripGeometry) -> Date {
        let index = min(max(Int((x - g.inset) / g.barWidth), 0), data.periods.count - 1)
        let period = data.periods[index]
        guard g.level == .weeks else { return period.start }
        let day = min(max(Int((x - g.inset - CGFloat(index) * g.barWidth) / g.dayWidth), 0), 6)
        return calendar.date(byAdding: .day, value: day, to: period.start) ?? period.start
    }

    /// Weeks to days or back, keeping a date where it was on the screen: the one under the fingers for a pinch; for
    /// the range's stops the chosen bar's, else the one in the middle, brought to the middle.
    private func setLevel(_ new: Strip.Level, data: StripData, g: StripGeometry, width: CGFloat, anchorX: CGFloat? = nil) {
        guard new != level, !data.periods.isEmpty else { return }
        let contentX = anchorX ?? motion.offset + width / 2
        let held = anchorX == nil ? scrub ?? date(atContentX: contentX, data: data, g: g) : date(atContentX: contentX, data: data, g: g)
        landing = (held, anchorX == nil ? 0.5 : min(max((contentX - motion.offset) / max(width, 1), 0), 1))
        level = new   // `onChange(of: level)` lands the held date once the new bars exist
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

/// Applies a pinch in progress to the row of bars: a stretch of the layer, nothing redrawn. Alone in reading
/// `StripMotion.pinch`, so a pinch re-evaluates this and nothing else.
private struct Stretch<Content: View>: View {
    let motion: StripMotion
    @ViewBuilder var content: Content
    var body: some View {
        content.scaleEffect(x: motion.pinch, y: 1, anchor: UnitPoint(x: motion.pinchAnchor, y: 0.5))
    }
}

/// One bar of the strip: a week or a day, the full height of the strip, and a button (HIG: a control is at least 44
/// points across for a finger, 28 for a pointer; `Strip.barWidth` sees to the width, the strip's height to the rest).
/// Drawn once and then only moved by the scroll; equal inputs mean it is not drawn again.
private struct StripBar: View, Equatable {
    /// A month's name on the upper tier: where the month begins (with a rule), or, at the days level, a reminder of it on a week's first day.
    struct Month: Equatable { var name: String; var day: Int; var begins: Bool }

    let period: DateInterval
    /// Per band, what the period holds; nil where it holds nothing.
    let cells: [Strip.Cell?]
    let totalFirst: Bool
    let g: StripGeometry
    let month: Month?
    /// The day of the period that is today, when it is in it.
    let today: Int?
    let pileups: [Int]
    let pileupDate: Date?
    let chosen: Bool
    let calendar: Calendar
    var choose: () -> Void
    var hover: (Bool) -> Void

    nonisolated static func == (a: StripBar, b: StripBar) -> Bool {
        a.period == b.period && a.cells == b.cells && a.totalFirst == b.totalFirst && a.g == b.g && a.month == b.month && a.today == b.today
            && a.pileups == b.pileups && a.chosen == b.chosen
    }

    private var title: String {
        g.level == .weeks ? "Week of \(period.start.formatted(.dateTime.month(.wide).day()))" : period.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
    private var summary: String {
        let cell = totalFirst ? cells.first ?? nil : cells.compactMap { $0 }.first
        let count = totalFirst ? cell?.count ?? 0 : cells.compactMap { $0?.count }.reduce(0, +)
        let points = totalFirst ? cell?.points ?? 0 : cells.compactMap { $0?.points }.reduce(0, +)
        return count == 0 ? "Nothing due" : "\(count) item\(count == 1 ? "" : "s"), \(points.formatted(.number.precision(.fractionLength(0...1)))) percent of grades at stake\(pileups.isEmpty ? "" : ", a pileup")"
    }

    var body: some View {
        Button(action: choose) {
            Canvas { context, size in draw(&context, size) }
                .frame(width: g.barWidth, height: g.height)
                .overlay(alignment: .topLeading) {   // a month's name may run on past its bar; nothing else is on its tier
                    if let month {
                        Text(month.name).font(.system(.subheadline, design: .serif, weight: .semibold)).foregroundStyle(month.begins ? .primary : .secondary).fixedSize()
                            .offset(x: CGFloat(month.day) * g.dayWidth + 6, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover(perform: hover)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHidden(cells.allSatisfy { $0 == nil })   // VoiceOver steps through the bars with something in them
    }

    private func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)) }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        // The chosen bar: a soft column behind everything else.
        if chosen {
            context.fill(Path(roundedRect: CGRect(x: 1, y: g.axisHeight - 2, width: size.width - 2, height: g.bottom - g.axisHeight + 2), cornerRadius: 4), with: .color(.primary.opacity(0.08)))
        }
        // Rules: the bar's own leading edge (a week's or a day's start), a month's beginning, a pileup's day. All behind the cells.
        context.stroke(vertical(0, from: g.axisHeight - 6, to: g.bottom), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        if let month, month.begins { context.stroke(vertical(CGFloat(month.day) * g.dayWidth, from: 0, to: g.bottom), with: .color(.secondary.opacity(0.35)), lineWidth: 1) }
        for day in pileups {
            context.stroke(vertical((CGFloat(day) + 0.5) * g.dayWidth, from: g.axisHeight - 2, to: g.bottom), with: .color(.primary.opacity(0.65)), lineWidth: 1)
        }
        // The lower tier: the bar's own date, or in the accent the date of the pileup it holds.
        let date: Text = if let pileupDate {
            Text(pileupDate.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accent)
        } else {
            Text(period.start.formatted(g.level == .weeks ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated).day()))
                .font(.caption2.weight(today != nil ? .bold : .regular)).foregroundStyle(today != nil ? .primary : .secondary)
        }
        context.draw(date, at: CGPoint(x: size.width / 2, y: g.monthTier + g.dateTier / 2), anchor: .center)
        // Bands: a baseline each, and what the period holds standing on it.
        for (band, cell) in cells.enumerated() {
            let base = g.baseline(band)
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: base)); p.addLine(to: CGPoint(x: size.width, y: base)) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            guard let cell else { continue }
            let rect = CGRect(x: 1.5, y: base - g.cellsHeight, width: size.width - 3, height: g.cellsHeight)
            if g.level == .weeks || (totalFirst && band == 0) { drawCell(cell, in: rect, &context) } else { drawItems(cell, in: rect, &context) }
        }
        // Today: a dashed line with its name at the foot, in the primary colour so it reads over the cells.
        if let today {
            let x = (CGFloat(today) + 0.5) * g.dayWidth
            context.stroke(vertical(x, from: g.axisHeight - 2, to: g.bottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let name = context.resolve(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary))
            let half = name.measure(in: CGSize(width: 80, height: 30)).width / 2
            context.draw(name, at: CGPoint(x: min(max(x, half), size.width - half), y: size.height), anchor: .bottom)
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

/// The whole term in one line, for a screen the strip does not fit across: a tick per week, the accent as deep as
/// the week's load, today, the pileups, and a window on what the strip is showing. A tap takes the strip there. Only
/// the window moves with a scroll; the line itself is drawn when the term changes.
private struct TermOverview: View {
    let data: StripData
    let level: Strip.Level
    let motion: StripMotion
    let contentWidth: CGFloat
    let viewport: CGFloat
    let calendar: Calendar
    var go: (Date) -> Void

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
                        let rect = CGRect(x: CGFloat(i) * w + 0.5, y: 8, width: max(w - 1, 1), height: 10)
                        let load = loads[week.start]
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(load == nil ? Color.secondary.opacity(0.12) : Design.accent.opacity(Strip.heat(points: load))))
                    }
                    for collision in data.collisions {   // a pileup: a tick above its week
                        context.fill(Path(CGRect(x: place(collision.day) - 0.5, y: 2, width: 1.5, height: 5)), with: .color(Design.accent))
                    }
                    let today = place(Date())
                    context.stroke(Path { p in p.move(to: CGPoint(x: today, y: 4)); p.addLine(to: CGPoint(x: today, y: 22)) }, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                OverviewWindow(motion: motion, contentWidth: contentWidth, viewport: viewport, width: geo.size.width)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in go(origin.addingTimeInterval(Double(location.x / max(geo.size.width, 1)) * total)) }
        }
        .frame(height: 44)   // a control's height, though the line in it is slight
        .accessibilityHidden(true)   // the bars themselves are the accessible path through the term
    }
}

/// The part of the term the strip is showing, on the overview. Alone in reading `StripMotion.offset`.
private struct OverviewWindow: View {
    let motion: StripMotion
    let contentWidth: CGFloat
    let viewport: CGFloat
    let width: CGFloat

    var body: some View {
        let span = max(contentWidth - 40, 1)
        let lead = min(max((motion.offset - 20) / span, 0), 1), share = min(viewport / span, 1)
        RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.55), lineWidth: 1.5)
            .frame(width: max(share * width, 12), height: 20)
            .offset(x: min(lead * width, width - max(share * width, 12)), y: 3)
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
                            Text(stop == .weeks ? "Weeks" : "Days").font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(selected ? .primary : .secondary)
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
                let kicker = pileup ? "Pileup" : level == .weeks ? "Week" : "Day"
                Text(kicker).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(pileup ? Design.accent : .secondary)
                Text(level == .weeks ? "Week of \(cell.period.start.formatted(.dateTime.month(.wide).day()))" : cell.period.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .deck().lineLimit(2, reservesSpace: true).contentTransition(.numericText())
                Text(cell.items.isEmpty ? "Nothing due." : "\(cell.count) item\(cell.count == 1 ? "" : "s"), \(cell.points.formatted(.number.precision(.fractionLength(0...1))))% of grades at stake.")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Semester").font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(.secondary)
                Text(summary).deck().lineLimit(2, reservesSpace: true)
                #if os(macOS)
                Text("Point at a bar to read it; click to keep it. Pinch for \(level == .weeks ? "days" : "weeks").").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                #else
                Text("Tap a bar to read it. Pinch for \(level == .weeks ? "days" : "weeks").").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
