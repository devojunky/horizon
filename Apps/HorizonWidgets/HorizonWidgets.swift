import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct HorizonWidgets: WidgetBundle {
    var body: some Widget {
        PlanLiveActivity()
        NextItemWidget()
        WeekWidget()
        ReadScreenshotControl()
        PlanDayControl()
    }
}

private typealias Phase = PlanActivityAttributes.Phase
private typealias Block = PlanActivityAttributes.Block

/// Today's plan on the Lock Screen and in the Dynamic Island: the block on now with the time left, or the one up next
/// and when, or, once a work block is over, whether it was finished. Done and Skip act on the block without opening
/// the app; the answer to "finished?" is Done or Not Yet, and a question left unanswered times out as not finished.
/// Set like the app's timetable: a caps kicker, a serif title, the marker orange for the block that is on.
///
/// Every presentation works from `ContentState.phase(at:)`, not from what the app last said: the system draws the
/// activity again at its stale date, which the app sets to the first moment the phase changes, and the views then
/// show what that moment is. The Dynamic Island says less than the Lock Screen (HIG: only the space the content needs,
/// large heavier text): which block, its hours, the time left, its name and the actions. The reason and what comes
/// after are the Lock Screen's.
struct PlanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlanActivityAttributes.self) { context in
            LockScreenPlan(state: context.state, phase: context.state.phase(at: .now))
                .padding(14)   // the HIG's standard margin on the Lock Screen
                .widgetURL(PlanLiveActivity.nowLink)
        } dynamicIsland: { context in
            let phase = context.state.phase(at: .now)
            return DynamicIsland {
                // Beside the camera: which block this is and when, and the time left. Under it, one row: the block's name
                // with the width to be read, and the actions. Nothing sits in the centre, squeezed by the camera.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ActivityKicker(phase.kicker, accent: phase.accented)
                        if let block = phase.block { Text(Clock.range(block)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    // A region is clipped to the island's shape drawn in by its margin, so its own top corner is round too, and
                    // a letter set right in that corner loses its shoulder (HIG: never draw to the island's edge; keep content
                    // concentric with it). In from the corner and down from the top, the kicker clears the curve.
                    .padding(.leading, Self.cornerClearance).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {   // sized first: the one figure that changes is never the one to give way
                    Group {   // against the trailing edge, as the kicker is against the leading: the two read as the island's ends
                        switch phase {
                        case .on(let block): Countdown(block: block, on: true)
                        case .upNext(let block): Countdown(block: block, on: false)
                        case .asking, .done: EmptyView()   // nothing counts down: the question waits on the user
                        }
                    }
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .padding(.trailing, Self.cornerClearance).padding(.top, 4)   // the same clearance at the other corner; the figure is as wide as it needs and no wider, so it stays beside the camera
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)   // beside the camera when it fits, under it rather than cut off when it does not
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(phase.block?.title ?? "Today's plan is done.").font(.system(.title3, design: .serif, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                        ActivityActions(phase: phase)
                    }
                    .padding(.horizontal, Self.cornerClearance).padding(.bottom, 4)   // in line with the kicker and the countdown above, and clear of the lower corners
                }
            } compactLeading: {   // the leading and trailing read as one unit: the sun, then the time it stands for
                Image(systemName: phase.accented ? "sun.horizon.fill" : "sun.horizon").foregroundStyle(ActivityDesign.accent).padding(.leading, 4)
            } compactTrailing: {
                ShortTime(phase: phase).font(.subheadline.weight(.semibold)).padding(.trailing, 2)
            } minimal: {   // the minimal shows what changes (the time left), not a logo
                ShortTime(phase: phase, minimal: true).font(.caption2.weight(.semibold))
            }
            .widgetURL(PlanLiveActivity.nowLink)
            .keylineTint(ActivityDesign.accent)
        }
    }

    /// A tap anywhere opens the app on Now.
    static let nowLink = URL(string: "horizon://now")!
    /// How far the expanded island's content stays from the sides of its regions, so that nothing sits in a rounded corner.
    static let cornerClearance: CGFloat = 12
}

private extension PlanActivityAttributes.Phase {
    var block: Block? {
        switch self { case .on(let b), .upNext(let b), .asking(let b): b; case .done: nil }
    }
    var kicker: String {
        switch self { case .on: "Now"; case .upNext: "Up next"; case .asking: "Finished?"; case .done: "Done" }
    }
    /// The block that is on, and the question: the accent, and the filled sun.
    var accented: Bool {
        switch self { case .on, .asking: true; case .upNext, .done: false }
    }
}

/// The Lock Screen banner.
private struct LockScreenPlan: View {
    let state: PlanActivityAttributes.ContentState
    let phase: Phase

    var body: some View {
        switch phase {
        case .on(let block), .upNext(let block):
            let on = phase.accented
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ActivityKicker(phase.kicker, accent: on)
                    Text(Clock.range(block)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Countdown(block: block, on: on).font(.system(.title3, design: .serif, weight: .semibold))
                }
                // The banner has about 160 points (HIG): the title comes first, the reason gets what is left.
                Text(block.title).font(.system(.title2, design: .serif, weight: .semibold)).lineLimit(2).layoutPriority(1)
                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 12) {
                    if on {
                        ProgressView(timerInterval: block.start...block.end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                            .tint(ActivityDesign.accent)
                    } else {
                        Text(state.done > 0 ? "\(state.done) of \(state.total) done" : then(after: block) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    ActivityActions(phase: phase)
                }
                if on, block.reason.isEmpty, let line = then(after: block) { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }   // "Then …" only where the reason left room
            }
        case .asking(let block):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ActivityKicker(phase.kicker, accent: true)
                    Text(Clock.range(block)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                }
                Text(block.title).font(.system(.title2, design: .serif, weight: .semibold)).lineLimit(2)
                HStack(spacing: 12) {
                    Text(then(after: block) ?? "The last block of the day.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    ActivityActions(phase: phase)
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                ActivityKicker("Done", accent: true)
                Text("Today's plan is done.").font(.system(.title2, design: .serif, weight: .semibold))
                Text("\(state.done) of \(state.total) done.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// What comes after `block`, in a line: the block that is on while this one asks, or the one up next.
    private func then(after block: Block) -> String? {
        let following = [state.current, state.next].compactMap { $0 }.first { $0.id != block.id && $0.start >= block.start }
        guard let following else { return nil }
        return following.start <= .now ? "Then \(following.title), on now" : "Then \(following.title) at \(Clock.time(following.start))"
    }
}

/// What a block's phase lets the user do from the activity: Done and Skip while it is on, Skip while it is ahead, and the
/// answer to "finished?" (Done, or Not Yet) once it is over. The main action sits at the trailing end. The buttons keep
/// their size (a label never wraps in a capsule); the block's name beside them is what gives way.
private struct ActivityActions: View {
    let phase: Phase
    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .on(let block):
                SkipButton(block: block, title: "Skip")
                DoneButton(block: block)
            case .upNext(let block):
                SkipButton(block: block, title: "Skip")
            case .asking(let block):
                SkipButton(block: block, title: "Not Yet")
                DoneButton(block: block)
            case .done:
                EmptyView()
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }
}

/// Counts down to the end of the block that is on, or to the start of the one ahead, to the second: the expanded
/// island and the Lock Screen.
///
/// A timer's text is drawn by the system after the view has been archived, in a frame the view no longer controls: it
/// takes all the width it is offered, sets itself at the start of it, and is cut off where the frame ends. So the
/// frame is made here, from the widest figure this countdown can show (hidden, in the same type), and the timer sits
/// in it against the trailing edge, on one line, shrinking before it is ever clipped.
private struct Countdown: View {
    let block: Block
    let on: Bool

    /// The widest the figure gets: minutes and seconds for the block that is on (a long block counts past 99
    /// minutes), hours too for one more than an hour ahead.
    private var widest: String {
        if on { return block.end.timeIntervalSince(block.start) >= 6000 ? "000:00" : "00:00" }
        let ahead = block.start.timeIntervalSinceNow
        return ahead >= 36_000 ? "00:00:00" : ahead >= 3600 ? "0:00:00" : "00:00"
    }

    var body: some View {
        Text(widest).monospacedDigit().lineLimit(1).fixedSize().hidden()
            .overlay(alignment: .trailing) { timer.monospacedDigit().multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.7) }
    }

    @ViewBuilder private var timer: some View {
        if on {
            Text(timerInterval: block.start...block.end, countsDown: true, showsHours: false).contentTransition(.numericText())
        } else {   // to the start; the range must stay ordered when the system re-renders after the start has passed
            let from = min(Date(), block.start.addingTimeInterval(-1))
            Text(timerInterval: from...block.start, countsDown: true, showsHours: true)
        }
    }
}

/// The time in a word, for the island's slots beside the camera (52 to 62 points) and the minimal presentation (36 to
/// 45): "39m" left, or "1h 5m"; "in 39m" or "in 2h 5m" for the block ahead; "Done?" while a block asks. No seconds: at
/// a glance a minute is the grain. Both figures are system styles the island keeps ticking by itself, and both count
/// whole minutes up (a block with 40 seconds to go says "1m", never "0m") and stop at zero. The time left above an hour takes two units ("1h 5m"): the two ways to a bare "1h" that counts down,
/// the one-unit `Duration` style and a format style of the app's own, each stopped the whole activity from drawing in
/// the simulator (a blank banner, a placeholder). Framed like `Countdown`: the widest figure it can show, hidden, and
/// the live one against its trailing edge.
private struct ShortTime: View {
    let phase: Phase
    var minimal = false

    var body: some View {
        switch phase {
        case .on(let block):
            let end = block.end.addingTimeInterval(59)   // whole minutes, counted up
            framed(widest: end.timeIntervalSinceNow >= 36_000 ? "00h 00m" : end.timeIntervalSinceNow >= 3600 ? "0h 00m" : "00m") {
                Text(.dateRange(endingAt: end), format: .components(style: .narrow, fields: [.hour, .minute]))
            }
        case .upNext(let block):
            // Counted the way the time left is (whole minutes, up), and stopping at "in 0m": a relative style ran on
            // past the start ("6s ago") when nothing drew the activity again at its stale date (seen in the simulator).
            let start = block.start.addingTimeInterval(59)
            framed(widest: start.timeIntervalSinceNow >= 3600 ? "in 0h 00m" : "in 00m") {
                Text("in \(Text(.dateRange(endingAt: start), format: .components(style: .narrow, fields: [.hour, .minute])))")
            }
        case .asking:
            if minimal { Image(systemName: "questionmark").foregroundStyle(ActivityDesign.accent) }
            else { Text("Done?").foregroundStyle(ActivityDesign.accent).lineLimit(1).fixedSize() }
        case .done:
            Image(systemName: "checkmark").foregroundStyle(ActivityDesign.accent)
        }
    }

    private func framed(widest: String, @ViewBuilder _ figure: () -> some View) -> some View {
        Text(widest).monospacedDigit().lineLimit(1).fixedSize().hidden()
            .overlay(alignment: .trailing) { figure().monospacedDigit().multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.7) }
    }
}

/// Marks the block done in the app without opening it.
private struct DoneButton: View {
    let block: Block
    var body: some View {
        Button(intent: MarkBlockDoneIntent(blockID: block.id)) {
            Label("Done", systemImage: "checkmark").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(ActivityDesign.ink)   // white on the deeper amber reads at 5:1; on the bright orange it was under 2:1
        .controlSize(.small)
    }
}

/// Sets the block aside in the app without opening it: Skip before it is over, Not Yet as the answer once it is.
private struct SkipButton: View {
    let block: Block
    let title: String
    var body: some View {
        Button(intent: SkipBlockIntent(blockID: block.id)) {
            Text(title).font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.primary)   // secondary to Done: the system's grey capsule, readable on the black island and the Lock Screen alike
        .controlSize(.small)
    }
}

/// The app's caps kicker, in the widget's own words.
private struct ActivityKicker: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }
    var body: some View {
        // Words take the ink, not the orange: on the light Lock Screen the orange reads at about 1.8:1 (the app's rule).
        Text(text).font(.caption2).textCase(.uppercase).kerning(1).foregroundStyle(accent ? GlanceDesign.ink : .secondary)
    }
}

enum ActivityDesign {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    /// The app's `Design.accentInk` in light: a fill under white words.
    static let ink = Color(red: 0.659, green: 0.353, blue: 0.0)
}

enum Clock {
    static func time(_ date: Date) -> String { date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)).minute()) }
    static func range(_ block: PlanActivityAttributes.Block) -> String { "\(time(block.start)) – \(time(block.end))" }
}
