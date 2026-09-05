import SwiftUI
import SwiftData
import HorizonCore

/// The app's screens (SPEC §6): Coverage, the Horizon strip, and Now.
struct MainTabs: View {
    /// `--tab-horizon` / `--tab-now` (DEBUG) open on a tab, for screenshots from the command line.
    @State private var tab = Self.debugFlag("--tab-horizon") ? 1 : Self.debugFlag("--tab-now") ? 2 : 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Coverage", systemImage: "eye", value: 0) { RootView() }
            Tab("Horizon", systemImage: "chart.bar.xaxis", value: 1) { HorizonStripView() }
            Tab("Now", systemImage: "sun.horizon", value: 2) { NowView() }
        }
    }

    static func debugFlag(_ flag: String) -> Bool {
        #if DEBUG
        CommandLine.arguments.contains(flag)
        #else
        false
        #endif
    }
}

/// SPEC §6.2: one continuous strip of the term. A mark's height and width follow its points at stake, courses sit in
/// bands, heavy marks carry their names, and days where heavy items pile up are called out in the accent. A pinch zooms
/// around the fingers, from the whole semester to two weeks across the width; a tap or a press-and-drag scrubs a day
/// into the header. New marks grow in as a document resolves.
struct HorizonStripView: View {
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.due != nil }, sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var zoom: CGFloat = 1            // 1 = the whole semester across the width
    @State private var pinchBase: CGFloat = 1
    @State private var pinch: PinchAnchor?
    @State private var scrollOffset: CGFloat = 0
    @State private var position = ScrollPosition()
    @State private var scrub: Date?
    @State private var reveals: [UUID: Date] = [:]  // when each mark first appeared, so new ones grow in
    @State private var seeded = false
    @State private var animating = false
    @State private var centreOn: Date?               // a menu zoom lands on the scrubbed day, else today
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
    private var bands: [Course] { courses.filter { c in obligations.contains { $0.course?.id == c.id } } }
    private var span: ClosedRange<Date> {
        Strip.span(termStarts: courses.compactMap(\.termStart), termEnds: courses.compactMap(\.termEnd), items: items, now: Date(), calendar: calendar)
    }
    private var days: Int { max(1, calendar.dateComponents([.day], from: span.lowerBound, to: span.upperBound).day ?? 1) }
    private var collisions: [Strip.Collision] { Strip.collisions(items, calendar: calendar) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fit = geo.size.width / CGFloat(days)
                let maxZoom = max(1, CGFloat(days) / 14)                 // two weeks across the width
                let scale = fit * min(max(zoom, 1), maxZoom)
                let bandHeight = max(72, min(160, geo.size.height * 0.5 / CGFloat(max(bands.count, 1))))   // few courses get tall bands
                VStack(alignment: .leading, spacing: 16) {
                    StripHeader(scrub: scrub, items: scrub.map { Strip.items(on: $0, in: items, calendar: calendar) } ?? [],
                                total: items.count, collisions: collisions, calendar: calendar)
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
                            StripCanvas(items: items, bands: bands, span: span, scale: scale, collisions: collisions, scrub: scrub,
                                        reveals: reveals, now: timeline.date, bandHeight: bandHeight, axisHeight: axisHeight, calendar: calendar)
                        }
                        .frame(width: CGFloat(days) * scale, height: axisHeight + bandHeight * CGFloat(max(bands.count, 1)))
                        .contentShape(Rectangle())
                        .onTapGesture { location in scrub = day(atX: location.x, scale: scale) }
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
                    .accessibilityHint("Tap a day to read it. Pinch to zoom.")
                    .onChange(of: centreOn) { _, target in
                        guard let target else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))   // after the zoom animation, once the wider content exists
                            // Values captured by this closure can predate the first layout; read the geometry live.
                            let width = geo.size.width
                            let live = width / CGFloat(days) * min(max(zoom, 1), max(1, CGFloat(days) / 14))
                            let target = x(of: target, scale: live) + live / 2 - width / 2
                            withAnimation { position.scrollTo(x: max(0, target)) }
                            centreOn = nil
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .onAppear { if MainTabs.debugFlag("--zoom-two-weeks"), zoom == 1 { zoomTo(maxZoom) } }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Zoom") {
                            Button("Whole Semester") { withAnimation { zoom = 1; pinchBase = 1 } }
                            Button("Month") { zoomTo(min(maxZoom, CGFloat(days) / 30)) }
                            Button("Two Weeks") { zoomTo(maxZoom) }
                        }
                    }
                }
            }
            .navigationTitle("Horizon")
            .onChange(of: obligations.map(\.id), initial: true) { _, ids in
                let now = Date()
                if !seeded { for id in ids { reveals[id] = .distantPast }; seeded = true; return }   // what is already on file simply is
                let fresh = ids.filter { reveals[$0] == nil }
                guard !fresh.isEmpty else { return }
                for id in fresh { reveals[id] = now }
                animating = true
                Task { try? await Task.sleep(for: .seconds(0.9)); animating = false }
            }
        }
    }

    /// A menu zoom lands on the scrubbed day, else today.
    private func zoomTo(_ level: CGFloat) {
        withAnimation { zoom = level; pinchBase = level }
        centreOn = scrub ?? Date()
    }

    private func x(of date: Date, scale: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(span.lowerBound) / 86_400) * scale
    }

    /// The day under a touch; at the semester zoom a day is a few points wide, so an empty day yields to a neighbour with items.
    private func day(atX x: CGFloat, scale: CGFloat) -> Date {
        let hit = calendar.date(byAdding: .day, value: Int(x / scale), to: span.lowerBound) ?? span.lowerBound
        guard scale < 12, Strip.items(on: hit, in: items, calendar: calendar).isEmpty else { return hit }
        let fraction = (x / scale).truncatingRemainder(dividingBy: 1)
        for offset in fraction < 0.5 ? [-1, 1] : [1, -1] {
            if let day = calendar.date(byAdding: .day, value: offset, to: hit), !Strip.items(on: day, in: items, calendar: calendar).isEmpty { return day }
        }
        return hit
    }

    private var accessibilitySummary: String {
        let names = bands.map(\.displayName).joined(separator: ", ")
        return "Semester strip, \(items.count) obligations across \(names). \(collisions.isEmpty ? "No pileups." : "\(collisions.count) pileups.")"
    }

    /// Course names pinned to the leading edge, one per band, so they stay put while the strip scrolls.
    private func bandLabels(height bandHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bands) { course in
                Text(course.displayName)
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

/// The scrubbed day, or the semester at a glance. Type carries it; the accent marks a pileup.
private struct StripHeader: View {
    let scrub: Date?
    let items: [StripItem]
    let total: Int
    let collisions: [Strip.Collision]
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scrub {
                let pileup = collisions.contains { calendar.isDate($0.day, inSameDayAs: scrub) }
                Text(pileup ? "Pileup" : "Day").font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(pileup ? Design.accent : .secondary)
                Text(scrub.formatted(.dateTime.weekday(.wide).month(.wide).day())).deck().contentTransition(.numericText())
                if items.isEmpty {
                    Text("Nothing due.").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title).font(.body.weight(.medium))
                        Text(item.courseName).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Design.points(item.points).font(.title3.weight(.medium))
                    }
                }
            } else {
                Text("Semester").font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(.secondary)
                Text(summary).deck()
                Text("Tap a day to read it. Pinch to zoom.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: scrub)
    }

    private var summary: String {
        let pileups = collisions.count == 0 ? "no pileups" : collisions.count == 1 ? "one pileup" : "\(collisions.count) pileups"
        return "\(total) obligation\(total == 1 ? "" : "s") on the horizon, \(pileups)."
    }
}

/// The strip itself: an axis of months, weeks and (when there is room) days; one band per course with a baseline; marks
/// whose height and width carry their weight, named when heavy or when there is room; pileup hairlines; today; the scrubbed day.
private struct StripCanvas: View {
    let items: [StripItem]
    let bands: [Course]
    let span: ClosedRange<Date>
    let scale: CGFloat
    let collisions: [Strip.Collision]
    let scrub: Date?
    let reveals: [UUID: Date]
    let now: Date
    let bandHeight: CGFloat
    let axisHeight: CGFloat
    let calendar: Calendar

    var body: some View {
        Canvas { context, size in
            func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(span.lowerBound) / 86_400) * scale }
            func vertical(_ px: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Path {
                Path { p in p.move(to: CGPoint(x: px, y: y0)); p.addLine(to: CGPoint(x: px, y: y1)) }
            }
            let bandTop: (Int) -> CGFloat = { axisHeight + bandHeight * CGFloat($0) }
            let baseline: (Int) -> CGFloat = { bandTop($0) + bandHeight - 12 }
            let bandCount = max(bands.count, 1)

            // The scrubbed day: a soft column behind everything else.
            if let scrub {
                let sx = x(calendar.startOfDay(for: scrub))
                context.fill(Path(CGRect(x: sx, y: axisHeight - 4, width: max(scale, 2), height: size.height - axisHeight + 4)), with: .color(.primary.opacity(0.07)))
            }
            // Axis: months always; weeks from a month's zoom; day numbers from two weeks'.
            var cursor = calendar.startOfDay(for: span.lowerBound)
            while cursor <= span.upperBound {
                let comps = calendar.dateComponents([.day, .weekday], from: cursor)
                if comps.day == 1 {
                    context.draw(Text(cursor.formatted(.dateTime.month(.wide))).font(.subheadline.weight(.semibold)).foregroundStyle(.primary),
                                 at: CGPoint(x: x(cursor) + 6, y: 6), anchor: .topLeading)
                    context.stroke(vertical(x(cursor), from: 0, to: size.height), with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                } else if comps.weekday == 2, scale >= 6 {
                    context.stroke(vertical(x(cursor), from: axisHeight - 8, to: size.height), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                    if scale >= 18 {
                        context.draw(Text(cursor.formatted(.dateTime.day())).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x(cursor) + 3, y: axisHeight - 10), anchor: .topLeading)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            // Bands: a baseline each, the marks stand on it.
            for i in 0..<bandCount {
                context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: baseline(i))); p.addLine(to: CGPoint(x: size.width, y: baseline(i))) }, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }
            // Today: an accent line with its name.
            let today = Date()
            if span.contains(today) {
                let tx = x(calendar.startOfDay(for: today)) + scale / 2
                context.stroke(vertical(tx, from: axisHeight - 2, to: size.height - 12), with: .color(Design.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.draw(Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(Design.accent), at: CGPoint(x: tx, y: size.height - 1), anchor: .bottom)
            }
            // Pileups: a hairline across every band, the day named above it.
            let pileupIDs = Set(collisions.flatMap { $0.items.map(\.id) })
            for collision in collisions {
                let cx = x(collision.day) + scale / 2
                context.stroke(vertical(cx, from: axisHeight - 2, to: size.height), with: .color(Design.accent), lineWidth: 1)
                context.draw(Text(collision.day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.weight(.bold)).foregroundStyle(Design.accent),
                             at: CGPoint(x: cx, y: axisHeight - 4), anchor: .bottom)
            }
            // Marks: height and width carry the weight; review items are outlines; pileup items take the accent; heavy
            // marks are named, and every mark is named once there is room, without overlapping the last name in the band.
            let bandIndex = Dictionary(uniqueKeysWithValues: bands.enumerated().map { ($1.id, $0) })
            var lastLabelEnd: [Int: CGFloat] = [:]
            for item in items.sorted(by: { $0.due < $1.due }) {
                let band = item.courseID.flatMap { bandIndex[$0] } ?? 0
                let mass = Strip.mass(points: item.points)
                var grow = 1.0
                if let start = reveals[item.id], start != .distantPast {
                    let t = min(1, max(0, now.timeIntervalSince(start) / 0.6))
                    grow = 1 - pow(1 - t, 3)
                }
                let h = max(3, (bandHeight - 30) * mass * grow)
                let w = max(3 + 5 * mass, min(scale * 0.7, 16) * (0.5 + mass))
                let cx = x(item.due) + scale / 2
                let rect = CGRect(x: cx - w / 2, y: baseline(band) - h, width: w, height: h)
                let path = Path(roundedRect: rect, cornerRadius: min(3, w / 2))
                let color: Color = pileupIDs.contains(item.id) ? Design.accent : .primary
                switch item.state {
                case .pendingReview, .awaitingDate: context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1.5)
                default: context.fill(path, with: .color(color.opacity(item.completed ? 0.25 : 0.9)))
                }
                let named = mass >= 0.5 || scale >= 20
                if named, grow >= 1, cx - 30 >= (lastLabelEnd[band] ?? -.infinity) {
                    let label = Text(item.title).font(.caption2.weight(mass >= 0.5 ? .semibold : .regular)).foregroundStyle(color.opacity(item.completed ? 0.4 : 1))
                    let resolved = context.resolve(label)
                    let width = resolved.measure(in: CGSize(width: 140, height: 30)).width
                    context.draw(resolved, at: CGPoint(x: cx, y: rect.minY - 3), anchor: .bottom)
                    lastLabelEnd[band] = cx + width / 2 + 6
                }
            }
        }
    }
}
