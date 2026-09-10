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
}

/// The three stops of the range control, by the days across the screen.
private enum Stop: Hashable, CaseIterable {
    case semester, month, twoWeeks
    var title: String { switch self { case .semester: "Semester"; case .month: "Month"; case .twoWeeks: "Two Weeks" } }
}

/// A band of the strip: a course, or the items filed under none.
private struct Band: Identifiable, Equatable {
    var id: UUID?
    var name: String
}

/// SPEC §6.2: one continuous strip of the term, one band per course. What it shows follows the zoom, the way Health's
/// charts change with their range: the whole semester reads as weeks, a month as days, and only two weeks or less as
/// the items themselves. Load is colour, not size: the accent deepens with the points at stake in a week, a day or an
/// item, and a cell carries its count. Days where heavy items pile up are called out. A pinch zooms around the fingers
/// and a segmented control has the three stops; a tap or a press-and-drag scrubs a week or a day into the header, whose
/// height never changes, and lists its items under the strip (what is coming up when nothing is scrubbed); a row opens
/// the editor. New marks fade in as a document resolves.
struct HorizonStripView: View {
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
    private let calendar = Calendar.current
    private let axisHeight: CGFloat = 34

    /// Where the fingers came down, in content points, so zooming keeps that day under them.
    private struct PinchAnchor { var contentX: CGFloat; var offset: CGFloat; var zoom: CGFloat }

    private var items: [StripItem] {
        obligations.compactMap { o in
            guard let due = o.due else { return nil }
            return StripItem(id: o.id, title: o.title, courseID: o.course?.id, courseCode: o.course?.code ?? "", courseName: o.course?.title, due: due, dueHasTime: o.dueHasTime,
                             points: o.pointsAtStake, state: o.state, completed: o.completedAt != nil)
        }
    }
    /// One band per course with items, and one for items filed under no course (documents nobody has filed yet).
    private var bands: [Band] {
        let known = Set(courses.map(\.id))
        var bands = courses.filter { c in obligations.contains { $0.course?.id == c.id } }.map { Band(id: $0.id, name: $0.displayName) }
        if obligations.contains(where: { $0.course.map { !known.contains($0.id) } ?? true }) { bands.append(Band(id: nil, name: "Unfiled")) }
        return bands
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
    private var scrubbed: Strip.Cell? { cell(for: hover ?? scrub) }
    private func cell(for day: Date?) -> Strip.Cell? {
        guard let day else { return nil }
        let period = Strip.period(containing: day, level: level, calendar: calendar)
        return Strip.cells(items.filter { period.contains($0.due) }, level: level, calendar: calendar).first ?? Strip.Cell(period: period, items: [], points: 0)
    }
    /// Under the strip: the scrubbed period's items, else what is coming up from today; in time order, heavier first on a tie.
    private var listed: [Obligation] {
        let byID = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0) })
        let chosen: [StripItem]
        if let clicked = cell(for: scrub) { chosen = clicked.items } else {
            let today = calendar.startOfDay(for: Date())
            chosen = items.filter { $0.due >= today && !$0.completed }
        }
        return chosen.sorted { $0.due != $1.due ? $0.due < $1.due : ($0.points ?? 0) > ($1.points ?? 0) }.compactMap { byID[$0.id] }
    }

    var body: some View {
        PageStack {
            GeometryReader { geo in
                let fit = geo.size.width / CGFloat(days)
                let scale = fit * clampedZoom
                let bandHeight = max(72, min(160, geo.size.height * 0.5 / CGFloat(max(bands.count, 1))))   // few courses get tall bands
                VStack(alignment: .leading, spacing: 16) {
                    #if os(iOS)
                    RangeTabs(selection: stop).padding(.horizontal, 20)
                    #endif
                    StripHeader(scrub: hover ?? scrub, level: level, cell: scrubbed, total: items.count, collisions: collisions, calendar: calendar)
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
                            StripCanvas(items: items, bands: bands, span: span, scale: scale, level: level, previousLevel: previousLevel, collisions: collisions,
                                        scrub: hover ?? scrub, reveals: reveals, now: timeline.date, bandHeight: bandHeight, axisHeight: axisHeight, calendar: calendar)
                        }
                        .frame(width: CGFloat(days) * scale, height: axisHeight + bandHeight * CGFloat(max(bands.count, 1)))
                        .contentShape(Rectangle())
                        .onTapGesture { location in scrub = day(atX: location.x, scale: scale) }
                        #if os(macOS)
                        .onContinuousHover { phase in   // the pointer reads a week or a day; a click keeps it
                            switch phase {
                            case .active(let point): hover = day(atX: point.x, scale: scale)
                            case .ended: hover = nil
                            }
                        }
                        #endif
                        .gesture(LongPressGesture(minimumDuration: 0.2).sequenced(before: DragGesture(minimumDistance: 0)).onChanged { value in
                            if case .second(true, let drag?) = value { scrub = day(atX: drag.location.x, scale: scale) }
                        })
                        .simultaneousGesture(MagnifyGesture()
                            .onChanged { value in
                                // Keep the day under the fingers where it is: scroll so that its screen position holds as the scale changes.
                                let anchor = pinch ?? PinchAnchor(contentX: value.startLocation.x, offset: scrollOffset, zoom: pinchBase)
                                if pinch == nil { pinch = anchor }
                                let level = min(max(anchor.zoom * value.magnification, 1), maxZoom)
                                zoom = level
                                let before = fit * anchor.zoom, after = fit * level
                                let screenX = anchor.contentX - anchor.offset
                                position.scrollTo(x: max(0, anchor.contentX / before * after - screenX))
                            }
                            .onEnded { _ in pinchBase = zoom; pinch = nil })
                    }
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in scrollOffset = offset }
                    .overlay(alignment: .topLeading) { bandLabels(height: bandHeight).padding(.top, axisHeight + 6) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityHint("Tap to read a week or a day. Pinch to zoom.")
                    .onChange(of: centreOn) { _, target in
                        guard let target else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))   // after the zoom animation, once the wider content exists
                            // Values captured by this closure can predate the first layout; read the geometry live.
                            let width = geo.size.width
                            let live = width / CGFloat(days) * clampedZoom
                            let target = x(of: target, scale: live) + live / 2 - width / 2
                            withAnimation { position.scrollTo(x: max(0, target)) }
                            centreOn = nil
                        }
                    }
                    List {
                        Section {
                            ForEach(listed) { obligation in
                                Button { editing = obligation } label: { ObligationRow(obligation: obligation) }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Opens the editor")
                            }
                            if listed.isEmpty { Text(scrub == nil ? "Nothing coming up." : "Nothing due.").foregroundStyle(.secondary) }
                        } header: {
                            if scrub == nil { Kicker("Coming up") }
                        }
                        .onPaper()
                    }
                    .listStyle(.plain)
                    .animation(.default, value: scrub)
                }
                .padding(.top, 8)
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

    private func runAnimation(for seconds: Double) {
        animating = true
        Task { try? await Task.sleep(for: .seconds(seconds)); animating = false }
    }

    /// A stop lands on the scrubbed day, else today.
    private func zoomTo(_ level: CGFloat) {
        withAnimation { zoom = level; pinchBase = level }
        centreOn = scrub ?? Date()
    }

    private func x(of date: Date, scale: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(span.lowerBound) / 86_400) * scale
    }

    /// The day under a touch; when a day is a few points wide, an empty day yields to a neighbour with items.
    private func day(atX x: CGFloat, scale: CGFloat) -> Date {
        let hit = calendar.date(byAdding: .day, value: Int(x / scale), to: span.lowerBound) ?? span.lowerBound
        guard level != .weeks, scale < 12, Strip.items(on: hit, in: items, calendar: calendar).isEmpty else { return hit }
        let fraction = (x / scale).truncatingRemainder(dividingBy: 1)
        for offset in fraction < 0.5 ? [-1, 1] : [1, -1] {
            if let day = calendar.date(byAdding: .day, value: offset, to: hit), !Strip.items(on: day, in: items, calendar: calendar).isEmpty { return day }
        }
        return hit
    }

    private var accessibilitySummary: String {
        let names = bands.map(\.name).joined(separator: ", ")
        let showing = switch level { case .weeks: "by week"; case .days: "by day"; case .items: "item by item" }
        return "Semester strip \(showing), \(items.count) obligations across \(names). \(collisions.isEmpty ? "No pileups." : "\(collisions.count) pileups.")"
    }

    /// Course names pinned to the leading edge, one per band, so they stay put while the strip scrolls.
    private func bandLabels(height bandHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bands) { band in
                Text(band.name)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: 170, alignment: .leading)
                    .frame(height: bandHeight, alignment: .top)
            }
        }
        .padding(.leading, 8)
        .allowsHitTesting(false)
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

/// The strip itself: an axis of months, weeks and (when there is room) days; one band per course with a baseline; at
/// the weeks and days levels a cell per period whose colour is its load and which carries its count; at the items
/// level a mark per item, its colour its weight, named when there is room. Pileup hairlines, today, the scrubbed period.
private struct StripCanvas: View {
    let items: [StripItem]
    let bands: [Band]
    let span: ClosedRange<Date>
    let scale: CGFloat
    let level: Strip.Level
    let previousLevel: (level: Strip.Level, at: Date)?
    let collisions: [Strip.Collision]
    let scrub: Date?
    let reveals: [UUID: Date]
    let now: Date
    let bandHeight: CGFloat
    let axisHeight: CGFloat
    let calendar: Calendar
    private let crossfade = 0.3

    private func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(span.lowerBound) / 86_400) * scale }
    private func bandTop(_ i: Int) -> CGFloat { axisHeight + bandHeight * CGFloat(i) }
    private func baseline(_ i: Int) -> CGFloat { bandTop(i) + bandHeight - 12 }
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
            let bandCount = max(bands.count, 1)
            let bandIndex = Dictionary(uniqueKeysWithValues: bands.enumerated().map { ($1.id, $0) })
            let loose = bandIndex[nil] ?? 0
            let byBand = Dictionary(grouping: items) { item in item.courseID.flatMap { bandIndex[$0] } ?? loose }
            let pileupIDs = Set(collisions.flatMap { $0.items.map(\.id) })

            // The scrubbed week or day: a soft column behind everything else.
            if let scrub {
                let period = Strip.period(containing: scrub, level: level, calendar: calendar)
                let sx = x(period.start)
                context.fill(Path(CGRect(x: sx, y: axisHeight - 4, width: max(x(period.end) - sx, 2), height: size.height - axisHeight + 4)), with: .color(.primary.opacity(0.07)))
            }
            // Axis: months always; week lines from a month's zoom; day numbers once a day is wide enough, every day at the items level.
            var cursor = calendar.startOfDay(for: span.lowerBound)
            while cursor <= span.upperBound {
                let comps = calendar.dateComponents([.day, .weekday], from: cursor)
                if comps.day == 1 {
                    context.draw(Text(cursor.formatted(.dateTime.month(.wide))).font(.system(.subheadline, design: .serif, weight: .semibold)).foregroundStyle(.primary),
                                 at: CGPoint(x: x(cursor) + 6, y: 6), anchor: .topLeading)
                    context.stroke(vertical(x(cursor), from: 0, to: size.height), with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                } else if comps.weekday == calendar.firstWeekday, scale >= 6 {
                    context.stroke(vertical(x(cursor), from: axisHeight - 8, to: size.height), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                }
                if scale >= 24 || (scale >= 12 && comps.weekday == calendar.firstWeekday && comps.day != 1) {
                    context.draw(Text(cursor.formatted(.dateTime.day())).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x(cursor) + scale / 2, y: axisHeight - 10), anchor: .top)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            // Bands: a baseline each.
            for i in 0..<bandCount {
                context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: baseline(i))); p.addLine(to: CGPoint(x: size.width, y: baseline(i))) }, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }
            // The content of the level, crossfading from the level just left.
            var alpha = 1.0
            if let previousLevel {
                let t = min(1, max(0, now.timeIntervalSince(previousLevel.at) / crossfade))
                if t < 1 { draw(previousLevel.level, alpha: 1 - t, byBand: byBand, pileupIDs: pileupIDs, in: &context); alpha = t }
            }
            draw(level, alpha: alpha, byBand: byBand, pileupIDs: pileupIDs, in: &context)
            // Today: a dashed line with its name, in the primary colour so it reads over the cells.
            let today = Date()
            if span.contains(today) {
                let tx = x(calendar.startOfDay(for: today)) + scale / 2
                context.stroke(vertical(tx, from: axisHeight - 2, to: size.height - 12), with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: tx, y: size.height - 1), anchor: .bottom)
            }
            // Pileups: a hairline across every band, the day named above it in the accent.
            for collision in collisions {
                let cx = x(collision.day) + scale / 2
                context.stroke(vertical(cx, from: axisHeight - 2, to: size.height - 12), with: .color(.primary.opacity(0.8)), lineWidth: 1.5)
                context.draw(Text(collision.day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accent),
                             at: CGPoint(x: cx, y: axisHeight - 4), anchor: .bottom)
            }
        }
    }

    private func draw(_ level: Strip.Level, alpha: Double, byBand: [Int: [StripItem]], pileupIDs: Set<UUID>, in context: inout GraphicsContext) {
        for (band, mine) in byBand {
            let cells = Strip.cells(mine, level: level, calendar: calendar)
            switch level {
            case .weeks, .days: drawCells(cells, band: band, alpha: alpha, in: &context)
            case .items: drawMarks(cells, band: band, alpha: alpha, pileupIDs: pileupIDs, in: &context)
            }
        }
    }

    /// One block per week or day, standing on the baseline: the accent at the load's intensity, the count inside when it fits.
    private func drawCells(_ cells: [Strip.Cell], band: Int, alpha: Double, in context: inout GraphicsContext) {
        let height = min(64, bandHeight - 30)
        for cell in cells {
            let x0 = x(cell.period.start) + 1, x1 = x(cell.period.end) - 1
            let width = max(x1 - x0, 2)
            let opacity = Strip.heat(points: cell.points) * alpha * (cell.items.map(grow).max() ?? 1)
            let rect = CGRect(x: x0, y: baseline(band) - height, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: min(4, width / 3)), with: .color(Design.accent.opacity(opacity)))
            if width >= 12, height >= 16 {
                let ink: Color = Strip.heat(points: cell.points) > 0.55 ? .black.opacity(0.75) : .primary
                context.draw(Text("\(cell.count)").font(.caption2.weight(.semibold)).foregroundStyle(ink.opacity(alpha)), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    /// One mark per item, stacked on the baseline when a day has several; its colour is its weight, review items are
    /// outlines, done items grey. The heaviest is named when the name does not run into the last one in the band.
    private func drawMarks(_ cells: [Strip.Cell], band: Int, alpha: Double, pileupIDs: Set<UUID>, in context: inout GraphicsContext) {
        let w = min(scale * 0.6, 16), h: CGFloat = 12, gap: CGFloat = 3
        let stack = max(1, Int((bandHeight - 30) / (h + gap)))
        var lastLabelEnd: CGFloat = -.infinity
        for cell in cells {
            let cx = x(cell.period.start) + scale / 2
            var top = baseline(band)
            for item in cell.items.prefix(stack) {
                let g = grow(item)
                let rect = CGRect(x: cx - w / 2, y: top - h * g, width: w, height: h * g)
                let path = Path(roundedRect: rect, cornerRadius: min(3, w / 2))
                let color: Color = item.completed ? .secondary : Design.accent
                let opacity = (item.completed ? 0.35 : Strip.heat(points: item.points)) * alpha
                switch item.state {
                case .pendingReview, .awaitingDate: context.stroke(path, with: .color(color.opacity(max(opacity, 0.6 * alpha))), lineWidth: 1.5)
                default: context.fill(path, with: .color(color.opacity(opacity)))
                }
                top = rect.minY - gap
            }
            guard let first = cell.items.first, grow(first) >= 1, cx - 30 >= lastLabelEnd else { continue }
            let heavy = (first.points ?? 0) >= Strip.heavyPoints
            let more = cell.count > 1 ? " +\(cell.count - 1)" : ""
            let label = Text(first.title + more).font(.caption2.weight(heavy ? .semibold : .regular)).foregroundStyle((pileupIDs.contains(first.id) ? Design.accent : .primary).opacity((first.completed ? 0.4 : 1) * alpha))
            let resolved = context.resolve(label)
            let width = resolved.measure(in: CGSize(width: 140, height: 30)).width
            context.draw(resolved, at: CGPoint(x: cx, y: top - 1), anchor: .bottom)
            lastLabelEnd = cx + width / 2 + 6
        }
    }
}
