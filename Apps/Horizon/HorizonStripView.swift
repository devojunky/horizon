import SwiftUI
import SwiftData
import HorizonCore
#if canImport(UIKit)
import UIKit
#endif

/// The app's screens (SPEC §6): Coverage, the Horizon strip, and Now; on iOS, Search as the tab bar's search tab
/// (HIG: one place to search the whole app, at the bar's trailing end).
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    /// `--tab-horizon` / `--tab-now` / `--tab-search` (DEBUG) open on a tab, for screenshots from the command line.
    @State private var tab = Self.debugFlag("--tab-horizon") ? 1 : Self.debugFlag("--tab-now") ? 2 : Self.debugFlag("--tab-search") ? 3 : 0

    var body: some View {
        #if os(iOS)
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Coverage", systemImage: "eye", value: 0) { RootView() }
            Tab("Horizon", systemImage: "chart.bar.xaxis", value: 1) { HorizonStripView() }
            Tab("Now", systemImage: "sun.horizon", value: 2) { NowView() }
            Tab(value: 3, role: .search) { SearchPage() }
        }
        // On the tab bar, not the page: the Search tab's field then stands at the foot of the screen whenever the tab is
        // open (iOS 26+), where the thumb is; on the page it hid in the navigation bar until pulled down.
        .searchable(text: $model.searchText, prompt: "Items, courses, policies, documents")
        .onSubmit(of: .search) { model.rememberSearch() }   // a search submitted is one of the page's recent searches
        .tabViewSearchActivation(.searchTabSelection)
        .modifier(AppRouter(tab: $tab))
        .overlay {
            // Over the app from its first frame (a cover is presented after it, and slid up over an empty Coverage), and
            // modal to VoiceOver; its fade at the end shows the app beneath.
            if model.showsOnboarding {
                OnboardingView(startPage: Self.debugValue("--onboarding-page").flatMap(Int.init) ?? 0) { model.finishOnboarding() }
                    .accessibilityAddTraits(.isModal)
                    .transition(.identity)
            }
        }
        #else
        MacRootView()
        #endif
    }

    /// A DEBUG flag's value, the argument after it (`--onboarding-page 2`).
    static func debugValue(_ flag: String) -> String? {
        #if DEBUG
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
        #else
        return nil
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

/// A band of the strip: a course, or the items filed under none. (`all` is no band: it is the filter's "every course".)
struct Band: Identifiable, Equatable {
    enum Kind: Hashable { case all, course(UUID), unfiled }
    var kind: Kind
    var name: String
    var id: Kind { kind }
}

/// What the strip's colour means (HIG: a legend for what position does not say): the accent deepens with the share
/// of the grade at stake in a cell, a day's on the Mac's chart and at the days, a week's in the semester.
struct HeatLegend: View {
    var period = "day"
    var body: some View {
        HStack(spacing: 8) {
            Text("Less at stake").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach([0.0, 5, 12, 25, 40], id: \.self) { points in
                    RoundedRectangle(cornerRadius: 2).fill(Design.paper).overlay(RoundedRectangle(cornerRadius: 2).fill(Design.accent.opacity(Strip.heat(points: points))))
                        .frame(width: 12, height: 12)
                }
            }
            Text("More").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The deeper the colour, the more of the grade is at stake that \(period)")
    }
}

extension AnyTransition {
    /// One thing giving way to another in the same place, the old gone before the new is in: a fade through, so two
    /// texts or two drawings are never seen over each other (a crossfade shows both at half strength for a moment).
    static var fadeThrough: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)), removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

#if os(iOS)
/// The page's height as it is at rest, with the large title showing. The strip is sized for that and keeps it: as the
/// title folds into the bar on a scroll the page grows by the title's height, and a strip sized for the page as it
/// stands grew with it, so its bands stretched under the finger, and after an animated scroll (a week chosen, the
/// list revealed) they stretched only once it was over, in one jump. The largest top inset seen at a width is the
/// title's (a pull past the top does not move it), kept per width so a turn to landscape starts again.
private struct RestingPage {
    struct Inset: Equatable { var width: CGFloat; var top: CGFloat }
    private var width: CGFloat = -1
    private var top: CGFloat = 0

    mutating func note(_ inset: Inset) {
        if inset.width != width { width = inset.width; top = inset.top } else { top = max(top, inset.top) }
    }

    /// The height the page has with its title showing: what it has now, less what the folded title has given it.
    func height(of geo: GeometryProxy) -> CGFloat {
        geo.size.height - max(0, (geo.size.width == width ? top : geo.safeAreaInsets.top) - geo.safeAreaInsets.top)
    }
}

/// Where things sit in the strip. Top to bottom: an axis of two tiers (a month's name where it begins; under it each
/// bar's own date, so nothing is ever drawn over anything), one row per band (what a roomy band has to spare, then
/// its name's line seated on its cells, then a gap), and a foot for "Today". Left to right: bars of one width, a week
/// or a day each: a week as wide as the term across the screen allows, a day never narrower than the HIG's control
/// size (`Strip.barWidth`).
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
/// under the fingers), a pinch in progress, and whether the bands' names show. Kept out of the page's state on
/// purpose: a scroll, a pinch or a hold touches only the small views that read these, never the page, its list, or
/// the bars.
@MainActor @Observable private final class StripMotion {
    var offset: CGFloat = 0
    var pinch: CGFloat = 1
    /// Where a pinch or a level's settle is centred, as a fraction of what `Stretch` scales: the screen-wide canvas at
    /// the semester, the whole row of days at the days (so a point of the row, not of the screen, stays put).
    var pinchAnchor: CGFloat = 0.5
    /// When two fingers were last on the strip: a bar under one of them must not take their lifting for a tap.
    var pinchedAt = Date.distantPast
    /// Where the days should scroll to, asked for by the overview line being scrubbed. `DaysStrip` alone reads it,
    /// and owns the scroll view's position.
    var request: ScrollRequest?
    /// Where the days should open (on today, on the date a change of level held, on a week looked closer at): kept
    /// until `DaysStrip` is laid out and knows its own width, then spent. A request fired at a guessed moment raced
    /// the scroll view and was lost when it came first.
    var landing: Landing?
    /// The day at the leading margin of the row on screen, kept as it scrolls once it has landed. A row made afresh
    /// with no landing asked for opens there: the page's other layout (iPhone Duo opened or closed) makes a new row,
    /// and the days in view stay in view. (A landing asked for at the change was spent by the row on its way out.)
    var leadingDay: Date?
    /// Whether the bands' names show (`BandLabels`, alone in reading it): while a finger holds the strip or the strip
    /// moves, and for a moment after. At rest the strip is its cells alone.
    private(set) var namesShown = false
    /// How long a still finger is down before it is a hold, not a tap: the system's long press.
    static let holdTime: TimeInterval = 0.5
    // What keeps the names up, each heard on its own, since one ends as another begins in either order (a bar's press
    // is let go the moment the row starts to scroll).
    @ObservationIgnored private var pressedAt: Date?       // a finger resting on a day's bar or on the semester, since
    @ObservationIgnored private var holding = false        // that press has become a hold: its names are up (the clock alone would call a lift at 0.501 s a hold no one saw)
    @ObservationIgnored private var moving = false         // a scroll or its coast
    @ObservationIgnored private var scrubbing = false      // the term's line dragged: the row moves without a scroll of its own
    // The lift of a hold is no tap, whichever of the two is heard first, and only that one tap is not: a tap that
    // follows quickly is a tap.
    @ObservationIgnored private var holdAnswered = false   // the hold under the finger has already turned its tap away
    @ObservationIgnored private var heldLift: Date?        // a hold just lifted whose tap has not come yet
    @ObservationIgnored private var names: Task<Void, Never>?

    /// A finger resting on a day's bar or on the semester, or lifted (or gone to a scroll).
    func press(_ down: Bool) {
        guard down != (pressedAt != nil) else { return }
        if down {
            holdAnswered = false; heldLift = nil
        } else {
            if holding, !holdAnswered { heldLift = Date() }
            holding = false
        }
        pressedAt = down ? Date() : nil
        update()
    }

    /// The row scrolling under a finger or coasting, or still again.
    func move(_ on: Bool) {
        guard on != moving else { return }
        moving = on
        if on { heldLift = nil }   // a press that ends in a scroll makes no tap
        update()
    }

    /// The term's line dragged, or let go.
    func scrub(_ on: Bool) {
        guard on != scrubbing else { return }
        scrubbing = on
        update()
    }

    /// Asked by a tap: whether it is only the lift of a hold (it was there for the names), and so no tap. Once per
    /// hold: the tap after it is a tap.
    func tapEndsHold() -> Bool {
        if holding, !holdAnswered { holdAnswered = true; return true }   // the tap heard before the press's end
        defer { heldLift = nil }
        return heldLift.map { Date().timeIntervalSince($0) < 0.3 } ?? false
    }

    /// The names come at once when the strip moves, and for a still finger once it is a hold, never for a tap; they
    /// go a moment after the finger lifts and the strip is still.
    private func update() {
        names?.cancel()
        if let pressedAt, Date().timeIntervalSince(pressedAt) >= Self.holdTime { holding = true }
        if moving || scrubbing || holding {
            if !namesShown { namesShown = true }
        } else if let pressedAt {   // a press not yet a hold: looked at again when it would be one
            let wait = Self.holdTime - Date().timeIntervalSince(pressedAt)
            names = Task { try? await Task.sleep(for: .seconds(max(wait, 0) + 0.01)); if !Task.isCancelled { self.update() } }
        } else if namesShown {
            names = Task { try? await Task.sleep(for: .milliseconds(900)); if !Task.isCancelled { self.namesShown = false } }
        }
    }

    struct ScrollRequest: Equatable {
        var x: CGFloat
        var animated: Bool
        var serial: Int
    }
    struct Landing: Equatable {
        var date: Date
        var place: Place
        /// A day's bar centred at a fraction of the screen's width, or its leading edge on the page's margin.
        enum Place: Equatable { case fraction(CGFloat), margin }
    }
    private var serial = 0
    func scroll(to x: CGFloat, animated: Bool) { serial += 1; request = ScrollRequest(x: x, animated: animated, serial: serial) }
}

/// The list's rows as of the last pass. A bar that did not change keeps the closure it was made with (`equatable`),
/// so what a tap needs to know about the page now is read from here, not captured then.
@MainActor private final class RowsBox { var ids: [UUID] = [] }

/// The handlers on the strip's place in the page, the same in either layout (`HorizonStripView.placing`).
private struct StripPlacing: ViewModifier {
    let inset: RestingPage.Inset
    let isReady: Bool
    let destination: AppDestination?
    var note: (RestingPage.Inset) -> Void
    var ready: () -> Void
    var go: (AppDestination?) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: inset, initial: true) { _, inset in note(inset) }
            .onChange(of: isReady, initial: true) { _, isReady in if isReady { ready() } }   // once there is a term and a real layout (the first pass is zero wide)
            .onChange(of: destination) { _, destination in go(destination) }
    }
}
#endif

/// Everything the page draws from, worked out once per pass instead of once per use.
struct StripData {
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
    /// What the page can be narrowed to: every course with something dated, and the unfiled when there are any.
    var choices: [Band] = []
    /// The band the page is narrowed to, when it is (a filter naming a course that has gone is no filter).
    var narrowedTo: Band?

    /// A month's name on a bar's upper tier: where the month begins (with a rule), or a reminder of it on a week's first day.
    struct Month: Equatable { var name: String; var begins: Bool }

    struct Bar: Identifiable, Equatable {
        var id: Date { period.start }
        var period: DateInterval
        var cells: [Strip.Cell?]
        var month: Month?
        var today: Bool
        var pileupDate: Date?
    }

    init(obligations: [Obligation], courses: [Course], level: Strip.Level, filter: Band.Kind, calendar: Calendar) {
        items = obligations.compactMap { o in
            guard let due = o.due else { return nil }
            return StripItem(id: o.id, title: o.title, courseID: o.course?.id, courseCode: o.course?.code ?? "", courseName: o.course?.title, due: due, dueHasTime: o.dueHasTime,
                             points: o.pointsAtStake, state: o.state, completed: o.completedAt != nil)
        }
        // A band per course with items, and one for items filed under no course. None adds them up: the courses' own say it.
        let known = Set(courses.map(\.id))
        let byCourse = Dictionary(grouping: items) { $0.courseID.flatMap { known.contains($0) ? $0 : nil } }
        bands = courses.filter { byCourse[$0.id] != nil }.map { Band(kind: .course($0.id), name: $0.displayName) }
        bandItems = courses.compactMap { byCourse[$0.id] }
        if let loose = byCourse[nil] { bands.append(Band(kind: .unfiled, name: "Unfiled")); bandItems.append(loose) }
        choices = bands
        // The term's span comes from everything, narrowed or not, so a week stays where it is when the filter changes.
        span = Strip.span(termStarts: courses.compactMap(\.termStart), termEnds: courses.compactMap(\.termEnd), items: items, now: Date(), calendar: calendar)
        if let index = bands.firstIndex(where: { $0.kind == filter }) {   // narrowed to one course: its band alone, its items alone, its own pileups
            narrowedTo = bands[index]
            items = bandItems[index]
            bands = [bands[index]]; bandItems = [items]
        }
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
            let month: Month? = components.day == 1 ? .init(name: period.start.formatted(.dateTime.month(.wide)), begins: true)
                : components.weekday == calendar.firstWeekday ? .init(name: period.start.formatted(.dateTime.month(.abbreviated)), begins: false) : nil
            return Bar(period: period, cells: cells.map { $0[period.start] }, month: month, today: period.start == today, pileupDate: pileups[period.start])
        }
    }
}

#if os(iOS)
/// SPEC §6.2: one continuous strip of the term, one band per course. Load is colour, not size: the accent deepens
/// with the points at stake, and a cell carries its count. Days where heavy items pile up are called out. The bands'
/// names show only while the strip is held or moving (`BandLabels`): at rest it is its cells alone.
///
/// Two levels for two intents. The semester is for reading: the whole term across the screen, as dense as that
/// makes it, drawn once. Its bars are not controls; the whole of it is one, and a touch means "look closer here": the
/// strip goes to days at that week, with the week chosen, so the list under it is that week's work. Days are for
/// working: a bar is a day, a real button the full height of the strip and never narrower than the HIG's control size
/// for a finger (44 points), so the strip scrolls, and a line above it keeps the whole term in view with a window on
/// where the strip is. A pinch goes between the two, keeping the date under the fingers. (A pointer can point at a
/// day a few points wide, so the Mac shows the whole term by day at once: `MacHorizonPage`.)
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
    @State private var held: Date?                   // the date a change of level keeps in place: the new level settles about it (written, never read by the body)
    @State private var rows = RowsBox()
    @State private var filter: Band.Kind = .all      // the course the page is narrowed to; everything, until the user says otherwise
    @State private var chosen: DateInterval?         // the week (from the overview) or the day (from its bar) whose work the list shows
    @State private var editing: Obligation?
    @State private var path: [Route] = []            // an item's details, pushed over the strip
    @State private var lingering = Lingering()       // just checked off under "Coming up": crossed off for a moment before it leaves, so a slip can be undone
    @State private var listHeadY: CGFloat?           // where the list begins on the screen, to know when a chosen period's items are under the fold (nil: never laid out, so far below it)
    @State private var resting = RestingPage()       // the page's height with the large title showing: what the strip is sized for
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 16
    /// A band's name grows with the text size as far as the first accessibility size (`BandLabels` stops there), so
    /// the strip stays a chart; its line is as tall as the name.
    private var bandLabelHeight: CGFloat { min(labelHeight, 29) }
    private let calendar = Calendar.current
    /// What sits above the strip on the page (the range, the header, the overview), and what the list needs to show
    /// its head (its kicker and two rows): the strip's bands share the rest.
    private let chromeAbove: CGFloat = 230, listHead: CGFloat = 170
    private let touch = true
    /// Semester to days or back: one transaction for everything the change moves (the strip, the key above it, the
    /// header, the range's underline), whichever way it was asked for (a tab, a tap, a pinch). Less motion: a fade.
    private var levelChange: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35) }

    /// `listBelow`: the list's head shares the page with the strip (one column); beside it, the strip has the height.
    private func geometry(in size: CGSize, data: StripData, listBelow: Bool = true) -> StripGeometry {
        let rows = max(data.bands.count, 1)
        let spare = Double(size.height - chromeAbove - (listBelow ? listHead : 0)) - 38 - 16   // less the axis and the foot
        let row = CGFloat(Strip.rowHeight(rows: rows, available: spare, minimum: Double(bandLabelHeight) + 28))
        let bar = Strip.barWidth(level, width: Double(size.width) - 40, weeks: data.weeks, minimumBar: Strip.minimumBar(touch: touch))
        return StripGeometry(rows: rows, rowHeight: row, labelHeight: bandLabelHeight, barWidth: CGFloat(bar), level: level)
    }

    /// Where `date` sits across what `Stretch` scales at the level `g` is for, as a fraction of it: the screen-wide
    /// canvas at the semester, the row of days at the days. A level settles into place about it.
    private func anchor(of date: Date, data: StripData, g: StripGeometry, width: CGFloat) -> CGFloat {
        guard let origin = data.periods.first?.start else { return 0.5 }
        let x: CGFloat, whole: CGFloat
        if g.level == .weeks {
            x = g.inset + CGFloat(date.timeIntervalSince(origin) / (7 * 86_400)) * g.barWidth
            whole = width
        } else {
            let index = min(max(calendar.dateComponents([.day], from: origin, to: calendar.startOfDay(for: date)).day ?? 0, 0), data.periods.count - 1)
            x = g.inset + (CGFloat(index) + 0.5) * g.barWidth
            whole = CGFloat(data.periods.count) * g.barWidth + g.inset * 2
        }
        return min(max(x / max(whole, 1), 0), 1)
    }

    /// What a period holds, of these items: a week's or a day's worth as one cell.
    private func cell(for period: DateInterval?, among items: [StripItem]) -> Strip.Cell? {
        guard let period else { return nil }
        let mine = items.filter { period.holds($0.due) }.sorted { ($0.points ?? 0) > ($1.points ?? 0) }
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
        let data = StripData(obligations: obligations, courses: courses, level: level, filter: filter, calendar: calendar)
        let listed = listed(data)
        let _ = rows.ids = listed.map(\.id)
        PageStack(path: $path) {
            Group {
                if #available(iOS 27.1, *), sizeClass == .regular { besideLayout(data, listed) } else { onePage(data, listed) }
            }
            .overlay {
                if data.items.isEmpty {
                    ScrollView {
                        EditorialEmpty(title: "Nothing on the horizon.", deck: "Add a syllabus or a schedule, and its term appears here.") {
                            ImportMenu().prominent()
                        }
                        .padding(.horizontal, 20)
                    }
                    .background(Design.paper)
                }
            }
            .background(Design.paper.ignoresSafeArea())
            .navigationTitle("Horizon")
            .toolbar {
                if data.choices.count > 1 {   // one course is its own filter
                    let narrowed = Binding(get: { data.narrowedTo?.kind ?? .all }, set: { filter = $0 })
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Course", selection: narrowed) {
                                Text("All Courses").tag(Band.Kind.all)
                                ForEach(data.choices) { Text($0.name).tag($0.kind) }
                            }
                        } label: {   // filled while the page is narrowed, so a filter is never on unseen
                            Label("Filter by Course", systemImage: data.narrowedTo == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityValue(data.narrowedTo?.name ?? "All courses")
                    }
                    .visibilityPriority(.high)   // it says whether the page is narrowed: the last to go to the overflow menu
                }
            }
            .sheet(item: $editing) { ObligationEditor(mode: $0.state == .pendingReview ? .review($0) : .edit($0), courses: courses) }
            #if os(iOS)
            .navigationDestination(for: Route.self) { route in
                if case .item(let id) = route { ItemDetail(id: id) }
            }
            #endif
        }
    }

    /// The page as one scroll (a phone; iPhone Duo closed): the range, the header, the strip, then the list.
    private func onePage(_ data: StripData, _ listed: [Obligation]) -> some View {
        GeometryReader { geo in
            let g = geometry(in: CGSize(width: geo.size.width, height: resting.height(of: geo)), data: data)
            ScrollViewReader { page in
                List {
                    chartSection(data, g, width: geo.size.width) { reveal(page, viewportBottom: geo.frame(in: .global).maxY) }
                    Section {
                        comingUp(listed, data: data)
                    } header: {
                        listHeader(data).onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { listHeadY = $0 }
                    }
                    .onPaper()
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 1)
                .paper()
                // Rows that come and go on their own (a check's linger running out, a sync, a document read) move
                // on the default curve. A change the page makes brings its own transaction (a level change, a
                // choice), and this leaves it alone: an implicit animation here would override it, and the
                // range's underline would slide on one curve while the strip changed level on another.
                .transaction(value: listed.map(\.id)) { if $0.animation == nil { $0.animation = .default } }
            }
            .modifier(placing(data, width: geo.size.width, inset: RestingPage.Inset(width: geo.size.width, top: geo.safeAreaInsets.top)))
        }
    }

    /// The page with room (iPhone Duo open, an iPad): the strip and its list side by side, or the strip over its list
    /// on a display taller than wide, so the list is in view whatever the strip shows, and choosing a week or a day
    /// fills it at once (HIG: with more room, expand the layout; the same rows, the same order of reading). An
    /// arrangement rather than a stack of the two: folded like a book the system gives each half of the display one of
    /// them, the strip never across the fold; propped like a laptop, the strip on the raised half, to be read at a
    /// distance, and the list with its rings to check off on the half that lies flat (HIG: content for a distance on
    /// top, controls below; no layout of its own for a pose).
    @available(iOS 27.1, *)
    private func besideLayout(_ data: StripData, _ listed: [Obligation]) -> some View {
        ArrangementView {
            GeometryReader { geo in
                let g = geometry(in: CGSize(width: geo.size.width, height: resting.height(of: geo)), data: data, listBelow: false)
                List {
                    chartSection(data, g, width: geo.size.width) {}
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 1)
                .paper()
                .modifier(placing(data, width: geo.size.width, inset: RestingPage.Inset(width: geo.size.width, top: geo.safeAreaInsets.top)))
            }
            // Only a preference: folded, each side of the fold is one of the two whatever its share (a minimum the side
            // above a fold cannot hold left the list out in the table pose).
            .splitArrangementLayoutRatio(idealHorizontal: 0.62, idealVertical: 0.58)
        } secondary: {
            ScrollViewReader { list in
                List {
                    Section {
                        comingUp(listed, data: data)
                    } header: {
                        listHeader(data).id("head")
                    }
                    .onPaper()
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 1)
                .paper()
                .transaction(value: listed.map(\.id)) { if $0.animation == nil { $0.animation = .default } }
                .onChange(of: chosen) { _, _ in withAnimation(.snappy) { list.scrollTo("head", anchor: .top) } }   // a new period's list from its head
            }
        }
        .arrangementViewStyle(.split)
    }

    /// The range, the header, the strip's key and the strip: the page's head and its chart, in either layout. A tap on
    /// the chart chooses a period; `revealList` brings that period's rows up when the list is below the strip.
    private func chartSection(_ data: StripData, _ g: StripGeometry, width: CGFloat, revealList: @escaping () -> Void) -> some View {
        let contentWidth = CGFloat(data.periods.count) * g.barWidth + g.inset * 2
        return Section {
            RangeTabs(selection: Binding(get: { level }, set: { setLevel($0, data: data, g: g, width: width) }))
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            StripHeader(level: level, cell: cell(for: chosen, among: data.items), total: data.items.count, ahead: ahead(data),
                        collisions: data.collisions, course: data.narrowedTo?.name)
                .pageRow(top: 8, bottom: 10)
            // The strip's key, in the same place at both levels so the strip under it never moves (a
            // row that came and went with the level moved the strip as it changed, and the two levels
            // showed through each other a line apart): at the semester what the colour means; at the
            // days, when the term does not fit across, a line with all of it and where the strip is in it.
            ZStack(alignment: .leading) {
                if level == .days, contentWidth > width + 1 {
                    TermOverview(data: data, motion: motion, g: g, viewport: width, calendar: calendar)
                        .transition(.fadeThrough)
                } else {
                    HeatLegend(period: level == .weeks ? "week" : "day")
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)   // on one line in the key's 44 points at every size
                        .transition(.fadeThrough)
                }
            }
            .frame(height: 44)
            .pageRow(top: 0, bottom: 2)
            strip(data, g, width: width) { period in
                guard Date().timeIntervalSince(motion.pinchedAt) > 0.4, !motion.tapEndsHold() else { return }   // two fingers lifting are not a tap, nor is a hold's finger (it was there for the names)
                if level == .weeks {   // the overview: look closer here, with the week chosen so the list is its work
                    held = period.start
                    motion.landing = .init(date: period.start, place: .margin)   // the week's first day at the leading margin
                    withAnimation(levelChange) { chosen = period; level = .days }
                } else {
                    withAnimation(.default) { chosen = chosen == period ? nil : period }   // the same day again lets it go
                }
                if chosen != nil { revealList() }
            }
            .bleedRow()   // edge to edge: the strip keeps the page's margins inside itself
        }
        .listRowSeparator(.hidden)
        .onPaper()
    }

    /// What the strip's place on the page does as it is laid out, in either layout: the page's resting height noted,
    /// the strip opened on today once there is a term and a width, and the app's own requests for the strip taken.
    private func placing(_ data: StripData, width: CGFloat, inset: RestingPage.Inset) -> some ViewModifier {
        StripPlacing(inset: inset, isReady: !data.periods.isEmpty && width > 0, destination: model.destination,
                     note: { resting.note($0) },
                     ready: { place(data) },
                     go: { if placed { go($0, data: data) } })
    }

    /// The strip's first layout with a term: it opens on today, and takes what was asked for before it was laid out.
    private func place(_ data: StripData) {
        guard !placed else { return }
        placed = true
        if level == .days { motion.landing = .init(date: Date(), place: .fraction(0.2)) }   // DEBUG `--zoom-days`: the days open on today, a little in from the leading edge (what is ahead matters most)
        if MainTabs.debugOnce("--filter-second-course"), data.choices.count > 1 { filter = data.choices[1].kind }   // DEBUG: narrowed to a course without a tap
        if MainTabs.debugOnce("--scrub-week"), let heavy = data.collisions.first?.day ?? data.items.first?.due {   // DEBUG: a week chosen from the overview without a tap, as the tap does it
            let week = Strip.period(containing: heavy, level: .weeks, calendar: calendar)
            held = week.start
            motion.landing = .init(date: week.start, place: .margin)
            chosen = week; level = .days
        }
        if MainTabs.debugOnce("--check-first-coming-up"), let first = listed(data).first {   // DEBUG: a check without a tap, to see the row linger and leave
            Task { try? await Task.sleep(for: .seconds(2)); mark(first.id, true) }
        }
        go(model.destination, data: data)   // asked for before the strip was laid out (the tab's first showing)
    }

    /// The strip at either level, and over it the bands' names, which stay put while the days scroll under them. A
    /// name has its own line above its band's cells, so it never covers a cell; at the line's end, while a period is
    /// chosen, what that course has in it.
    private func strip(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (DateInterval) -> Void) -> some View {
        ZStack(alignment: .topLeading) {   // the two levels in one place: the old goes before the new comes, so they never show through each other
            if level == .weeks { overview(data, g, width: width, choose: choose).transition(.fadeThrough) }
            else { days(data, g, width: width, choose: choose).transition(.fadeThrough) }
        }
        .onChange(of: level) { _, new in   // the strip now holds the new level (`data` and `g` are its); `DaysStrip` puts the held date back where it was once it is laid out
            if new == .weeks { motion.landing = nil }
            if !reduceMotion {   // the new level settles into place about the held date: the step reads as a zoom there (a zoom is what less motion leaves out)
                motion.pinchAnchor = g.level == new ? anchor(of: held ?? Date(), data: data, g: g, width: width) : 0.5
                motion.pinch = new == .days ? 0.94 : 1.06
                withAnimation(.spring(duration: 0.4)) { motion.pinch = 1 }
            }
        }
        .overlay(alignment: .topLeading) {
            BandLabels(lines: data.bands.indices.map { index in
                let cell = cell(for: chosen, among: data.bandItems[index])
                let figure = cell.flatMap { $0.count == 0 ? nil : $0.points > 0 ? "\($0.count) · \($0.points.formatted(.number.precision(.fractionLength(0...1))))%" : "\($0.count)" }
                return BandLabels.Line(id: data.bands[index].kind, name: data.bands[index].name, figure: figure)
            }, g: g, motion: motion)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(data))
    }

    /// The semester, to read: the whole term across the screen in one canvas, drawn when the term changes and not
    /// otherwise. It does not scroll, and its bars are not controls: the whole of it is one, and a touch means "look
    /// closer here" (`Strip.week(at:)` forgives a miss toward a week with something in it). A pinch out does the same
    /// where the fingers are, choosing nothing. A finger held still on it shows the bands' names until it lifts, and
    /// is no tap (`HoldForNames`).
    private func overview(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (DateInterval) -> Void) -> some View {
        let week: (CGFloat) -> DateInterval? = { x in
            Strip.week(at: Double(x - g.inset), barWidth: Double(g.barWidth), weeks: data.periods.count,
                       hasItems: { i in data.cells.contains { $0[data.periods[i].start] != nil } }, reach: Strip.minimumBar(touch: touch) / 2).map { data.periods[$0] }
        }
        return Stretch(motion: motion) {
            OverviewCanvas(data: data, g: g, today: calendar.startOfDay(for: Date()), calendar: calendar)
                .equatable()   // drawn again when its cells change (the term, a check, an edit), not on every pass of the page (a choice, a scroll)
                .dynamicTypeSize(...DynamicTypeSize.large)   // the chart's own words: its tiers and cells are sized for them
                .frame(width: width, height: g.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in if let period = week(location.x) { choose(period) } }
        .modifier(HoldForNames(motion: motion))
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
        .accessibilityChildren {   // VoiceOver's path through the term: each week with something in it, over its own column (so a finger finds the week under it, and the cursor outlines that week), looking closer as its action
            let bandsTop = g.rowTop(0), bandsBottom = g.rowTop(data.bands.count)
            ZStack(alignment: .topLeading) {
                ForEach(Array(data.periods.enumerated()).filter { _, p in data.cells.contains { $0[p.start] != nil } }, id: \.element.start) { index, period in
                    let cell = cell(for: period, among: data.items)
                    Rectangle()
                        .frame(width: g.barWidth, height: max(bandsBottom - bandsTop, 1))
                        .position(x: g.inset + (CGFloat(index) + 0.5) * g.barWidth, y: (bandsTop + bandsBottom) / 2)
                        .accessibilityLabel("Week of \(period.start.formatted(.dateTime.month(.wide).day()))")
                        .accessibilityValue("\(cell?.count ?? 0) item\(cell?.count == 1 ? "" : "s"), \((cell?.points ?? 0).formatted(.number.precision(.fractionLength(0...1)))) percent of grades at stake")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows the week's days")
                        .accessibilityAction { choose(period) }
                }
            }
            .frame(width: width, height: g.height, alignment: .topLeading)
        }
    }

    /// The days, to work from (`DaysStrip`).
    private func days(_ data: StripData, _ g: StripGeometry, width: CGFloat, choose: @escaping (DateInterval) -> Void) -> some View {
        DaysStrip(bars: data.bars, g: g, motion: motion, lit: chosen, calendar: calendar,
                  choose: choose,
                  pinchedIn: { anchorX in setLevel(.weeks, data: data, g: g, width: width, anchorX: anchorX) })
            .dynamicTypeSize(...DynamicTypeSize.large)   // the chart's own words: a bar is 44 points, its tiers sized for them
    }

    /// Under the strip: the chosen period's items, else what is coming up.
    @ViewBuilder private func comingUp(_ listed: [Obligation], data: StripData) -> some View {
        ForEach(listed) { obligation in
            let isOpen = obligation.completedAt == nil   // only a row still to do lingers where it was; one already closed changes in place
            Button { push(.item(obligation.id)) } label: {
                ObligationRow(obligation: obligation, showCourse: data.narrowedTo == nil, mark: { mark(obligation.id, $0, linger: isOpen || !$0) }, disclosure: true)   // narrowed to a course, a row need not say which
            }
                .buttonStyle(.plain)
                .opacity(lingering.isLeaving(obligation.id) ? 0 : 1)
                .id(obligation.id)   // what `reveal` scrolls to
                .obligationActions(done: obligation.completedAt != nil && obligation.skippedAt == nil, skipped: obligation.skippedAt != nil,
                                   mark: { mark(obligation.id, $0, linger: isOpen || !$0) }, skip: { skip(obligation.id, $0, linger: isOpen || !$0) },
                                   edit: { editing = obligation }, delete: { Task { await model.discard(obligation.id) } })
                .accessibilityHint("Opens its details")
        }
        if listed.isEmpty { Text(chosen == nil ? "Nothing coming up." : "Nothing due.").foregroundStyle(.secondary).id("nothing") }
    }

    /// Over the list: what it is a list of, and, for a chosen bar, the way back to what is coming up.
    private func listHeader(_ data: StripData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let chosen {
                Kicker(Self.isWeek(chosen) ? "Week of \(chosen.start.formatted(.dateTime.month(.abbreviated).day()))" : chosen.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                Spacer()
                Button { withAnimation(.default) { self.chosen = nil } } label: {
                    Label("Coming Up", systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon).font(.caption.weight(.medium))
                        .contentShape(.rect.inset(by: -14))   // HIG: about 44 points to hit, though the words are a caption; the shape reaches over the header's own air, so nothing moves
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Lists what is coming up instead")
            } else {
                Kicker(data.narrowedTo.map { "Coming up · \($0.name)" } ?? "Coming up").lineLimit(1)
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
    /// The strip the app was asked for (a link, an intent: "show Calc's week on Horizon"): narrowed to the course when it
    /// has dated work, and at the day asked for, chosen at the days level, in the same transaction a tap makes.
    private func go(_ destination: AppDestination?, data: StripData) {
        guard case .horizon(let course, let day)? = destination else { return }
        model.destination = nil
        path = []   // the strip itself, whatever was pushed over it
        let kind: Band.Kind = course.map { .course($0) } ?? .all
        filter = data.choices.contains { $0.kind == kind } ? kind : .all
        guard let day else { return }
        let period = Strip.period(containing: day, level: .days, calendar: calendar)
        held = period.start
        motion.landing = .init(date: period.start, place: .fraction(0.2))
        withAnimation(levelChange) { chosen = period; level = .days }
    }

    private func setLevel(_ new: Strip.Level, data: StripData, g: StripGeometry, width: CGFloat, anchorX: CGFloat? = nil) {
        guard new != level, !data.periods.isEmpty else { return }
        let kept: Date, fraction: CGFloat
        if let anchorX {   // a pinch: the date under the fingers stays under them
            kept = date(atContentX: anchorX, data: data, g: g)
            fraction = min(max((anchorX - (level == .days ? motion.offset : 0)) / max(width, 1), 0), 1)
        } else {           // the range's stop: the chosen period, else today, a little in from the leading edge (what is ahead matters most)
            kept = chosen?.start ?? Date()
            fraction = 0.2
        }
        held = kept
        if new == .days { motion.landing = .init(date: kept, place: .fraction(fraction)) }   // `DaysStrip` spends it once it is laid out
        withAnimation(levelChange) {   // one transaction for all of it, the list's rows and the range's underline included
            level = new
            if new == .weeks { chosen = nil }   // the semester is for reading: what was picked out among the days is let go, and the list is what is coming up
        }
    }

    /// Of the items on the page, those still to do from today on: what "Coming up" lists.
    private func ahead(_ data: StripData) -> Int {
        let today = calendar.startOfDay(for: Date())
        return data.items.count { !$0.completed && $0.due >= today }
    }

    /// A tap has chosen a bar: if the head of its list is under the fold, the page moves just far enough to show its
    /// first rows (HIG: scroll automatically only as much as necessary).
    private func reveal(_ page: ScrollViewProxy, viewportBottom: CGFloat) {
        guard (listHeadY ?? .infinity) + listHead > viewportBottom + 8 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))   // once the list holds the period's items
            let ids = rows.ids
            if ids.isEmpty { withAnimation(.snappy) { page.scrollTo("nothing", anchor: .bottom) } }
            else { let id = ids[min(1, ids.count - 1)]; withAnimation(.snappy) { page.scrollTo(id, anchor: .bottom) } }   // the second row at the foot: two rows of the period in view
        }
    }

    /// A check under "Coming up" stays on the page for a moment, crossed off, then the row leaves; unchecked, it stays.
    private func mark(_ id: UUID, _ done: Bool, linger: Bool = true) {
        if linger { lingering.mark(id, done: done) }
        Task { await model.setCompleted(id, done) }
    }

    /// A skip lingers as a check does, then the row leaves "Coming up"; taken back, it stays.
    private func skip(_ id: UUID, _ skipped: Bool, linger: Bool) {
        if linger { lingering.mark(id, done: skipped) }
        Task { await model.setSkipped(id, skipped) }
    }

    /// An item's details over the strip, pushed once: a second tap while it is going up is ignored.
    private func push(_ route: Route) {
        guard !path.contains(route) else { return }
        path.append(route)
    }

    private func accessibilitySummary(_ data: StripData) -> String {
        let names = data.bands.map(\.name).joined(separator: ", ")
        let items = data.items.count == 1 ? "1 item" : "\(data.items.count) items"
        let pileups = data.collisions.isEmpty ? "No pileups." : data.collisions.count == 1 ? "1 pileup." : "\(data.collisions.count) pileups."
        return "Semester strip by \(level == .weeks ? "week" : "day"), \(items) across \(names). \(pileups)"
    }
}

/// The days, to work from: a lazy row of bars scrolling sideways, each a button. The scroll view's position lives here
/// and nowhere else: it is by offset only, and neither the system's writes to it as a finger scrolls nor the
/// overview line's as it is scrubbed re-evaluate anything but this row, whose bars are already worked out
/// (`StripData.Bar`) and skipped when equal. (A position that tracked the bar in view, kept in the page's state, was
/// rewritten bar by bar as the strip moved; each write re-ran the page and stopped the scroll's inertia dead.)
private struct DaysStrip: View {
    let bars: [StripData.Bar]
    let g: StripGeometry
    let motion: StripMotion
    /// The period chosen: its days stand in one soft column.
    let lit: DateInterval?
    let calendar: Calendar
    var choose: (DateInterval) -> Void
    /// A pinch in, with where the fingers were along the row: back to the semester.
    var pinchedIn: (CGFloat) -> Void
    @State private var position = ScrollPosition()

    /// The row's width, by arithmetic (bars are one width), and set on it: the scroll view knows it from its first
    /// layout, before a lazy bar exists.
    private var contentWidth: CGFloat { CGFloat(bars.count) * g.barWidth + g.inset * 2 }

    /// The scroll view as laid out: its own width (the viewport) and its content's.
    private struct Frame: Equatable { var viewport: CGFloat; var content: CGFloat }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Stretch(motion: motion) {
                LazyHStack(spacing: 0) {
                    ForEach(bars) { bar in
                        StripBar(bar: bar, g: g, ground: lit.flatMap { StripBar.Ground(bar.period, of: $0) }, choose: { choose(bar.period) },
                                 pressed: { motion.press($0) })
                            .equatable()
                    }
                }
                .padding(.horizontal, g.inset)
                .frame(width: contentWidth, height: g.height, alignment: .leading)
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in   // the row gives a little under the fingers; the level changes when they let go
                    motion.pinchedAt = Date()
                    motion.pinchAnchor = min(max(value.startLocation.x / max(contentWidth, 1), 0), 1)   // the point of the row under the fingers (the stretch scales the row)
                    motion.pinch = min(max(1 + (value.magnification - 1) * 0.2, 0.9), 1.1)
                }
                .onEnded { value in
                    motion.pinchedAt = Date()
                    if value.magnification < 0.8 { pinchedIn(value.startLocation.x) }
                    withAnimation(.spring(duration: 0.35)) { motion.pinch = 1 }
                })
        }
        .scrollPosition($position)
        // The bands' names while the row moves (a finger resting on it is its bars' press: the scroll does not report one).
        .onScrollPhaseChange { _, phase in motion.move(phase != .idle && phase != .tracking) }
        .onDisappear { motion.move(false); motion.press(false) }   // gone mid-scroll or mid-press (a pinch to the semester): no end will come
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
            motion.offset = offset
            if landed, !bars.isEmpty { motion.leadingDay = bars[min(max(Int((offset / g.barWidth).rounded()), 0), bars.count - 1)].period.start }
        }
        .onScrollGeometryChange(for: Frame.self) { Frame(viewport: $0.containerSize.width, content: $0.contentSize.width) } action: { _, frame in
            land(in: frame)   // laid out (or resized): a landing waiting for that goes now
        }
        .onChange(of: motion.landing, initial: true) { land(in: nil) }
        .onChange(of: motion.request) { _, request in
            guard let request else { return }
            if request.animated { withAnimation(.snappy) { position.scrollTo(x: request.x) } } else { position.scrollTo(x: request.x) }
        }
    }

    /// Spends a landing: the date's bar where it was asked to go, by offset (bars are one width, so where a date sits
    /// is arithmetic; an id, in a lazy row whose bars do not exist yet, did not land). Only once the scroll view has
    /// its real width and the row's: before that a position is clamped to nothing, or lost.
    private func land(in laidOut: Frame?) {
        if let laidOut { laid = laidOut }
        let frame = laidOut ?? laid
        guard let first = bars.first, frame.viewport > 0, frame.content >= contentWidth - 1 else { return }
        let resume = landed ? nil : motion.leadingDay.map { StripMotion.Landing(date: $0, place: .margin) }   // a new row, nothing asked: where the last one was
        guard let landing = motion.landing ?? resume else { landed = true; return }
        motion.landing = nil
        landed = true
        let days = calendar.dateComponents([.day], from: first.period.start, to: calendar.startOfDay(for: landing.date)).day ?? 0
        let index = CGFloat(min(max(days, 0), bars.count - 1))
        let x = switch landing.place {
        case .fraction(let f): g.inset + (index + 0.5) * g.barWidth - f * frame.viewport
        case .margin: index * g.barWidth
        }
        position.scrollTo(x: max(0, min(x, contentWidth - frame.viewport)))
    }
    @State private var laid = Frame(viewport: 0, content: 0)
    /// This row has been placed (on a landing, or where the last row was): from then on it says where it is.
    @State private var landed = false
}

/// The bands' names, in the page's margin, each on the line above its cells, and at a course's line's end, while a
/// period is chosen, what it has there. They show only while the strip is held or moving (`StripMotion.namesShown`):
/// at rest the strip is its cells alone, and a name's line is air between the bands. The paper behind the words lets
/// the strip's rules pass under them. Alone in reading `namesShown`, so a touch redraws this and nothing else.
private struct BandLabels: View {
    struct Line: Identifiable, Equatable {
        var id: Band.Kind
        var name: String
        /// What the band has in the chosen period ("1 · 20%"), when it has anything there.
        var figure: String?
    }
    let lines: [Line]
    let g: StripGeometry
    let motion: StripMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(spacing: 8) {
                    Text(line.name).lineLimit(1).truncationMode(.middle)
                        .modifier(Chip(edge: .leading))
                    Spacer(minLength: 0)
                    if let figure = line.figure {
                        Text(figure).monospacedDigit().modifier(Chip(edge: .trailing)).transition(.opacity)
                    }
                }
                .font(.caption2.weight(.semibold)).textCase(.uppercase).kerning(0.6).foregroundStyle(.secondary)
                .frame(height: g.labelHeight)
                .padding(.top, g.labelOffset)
                .frame(height: g.rowHeight, alignment: .top)
            }
        }
        .padding(.horizontal, g.inset)
        .padding(.top, g.axisHeight)
        .opacity(motion.namesShown ? 1 : 0)
        .animation(motion.namesShown ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.4), value: motion.namesShown)   // in as the finger moves; out unhurried
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)   // as far as `bandLabelHeight` grows
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The paper behind a label's words, a little past them either way and rounded, so over a chosen period's column it
    /// reads as a label laid on the strip, not a box cut out of it; the words keep the page's margin (`edge`).
    private struct Chip: ViewModifier {
        let edge: HorizontalEdge
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 5)
                .background(Design.paper, in: .rect(cornerRadius: 4))
                .padding(edge == .leading ? .leading : .trailing, -5)
        }
    }
}

/// A finger resting on the semester, as a day's bar's press says it on the days: held, it shows the bands' names until
/// it lifts, and its lifting is no tap (`StripMotion.press`, `tapEndsHold`). Heard by `FingerDown`, which claims nothing.
private struct HoldForNames: ViewModifier {
    let motion: StripMotion

    func body(content: Content) -> some View {
        content
            .gesture(FingerDown { motion.press($0) })
            .onDisappear { motion.press(false) }   // gone while held (a pinch to the days): the lift will not come here
    }
}

/// A finger down, and up again, heard without being taken: a UIKit recognizer that never recognizes, prevents nothing
/// and cannot be prevented, so the semester's tap and pinch and the page's scroll go on as if it were not there. Every
/// SwiftUI gesture that heard a touch from its first moment took it: a long press (even one meant never to finish)
/// or a drag took the page's vertical scroll from the strip, and one inside the tap kept every tap from it. Up at the
/// lift, or once the finger has moved 10 points before it could be a hold (the page scrolling); a hold that drifts
/// (under 2 mm is 10 points) stays a hold, as a long press does once it has begun.
private struct FingerDown: UIGestureRecognizerRepresentable {
    var changed: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> Observer { Observer() }
    func updateUIGestureRecognizer(_ recognizer: Observer, context: Context) { recognizer.changed = changed }

    final class Observer: UIGestureRecognizer {
        var changed: (Bool) -> Void = { _ in }
        private var start: CGPoint?
        private var startTime: TimeInterval = 0

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard start == nil, let touch = touches.first else { return }
            start = touch.location(in: view)
            startTime = touch.timestamp
            changed(true)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let start, let touch = touches.first, touch.timestamp - startTime < StripMotion.holdTime else { return }
            let point = touch.location(in: view)
            if hypot(point.x - start.x, point.y - start.y) > 10 { finish() }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish() }

        override func reset() { lifted() }   // however it ends, the finger is said to be up: a press left down would keep the names up and turn the next tap away

        private func finish() {
            lifted()
            state = .failed
        }

        private func lifted() {
            if start != nil { start = nil; changed(false) }
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

/// The ink for a count on a cell of the accent at `heat`: black or white, whichever stands out more from the cell as
/// the screen shows it, the accent laid over the paper (`Strip.countInk`, which the Week Ahead widget takes too).
@MainActor private func countInk(heat: Double, in environment: EnvironmentValues) -> Color {
    let accent = Design.accent.resolve(in: environment), paper = Design.paper.resolve(in: environment)
    let cell = Strip.mix((Double(accent.red), Double(accent.green), Double(accent.blue)), at: heat * Double(accent.opacity),
                         over: (Double(paper.red), Double(paper.green), Double(paper.blue)))
    let ink = Strip.countInk(cell: Strip.luminance(cell))
    return ink.dark ? .black.opacity(ink.opacity) : .white
}

/// The semester in one canvas the width of the screen: a cell per week per band, as deep as its load, its count
/// inside when it fits. An axis in two tiers, so nothing is drawn over anything: the months above (shortened to fit,
/// never to one letter), the pileups' dates below in the accent (of two a few points apart, the first is named and
/// both are ruled). Rules run behind the cells, and a cell is painted on the paper first, so no count is struck
/// through; today's line breaks around a count. Today is a dashed line with its name at the foot. Drawn when the term
/// changes (`equatable`); nothing here moves.
private struct OverviewCanvas: View, Equatable {
    let data: StripData
    let g: StripGeometry
    /// Today's start: a new day draws today's line again.
    let today: Date
    let calendar: Calendar

    nonisolated static func == (a: OverviewCanvas, b: OverviewCanvas) -> Bool {
        a.g == b.g && a.today == b.today && a.data.bands.count == b.data.bands.count && a.data.periods == b.data.periods
            && a.data.collisions == b.data.collisions && a.data.cells == b.data.cells
    }

    private func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)) }
    }

    var body: some View {
        Canvas { context, size in
            guard let origin = data.periods.first?.start else { return }
            let x: (Date) -> CGFloat = { g.inset + CGFloat($0.timeIntervalSince(origin) / (7 * 86_400)) * g.barWidth }
            let end = g.inset + CGFloat(data.periods.count) * g.barWidth

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
                let flag = context.resolve(Text(collision.day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accentInk))
                let w = flag.measure(in: CGSize(width: 120, height: 30)).width
                let fx = min(max(cx, g.inset + w / 2), size.width - w / 2 - 2)
                guard fx - w / 2 >= lastFlagEnd + 6 else { continue }
                context.draw(flag, at: CGPoint(x: fx, y: g.monthTier + g.dateTier / 2), anchor: .center)
                lastFlagEnd = fx + w / 2
            }
            // Bands: a baseline each, and a cell per week with anything in it; its count inside when it fits with air.
            var counts = Path()   // where counts are, for today's line to break around
            for band in 0..<max(data.bands.count, 1) {
                let base = g.baseline(band)
                context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: base)); p.addLine(to: CGPoint(x: size.width, y: base)) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                guard band < data.cells.count else { continue }
                for (index, period) in data.periods.enumerated() {
                    guard let cell = data.cells[band][period.start] else { continue }
                    let rect = CGRect(x: g.inset + CGFloat(index) * g.barWidth + 1, y: base - g.cellsHeight, width: max(g.barWidth - 2, 2), height: g.cellsHeight)
                    let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.width / 3))
                    let heat = Strip.heat(points: cell.points)
                    context.fill(shape, with: .color(Design.paper))
                    context.fill(shape, with: .color(Design.accent.opacity(heat)))
                    let count = context.resolve(Text("\(cell.count)").font(.caption2.weight(.semibold)).foregroundStyle(countInk(heat: heat, in: context.environment)))
                    let measured = count.measure(in: CGSize(width: 100, height: 40))
                    guard measured.width <= rect.width - 2, measured.height <= rect.height else { continue }
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    context.draw(count, at: center)
                    counts.addRect(CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width, height: measured.height).insetBy(dx: -4, dy: -1))   // a line within 4 points of the digits reads as touching them
                }
            }
            // Today, over the cells so it is never lost in a busy week, broken where it would cross a count.
            if today >= origin, x(today) < end {
                let tx = x(today) + g.dayWidth / 2
                var line = context
                line.clip(to: counts, options: .inverse)
                line.stroke(vertical(tx, from: g.axisHeight - 2, to: g.bottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: tx, y: size.height), anchor: .bottom)
            }
        }
    }
}

/// One bar of the days: a day, the full height of the strip, and a button (HIG: a control is at least 44 points
/// across for a finger; `Strip.barWidth` sees to the width, the strip's height to the rest).
/// Drawn once and then only moved by the scroll; equal inputs mean it is not drawn again.
private struct StripBar: View, Equatable {
    let bar: StripData.Bar
    let g: StripGeometry
    /// The chosen period's ground in this bar, when the bar is one of its days.
    let ground: Ground?
    var choose: () -> Void
    /// A finger down on the bar, or up: held, it shows the bands' names (`StripMotion.press`).
    var pressed: (Bool) -> Void

    /// A chosen day, or a day of a chosen week: the column its ground fills, rounded where the period opens and
    /// closes, so a day is one rounded column and a week's seven are one with square seams.
    struct Ground: Equatable {
        var opens: Bool
        var closes: Bool
        init?(_ day: DateInterval, of chosen: DateInterval) {
            guard chosen.holds(day.start) else { return nil }
            opens = day.start <= chosen.start
            closes = day.end >= chosen.end
        }
    }

    /// A Wednesday the 28th: the widest date a bar shows, which decides the form every bar takes.
    static let widestDay = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28)) ?? .now

    nonisolated static func == (a: StripBar, b: StripBar) -> Bool {
        a.bar == b.bar && a.g == b.g && a.ground == b.ground
    }

    private var summary: String {
        let count = bar.cells.compactMap { $0?.count }.reduce(0, +)
        let points = bar.cells.compactMap { $0?.points }.reduce(0, +)
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
        .buttonStyle(Press(pressed: pressed))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.period.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(summary)
        .accessibilityAddTraits(ground != nil ? [.isButton, .isSelected] : .isButton)
        .accessibilityHidden(bar.cells.allSatisfy { $0 == nil })   // VoiceOver steps through the days with something in them
    }

    /// The plain button's look, saying when a finger is down: the only word of one resting on the row, since its
    /// scroll reports nothing until it moves (and lets the press go when it does).
    private struct Press: ButtonStyle {
        var pressed: (Bool) -> Void
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onChange(of: configuration.isPressed) { _, down in pressed(down) }
        }
    }

    private func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)) }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        // Chosen: one soft column from the day's date down past the last band, behind everything, edge to edge so the
        // days of a chosen week read as one stretch, and rounded where the period begins and ends.
        if let ground {
            let r: CGFloat = 8
            let column = CGRect(x: 0, y: g.monthTier, width: size.width, height: g.bottom - g.gap + 4 - g.monthTier)
            let corners = RectangleCornerRadii(topLeading: ground.opens ? r : 0, bottomLeading: ground.opens ? r : 0,
                                               bottomTrailing: ground.closes ? r : 0, topTrailing: ground.closes ? r : 0)
            context.fill(Path(roundedRect: column, cornerRadii: corners), with: .color(.primary.opacity(0.08)))
        }
        // Rules: the day's own leading edge, a month's beginning, a pileup. All behind the cells.
        context.stroke(vertical(0, from: g.axisHeight - 6, to: g.bottom), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        if bar.month?.begins == true { context.stroke(vertical(0, from: 0, to: g.bottom), with: .color(.secondary.opacity(0.35)), lineWidth: 1) }
        if bar.pileupDate != nil { context.stroke(vertical(size.width / 2, from: g.axisHeight - 2, to: g.bottom), with: .color(.primary.opacity(0.65)), lineWidth: 1) }
        // The lower tier: the day's own date, or in the accent the date of the pileup it is; the day's number alone
        // when the whole of it would not sit in the bar with air on either side (a long weekday's name).
        let full: Text, short: Text
        if let pileup = bar.pileupDate {
            full = Text(pileup.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accentInk)
            short = Text(pileup.formatted(.dateTime.day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accentInk)
        } else {
            full = Text(bar.period.start.formatted(.dateTime.weekday(.abbreviated).day())).font(.caption2.weight(bar.today ? .bold : .regular)).foregroundStyle(bar.today ? .primary : .secondary)
            short = Text(bar.period.start.formatted(.dateTime.day())).font(.caption2.weight(bar.today ? .bold : .regular)).foregroundStyle(bar.today ? .primary : .secondary)
        }
        // Every bar takes the same form, decided by the widest date there is ("Wed 28"), so the row never alternates
        // "Tue 17", "18", "Thu 19" as the weekdays' names happen to fit.
        let widest = context.resolve(Text(StripBar.widestDay.formatted(.dateTime.weekday(.abbreviated).day())).font(.caption2))
        let fits = widest.measure(in: CGSize(width: 200, height: g.dateTier)).width <= size.width - 2
        context.draw(context.resolve(fits ? full : short), at: CGPoint(x: size.width / 2, y: g.monthTier + g.dateTier / 2), anchor: .center)
        // Bands: a baseline each, and what the day holds standing on it.
        var counts = Path()   // where counts are, for today's line to break around
        for (band, cell) in bar.cells.enumerated() {
            let base = g.baseline(band)
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: base)); p.addLine(to: CGPoint(x: size.width, y: base)) }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            guard let cell else { continue }
            let rect = CGRect(x: 1.5, y: base - g.cellsHeight, width: size.width - 3, height: g.cellsHeight)
            if let count = drawItems(cell, in: rect, &context) { counts.addRect(count) }
        }
        // Today: a dashed line with its name at the foot, in the primary colour so it reads over the cells, broken
        // where it would cross a count.
        if bar.today {
            let x = size.width / 2
            var line = context
            line.clip(to: counts, options: .inverse)
            line.stroke(vertical(x, from: g.axisHeight - 2, to: g.bottom + 2), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: x, y: size.height), anchor: .bottom)
        }
    }

    /// Draws `text` centred at `point` and returns the room it takes, with the air today's line keeps from it.
    private func drawCount(_ text: Text, at point: CGPoint, _ context: inout GraphicsContext) -> CGRect {
        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: 100, height: 40))
        context.draw(resolved, at: point)
        return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height).insetBy(dx: -4, dy: -1)
    }

    /// A day in a course's band: its cell divided among its items, each part its own item's weight; a review item is
    /// an outline, a done one grey. More than the cell can divide among: the top part says how many. Returns where
    /// that count is.
    private func drawItems(_ cell: Strip.Cell, in rect: CGRect, _ context: inout GraphicsContext) -> CGRect? {
        let gap: CGFloat = 2
        let most = max(1, Int((rect.height + gap) / (9 + gap)))
        let shown = Array(cell.items.prefix(most))
        let h = (rect.height - gap * CGFloat(shown.count - 1)) / CGFloat(shown.count)
        var top = rect.maxY
        var ink: Color = .primary   // for the count on the top part: as for a cell's when that part is the accent filled
        for item in shown {
            let part = CGRect(x: rect.minX, y: top - h, width: rect.width, height: h)
            let shape = Path(roundedRect: part, cornerRadius: min(5, h / 2))
            let color: Color = item.completed ? .secondary : Design.accent
            let opacity = item.completed ? 0.35 : Strip.heat(points: item.points)
            context.fill(shape, with: .color(Design.paper))
            switch item.state {
            case .pendingReview, .awaitingDate:
                context.stroke(Path(roundedRect: part.insetBy(dx: 0.75, dy: 0.75), cornerRadius: min(5, h / 2)), with: .color(color.opacity(max(opacity, 0.6))), lineWidth: 1.5)
                ink = .primary
            default:
                context.fill(shape, with: .color(color.opacity(opacity)))
                ink = item.completed ? .primary : countInk(heat: opacity, in: context.environment)
            }
            top = part.minY - gap
        }
        let more = cell.count - shown.count
        guard more > 0, h >= 12 else { return nil }
        return drawCount(Text("+\(more)").font(.caption2.weight(.semibold)).foregroundStyle(ink), at: CGPoint(x: rect.midX, y: top + gap + h / 2), &context)
    }
}

/// The whole term in one line above the days, and their scroll bar: a tick per week, the accent as deep as the
/// week's load, today, the pileups, and a window on what the days are showing. Drag along it and the days follow the
/// finger, the window under it; a tap goes there at once. Only the window moves with a scroll; the line itself is
/// drawn when the term changes (`TermLine`). It takes a control's 44 points of height, though the line in it is slight.
private struct TermOverview: View {
    let data: StripData
    let motion: StripMotion
    let g: StripGeometry
    let viewport: CGFloat
    let calendar: Calendar
    @State private var scrubbing = false
    @GestureState private var touching = false   // a finger on the line: back to false however the drag ends, a cancel included

    var body: some View {
        let weeks = Strip.periods(in: data.span, level: .weeks, calendar: calendar)
        let scale = TermScale(weeks: weeks, days: data.periods, g: g, viewport: viewport, calendar: calendar)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                TermLine(weeks: weeks, loads: Dictionary(uniqueKeysWithValues: Strip.cells(data.items, level: .weeks, calendar: calendar).map { ($0.period.start, $0.points) }),
                         pileups: data.collisions.map(\.day), today: calendar.startOfDay(for: Date()))
                    .equatable()
                OverviewWindow(motion: motion, scale: scale, width: geo.size.width, held: scrubbing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)   // a scroll bar: the touch is its own from the first point, as a slider's is
                .updating($touching) { _, touching, _ in touching = true }
                .onChanged { value in
                    if abs(value.translation.width) > 3, !scrubbing { scrubbing = true; motion.scrub(true) }   // the days move: their names show, as for a scroll
                    if scrubbing { motion.scroll(to: scale.offset(centring: value.location.x / max(geo.size.width, 1)), animated: false) }
                }
                .onEnded { value in
                    if !scrubbing { motion.scroll(to: scale.offset(centring: value.location.x / max(geo.size.width, 1)), animated: true) }   // a tap: there at once
                    else { motion.scrub(false) }
                    scrubbing = false
                })
        }
        .frame(height: 44)
        .onChange(of: touching) { _, touching in   // a scrub cancelled (Control Center, a call) calls no onEnded: the touch's own state still ends
            if !touching, scrubbing { scrubbing = false; motion.scrub(false) }
        }
        .onDisappear { motion.scrub(false) }   // gone mid-scrub (a change of level): its end will not come
        .accessibilityElement()
        .accessibilityLabel("Term")
        .accessibilityHint("Moves the days along the term")
        .accessibilityAdjustableAction { direction in   // VoiceOver's scroll bar: a screenful of days either way
            let step = direction == .increment ? viewport * 0.8 : -viewport * 0.8
            motion.scroll(to: max(0, min(motion.offset + step, scale.contentWidth - viewport)), animated: true)
        }
    }
}

/// The term line's measure against the days': the line runs over whole weeks, the days from the term's first day, so
/// a place on the line and an offset of the days are matched by the day, not by stretching one span over the other
/// (that put the window up to four days off its own ticks).
private struct TermScale {
    /// Days from the line's start (its first week's first day) to the first day's bar.
    var lead: CGFloat
    /// Days the line spans.
    var total: CGFloat
    var barWidth: CGFloat
    var inset: CGFloat
    var viewport: CGFloat
    var contentWidth: CGFloat

    init(weeks: [DateInterval], days: [DateInterval], g: StripGeometry, viewport: CGFloat, calendar: Calendar) {
        let start = weeks.first?.start ?? days.first?.start ?? Date()
        lead = CGFloat(calendar.dateComponents([.day], from: start, to: days.first?.start ?? start).day ?? 0)
        total = CGFloat(max(weeks.count * 7, 1))
        barWidth = max(g.barWidth, 1)
        inset = g.inset
        self.viewport = viewport
        contentWidth = CGFloat(days.count) * g.barWidth + g.inset * 2
    }

    /// Where on the line (0...1) the days' leading edge is at a scroll offset.
    func fraction(atOffset offset: CGFloat) -> CGFloat { (lead + (offset - inset) / barWidth) / total }
    /// The share of the line the days in view take.
    var share: CGFloat { viewport / barWidth / total }
    /// The offset that puts the day at `fraction` of the line in the middle of the days in view.
    func offset(centring fraction: CGFloat) -> CGFloat {
        max(0, min(inset + (fraction * total - lead) * barWidth - viewport / 2, contentWidth - viewport))
    }
}

/// The term line itself: a tick per week as deep as its load, a pileup's mark over its day, today's dash at the
/// middle of today (where the days draw it). Drawn when the term changes, not as the days scroll.
private struct TermLine: View, Equatable {
    let weeks: [DateInterval]
    let loads: [Date: Double]
    let pileups: [Date]
    let today: Date

    var body: some View {
        Canvas { context, size in
            guard let origin = weeks.first?.start else { return }
            let days = CGFloat(weeks.count * 7)
            let place: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(origin) / 86_400 + 0.5) / days * size.width }   // the middle of the day
            let w = size.width / CGFloat(max(weeks.count, 1))
            for (i, week) in weeks.enumerated() {
                let rect = CGRect(x: CGFloat(i) * w + 0.5, y: 17, width: max(w - 1, 1), height: 10)
                let load = loads[week.start]
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(load == nil ? Color.secondary.opacity(0.12) : Design.accent.opacity(Strip.heat(points: load))))
            }
            for day in pileups {   // a pileup: a tick above its day
                context.fill(Path(CGRect(x: place(day) - 0.75, y: 11, width: 1.5, height: 5)), with: .color(Design.accent))
            }
            let now = place(today)
            context.stroke(Path { p in p.move(to: CGPoint(x: now, y: 13)); p.addLine(to: CGPoint(x: now, y: 31)) }, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }
    }
}

/// The part of the term the days are showing, on the overview: the scroll bar's thumb. Alone in reading
/// `StripMotion.offset`, so a scroll redraws this and nothing else.
private struct OverviewWindow: View {
    let motion: StripMotion
    let scale: TermScale
    let width: CGFloat
    /// A finger is on it.
    let held: Bool

    var body: some View {
        let lead = min(max(scale.fraction(atOffset: motion.offset), 0), 1)
        let thumb = max(min(scale.share, 1) * width, 14)
        RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(held ? 0.9 : 0.55), lineWidth: held ? 2 : 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(held ? 0.08 : 0)))
            .frame(width: thumb, height: 22)
            .offset(x: min(lead * width, width - thumb), y: 11)
            .animation(.snappy(duration: 0.2), value: held)
    }
}

/// The range's two stops as a row of tabs with a sliding accent underline, the way a magazine names its sections:
/// each name as wide as its word, its underline too (DECISIONS 2026-09-05; halves of the row read as a segmented
/// control), on one line at every text size.
private struct RangeTabs: View {
    @Binding var selection: Strip.Level
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(Strip.Level.allCases, id: \.self) { stop in
                    let selected = stop == selection
                    Button { selection = stop } label: {   // the page animates the change, the underline with it
                        Text(stop == .weeks ? "Semester" : "Days").font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(selected ? .primary : .secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)   // a name is never broken over two lines
                            .padding(.bottom, 10)   // the underline's room: 8 of air, then its 2
                            .overlay(alignment: .bottom) {
                                if selected { Rectangle().fill(Design.accent).frame(height: 2).matchedGeometryEffect(id: "underline", in: underline) }
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

/// The chosen week or day, or the term at a glance: a kicker, a deck, a line under it. It keeps one height whatever
/// it says, so the strip below never moves: the room is the kicker, the deck's lines and the line's, and what is said
/// sits at its top, so a one-line deck has its line right under it and the spare goes below. At an accessibility
/// text size each gets more lines rather than being cut short (HIG). The accent marks a pileup.
private struct StripHeader: View {
    let level: Strip.Level
    let cell: Strip.Cell?
    let total: Int
    /// Of `total`, what is still to do from today on (what "Coming up" lists).
    let ahead: Int
    let collisions: [Strip.Collision]
    /// The course the page is narrowed to: said in the kicker, so what the figures are figures of is never in doubt.
    var course: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    private func kicker(_ word: String) -> String { course.map { "\(word) · \($0)" } ?? word }
    private var deckLines: Int { typeSize.isAccessibilitySize ? 4 : 2 }
    private var noteLines: Int { typeSize.isAccessibilitySize ? 3 : typeSize > .large ? 2 : 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {   // what is chosen, or the term: one gives way to the other in place
            VStack(alignment: .leading, spacing: 6) {   // the room, the same in every state
                Text(verbatim: " ").font(.caption)
                Text(verbatim: " ").deck().lineLimit(deckLines, reservesSpace: true)
                Text(verbatim: " ").font(.subheadline).lineLimit(noteLines, reservesSpace: true)
            }
            .hidden()
            if let cell {
                let pileup = collisions.contains { cell.period.holds($0.day) }
                let week = HorizonStripView.isWeek(cell.period)
                VStack(alignment: .leading, spacing: 6) {
                    Text(kicker(pileup ? "Pileup" : week ? "Week" : "Day")).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(pileup ? Design.accentInk : .secondary).lineLimit(1)
                    Text(week ? "Week of \(cell.period.start.formatted(.dateTime.month(.wide).day()))" : cell.period.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .deck().lineLimit(deckLines).contentTransition(.numericText())
                    Text(cell.items.isEmpty ? "Nothing due." : "\(cell.count) item\(cell.count == 1 ? "" : "s"), \(cell.points.formatted(.number.precision(.fractionLength(0...1))))% of grades at stake.")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(noteLines)
                }
                .transition(.fadeThrough)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kicker("Term")).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(.secondary).lineLimit(1)   // the subject, at either level: not the range's name under the other range's tab
                    Text(summary).deck().lineLimit(deckLines)
                    Text(level == .weeks ? "Tap a week to look closer." : "Pinch for the semester.").font(.subheadline).foregroundStyle(.secondary).lineLimit(noteLines)   // a day's bar is a button, as the week's tap taught
                        .contentTransition(.opacity)
                }
                .transition(.fadeThrough)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The term in a line: everything on the page, what of it is still ahead (the list's "Coming up"), the pileups.
    private var summary: String {
        let items = total == 1 ? "1 item" : "\(total) items"
        let still = ahead == 0 ? "none still ahead" : ahead == total && total > 1 ? "all still ahead" : "\(ahead) still ahead"
        let pileups = collisions.isEmpty ? "no pileups" : collisions.count == 1 ? "1 pileup" : "\(collisions.count) pileups"
        return "\(items), \(still), \(pileups)."
    }
}
#endif
