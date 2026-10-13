import WidgetKit
import SwiftUI
import HorizonCore

// SPEC §7's widgets: on the Lock Screen the one item that matters most next, ranked by its weight in the grade, not
// by its date; on the Home Screen the coming week of the strip. Both draw the glance the app keeps in the App Group
// (`Glance`), worked out a week ahead with an entry wherever what is shown changes by itself, so they stay right while
// the app sleeps; the extension never opens the store.

struct GlanceEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written a glance (just installed): the widget says to open it.
    let glance: Glance.Entry?
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { GlanceEntry(date: .now, glance: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let entry = Self.read()?.entry(at: .now)
        completion(GlanceEntry(date: .now, glance: context.isPreview && entry == nil ? Self.sample : entry))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        guard let glance = Self.read(), !glance.entries.isEmpty else {
            completion(Timeline(entries: [GlanceEntry(date: .now, glance: nil)], policy: .after(.now.addingTimeInterval(3600))))
            return
        }
        // From the entry under way on; the app reloads the timelines whenever it writes a new glance.
        let now = Date()
        let current = glance.entry(at: now)
        let ahead = glance.entries.filter { $0.date > now }
        let entries = [GlanceEntry(date: now, glance: current)] + ahead.map { GlanceEntry(date: $0.date, glance: $0) }
        let last = glance.entries.last?.date ?? now
        completion(Timeline(entries: entries, policy: .after(max(last, now.addingTimeInterval(3600)))))
    }

    static func read() -> Glance? { Glance.sharedURL.flatMap(Glance.read(from:)) }

    /// The gallery's picture of a week, before there is one of the user's own.
    static var sample: Glance.Entry {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today) ?? today }
        let next = Glance.Item(id: UUID(), title: "Midterm 1", course: "Calculus II", due: day(3).addingTimeInterval(9 * 3600), dueHasTime: true, points: 25, inReview: false)
        let loads: [(Int, Double, Bool, String?)] = [(1, 2, false, "Problem Set 4"), (0, 0, false, nil), (2, 6, false, "Quiz 3"), (2, 45, true, "Midterm 1"), (1, 4, false, "Lab 2"), (0, 0, false, nil), (1, 3, false, "Reading Response")]
        let week = loads.enumerated().map { i, load in
            Glance.Day(day: day(i), count: load.0, points: load.1, heat: load.0 == 0 ? 0 : Strip.heat(points: load.1), pileup: load.2, heaviest: load.3)
        }
        return Glance.Entry(date: .now, next: next, week: week)
    }
}

/// The app's own colours, as the widget extension cannot see the app's assets.
enum GlanceDesign {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let paper = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.082, green: 0.078, blue: 0.071, alpha: 1) : UIColor(red: 0.976, green: 0.965, blue: 0.941, alpha: 1) })
    /// Words in the accent's place: the deeper amber on light paper, the orange at night (the app's `accentInk`).
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1.0, green: 0.68, blue: 0.26, alpha: 1) : UIColor(red: 0.659, green: 0.353, blue: 0.0, alpha: 1) })

    static func weight(_ points: Double?) -> String? { points.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } }

    static func due(_ item: Glance.Item) -> String {
        let calendar = Calendar.current
        let day: String = calendar.isDateInToday(item.due) ? "Today" : calendar.isDateInTomorrow(item.due) ? "Tomorrow" : item.due.formatted(.dateTime.weekday(.abbreviated))
        return item.dueHasTime ? "\(day) \(item.due.formatted(date: .omitted, time: .shortened))" : day
    }

    static func link(_ item: Glance.Item?) -> URL {
        URL(string: item.map { "horizon://obligation/\($0.id.uuidString)" } ?? "horizon://page/horizon")!
    }
}

// MARK: The one item that matters most next

struct NextItemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextItem", provider: GlanceProvider()) { entry in
            NextItemView(entry: entry)
                .containerBackground(for: .widget) { GlanceDesign.paper }
                .widgetURL(GlanceDesign.link(entry.glance?.next))
        }
        .configurationDisplayName("Next by Weight")
        .description("See the item worth the most of your grade in the next two weeks.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall])
    }
}

struct NextItemView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let glance = entry.glance {
            if let next = glance.next { item(next) } else { nothing("Nothing due in the next two weeks.") }
        } else {
            nothing("Open Horizon to begin.")
        }
    }

    @ViewBuilder private func item(_ next: Glance.Item) -> some View {
        switch family {
        case .accessoryInline:
            Text([next.title, GlanceDesign.due(next), GlanceDesign.weight(next.points)].compactMap { $0 }.joined(separator: " · "))
        case .accessoryCircular:
            // The ring is the item's weight (40% fills it); the middle, how soon.
            Gauge(value: min((next.points ?? 0) / 40, 1)) { Text("Next") } currentValueLabel: { Text(Self.soon(next.due)).font(.system(.body, design: .serif, weight: .semibold)) }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("NEXT BY WEIGHT").font(.caption2).kerning(0.6)
                    Spacer(minLength: 0)
                    if let weight = GlanceDesign.weight(next.points) { Text(weight).font(.caption2.weight(.bold)).widgetAccentable() }
                }
                Text(next.title).font(.system(.headline, design: .serif)).lineLimit(1).widgetAccentable()
                Text([next.course, GlanceDesign.due(next)].compactMap { $0 }.joined(separator: " · ")).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT BY WEIGHT").font(.caption2).kerning(0.8).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(next.title).font(.system(.title3, design: .serif, weight: .semibold)).lineLimit(3).minimumScaleFactor(0.8)
                if let course = next.course { Text(course).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(alignment: .firstTextBaseline) {
                    Text(GlanceDesign.due(next)).font(.caption.weight(.medium)).monospacedDigit()
                    Spacer(minLength: 4)
                    if let weight = GlanceDesign.weight(next.points) {
                        Text(weight).font(.system(.title2, design: .serif, weight: .bold)).foregroundStyle(GlanceDesign.ink).monospacedDigit().widgetAccentable()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func nothing(_ line: String) -> some View {
        switch family {
        case .accessoryInline: Text(line)
        case .accessoryCircular: Image(systemName: "checkmark").font(.title3)
        default: Text(line).font(.system(.callout, design: .serif)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// "4h", "3d": how soon, in the one unit that matters.
    static func soon(_ due: Date) -> String {
        let hours = max(0, due.timeIntervalSinceNow / 3600)
        return hours < 24 ? "\(Int(hours.rounded(.up)))h" : "\(Int((hours / 24).rounded(.up)))d"
    }
}

// MARK: The coming week of the strip

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Week", provider: GlanceProvider()) { entry in
            WeekView(entry: entry)
                .containerBackground(for: .widget) { GlanceDesign.paper }
                .widgetURL(URL(string: "horizon://page/horizon")!)
        }
        .configurationDisplayName("The Week Ahead")
        .description("See the next seven days of the semester strip: how much falls due each day, and where it piles up.")
        .supportedFamilies([.systemMedium])
    }
}

struct WeekView: View {
    let entry: GlanceEntry
    @Environment(\.widgetRenderingMode) private var rendering

    var body: some View {
        if let glance = entry.glance {
            let week = glance.week
            let count = week.reduce(0) { $0 + $1.count }
            let pileups = week.filter(\.pileup).count
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("THE WEEK AHEAD").font(.caption2).kerning(0.8).foregroundStyle(.secondary)
                    Spacer()
                    Text(count == 0 ? "Nothing due" : "\(count) due" + (pileups > 0 ? " · \(pileups) pileup\(pileups == 1 ? "" : "s")" : ""))
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    ForEach(week) { day in
                        Link(destination: URL(string: "horizon://horizon?day=\(Self.dayString(day.day))")!) { column(day) }
                    }
                }
                if let next = glance.next {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Heaviest next").font(.caption2).foregroundStyle(.secondary)
                        Text(next.title).font(.system(.footnote, design: .serif, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text([GlanceDesign.due(next), GlanceDesign.weight(next.points)].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } else {
            Text("Open Horizon to see your week.").font(.system(.callout, design: .serif)).foregroundStyle(.secondary)
        }
    }

    private func column(_ day: Glance.Day) -> some View {
        VStack(spacing: 3) {
            Text(day.day.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 5).fill(fill.opacity(day.heat))   // the strip's colour: the share of the grade that day
                if day.count > 0 { Text("\(day.count)").font(.caption.weight(.bold)).monospacedDigit() }
            }
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                if day.pileup { Capsule().fill(GlanceDesign.ink).frame(height: 3).padding(.horizontal, 6).offset(y: 5).widgetAccentable() }   // a pileup starts here
            }
            Text(day.day.formatted(.dateTime.day())).font(.caption2).monospacedDigit().foregroundStyle(.secondary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.day.formatted(.dateTime.weekday(.wide).month().day())): \(day.count == 0 ? "nothing due" : "\(day.count) due")\(day.pileup ? ", a pileup" : "")")
    }

    private var fill: Color { rendering == .fullColor ? GlanceDesign.accent : .primary }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
