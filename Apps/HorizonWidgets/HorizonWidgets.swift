import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct HorizonWidgets: WidgetBundle {
    var body: some Widget {
        PlanLiveActivity()
    }
}

/// Today's plan on the Lock Screen and in the Dynamic Island: the block on now with a live countdown, or the one up
/// next and when, and a Done button that marks it in the app. Set like the app's timetable: a caps kicker, a serif
/// title, the marker orange for the block that is on.
///
/// The Dynamic Island says less than the Lock Screen, on purpose (HIG: use only the space the content needs, large
/// heavier text, small text sparingly, one action): what is on, how long is left, and Done. The block's reason and
/// what comes after it are the Lock Screen's and the app's to say; in the island they were two lines of small grey
/// type competing with the one figure that changes.
struct PlanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlanActivityAttributes.self) { context in
            LockScreenPlan(state: context.state)
                .padding(14)   // the HIG's standard margin on the Lock Screen
                .widgetURL(PlanLiveActivity.nowLink)
        } dynamicIsland: { context in
            let state = context.state
            let block = state.current ?? state.next
            return DynamicIsland {
                // Beside the camera: which block this is and when, and the time left. Under it, one row: the block's name
                // with the width to be read, and the one action. Nothing sits in the centre, squeezed by the camera.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ActivityKicker(state.current != nil ? "Now" : state.finished ? "Done" : "Up next", accent: state.current != nil)
                        if let block { Text(Clock.range(block)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    // A region is clipped to the island's shape drawn in by its margin, so its own top corner is round too, and
                    // a letter set right in that corner loses its shoulder (HIG: never draw to the island's edge; keep content
                    // concentric with it). In from the corner and down from the top, the kicker clears the curve.
                    .padding(.leading, Self.cornerClearance).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {   // sized first: the one figure that changes is never the one to give way
                    if let block {   // against the trailing edge, as the kicker is against the leading: the two read as the island's ends
                        Countdown(block: block, on: state.current != nil).font(.system(.title3, design: .serif, weight: .semibold))
                            .padding(.trailing, Self.cornerClearance).padding(.top, 4)   // the same clearance at the other corner; the figure is as wide as it needs and no wider, so it stays beside the camera
                            .dynamicIsland(verticalPlacement: .belowIfTooWide)   // beside the camera when it fits, under it rather than cut off when it does not
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(block?.title ?? "Today's plan is done.").font(.system(.title3, design: .serif, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                        if let block { DoneButton(block: block) }
                    }
                    .padding(.horizontal, Self.cornerClearance).padding(.bottom, 4)   // in line with the kicker and the countdown above, and clear of the lower corners
                }
            } compactLeading: {   // the leading and trailing read as one unit: the sun, then the time it stands for
                Image(systemName: state.current != nil ? "sun.horizon.fill" : "sun.horizon").foregroundStyle(ActivityDesign.accent).padding(.leading, 4)
            } compactTrailing: {
                if let block { Countdown(block: block, on: state.current != nil, compact: true).padding(.trailing, 2) }
                else { Image(systemName: "checkmark").foregroundStyle(ActivityDesign.accent) }
            } minimal: {   // the minimal shows what changes (the time left), not a logo
                if let block { Countdown(block: block, on: state.current != nil).font(.caption2.weight(.semibold)) }
                else { Image(systemName: "checkmark").foregroundStyle(ActivityDesign.accent) }
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

/// The Lock Screen banner.
private struct LockScreenPlan: View {
    let state: PlanActivityAttributes.ContentState

    var body: some View {
        if let block = state.current ?? state.next {
            let on = state.current != nil
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ActivityKicker(on ? "Now" : "Up next", accent: on)
                    Text(Clock.range(block)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Countdown(block: block, on: on).font(.system(.title3, design: .serif, weight: .semibold))
                }
                Text(block.title).font(.system(.title2, design: .serif, weight: .semibold)).lineLimit(2)
                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 14) {
                    if on {
                        ProgressView(timerInterval: block.start...block.end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                            .tint(ActivityDesign.accent)
                    } else if let next = state.next, next.id != block.id {
                        Text("Then \(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    } else {
                        Text("\(state.done) of \(state.total) done").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    DoneButton(block: block)
                }
                if on, let next = state.next {
                    Text("Then \(next.title) at \(Clock.time(next.start))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ActivityKicker("Done", accent: true)
                Text("Today's plan is done.").font(.system(.title2, design: .serif, weight: .semibold))
                Text("\(state.done) of \(state.total) blocks.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Counts down to the end of the block that is on, or to the start of the one ahead.
///
/// A timer's text is drawn by the system after the view has been archived, in a frame the view no longer controls: it
/// takes all the width it is offered, sets itself at the start of it, and is cut off where the frame ends. So the
/// frame is made here, from the widest figure this countdown can show (hidden, in the same type), and the timer sits
/// in it against the trailing edge, on one line, shrinking before it is ever clipped. `compact` is for the island's
/// slots beside the camera (52 to 62 points wide, HIG): past the hour the figure needs seven characters, and takes a
/// smaller size to keep them all.
private struct Countdown: View {
    let block: PlanActivityAttributes.Block
    let on: Bool
    var compact = false

    /// The widest the figure gets: minutes and seconds for the block that is on (a long block counts past 99
    /// minutes), hours too for one more than an hour ahead.
    private var widest: String {
        if on { return block.end.timeIntervalSince(block.start) >= 6000 ? "000:00" : "00:00" }
        let ahead = block.start.timeIntervalSinceNow
        return ahead >= 36_000 ? "00:00:00" : ahead >= 3600 ? "0:00:00" : "00:00"
    }

    var body: some View {
        if compact { figure.font(widest.count > 5 ? .caption.weight(.semibold) : .subheadline.weight(.semibold)) } else { figure }   // elsewhere the type is the caller's
    }

    private var figure: some View {
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

/// Marks the block done in the app without opening it.
private struct DoneButton: View {
    let block: PlanActivityAttributes.Block
    var body: some View {
        Button(intent: MarkBlockDoneIntent(blockID: block.id)) {
            Label("Done", systemImage: "checkmark").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(ActivityDesign.accent)
        .controlSize(.small)
    }
}

/// The app's caps kicker, in the widget's own words.
private struct ActivityKicker: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }
    var body: some View {
        Text(text).font(.caption2).textCase(.uppercase).kerning(1).foregroundStyle(accent ? ActivityDesign.accent : .secondary)
    }
}

enum ActivityDesign {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
}

enum Clock {
    static func time(_ date: Date) -> String { date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)).minute()) }
    static func range(_ block: PlanActivityAttributes.Block) -> String { "\(time(block.start)) – \(time(block.end))" }
}
