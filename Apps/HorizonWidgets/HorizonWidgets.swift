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

/// Today's plan on the Lock Screen and in the Dynamic Island: the block on now with a live countdown and its reason,
/// or the one up next and when; a Done button that marks it in the app; what comes after. Set like the app's
/// timetable: a caps kicker, a serif title, the marker orange for the block that is on.
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
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ActivityKicker(state.current != nil ? "Now" : state.finished ? "Done" : "Up next", accent: state.current != nil)
                        if let block { Text(Clock.range(block)).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let block { Countdown(block: block, on: state.current != nil).font(.system(.title3, design: .serif, weight: .semibold)) }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(block?.title ?? "Today's plan is done.").font(.system(.title3, design: .serif, weight: .semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let block {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                                if let next = state.next, state.current != nil { Text("Then \(next.title) at \(Clock.time(next.start))").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            DoneButton(block: block)
                        }
                    } else {
                        Text("\(state.done) of \(state.total) blocks done.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {   // the leading and trailing read as one unit: the sun, then the time it stands for
                Image(systemName: state.current != nil ? "sun.horizon.fill" : "sun.horizon").foregroundStyle(ActivityDesign.accent).padding(.leading, 4)
            } compactTrailing: {
                if let block { Countdown(block: block, on: state.current != nil).font(.subheadline.weight(.semibold)).frame(maxWidth: 54).padding(.trailing, 4) }
                else { Image(systemName: "checkmark").foregroundStyle(ActivityDesign.accent) }
            } minimal: {   // the minimal shows what changes (the time left), not a logo
                if let block { Countdown(block: block, on: state.current != nil).font(.caption2.weight(.semibold)).minimumScaleFactor(0.7) }
                else { Image(systemName: "checkmark").foregroundStyle(ActivityDesign.accent) }
            }
            .widgetURL(PlanLiveActivity.nowLink)
            .keylineTint(ActivityDesign.accent)
        }
    }

    /// A tap anywhere opens the app on Now.
    static let nowLink = URL(string: "horizon://now")!
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
private struct Countdown: View {
    let block: PlanActivityAttributes.Block
    let on: Bool
    var body: some View {
        if on {
            Text(timerInterval: block.start...block.end, countsDown: true, showsHours: false).monospacedDigit().contentTransition(.numericText())
        } else {   // to the start; the range must stay ordered when the system re-renders after the start has passed
            let from = min(Date(), block.start.addingTimeInterval(-1))
            Text(timerInterval: from...block.start, countsDown: true, showsHours: true).monospacedDigit()
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
