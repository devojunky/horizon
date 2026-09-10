#if os(iOS)
import ActivityKit
import Foundation
import IngestKit
import HorizonCore
import os

/// Keeps the plan's Live Activity in step with the plan on file: started when there is something ahead, updated when
/// what is on or next changes (the app does this on every change it makes and every minute while Now is open),
/// left to the system's countdowns in between, ended when the day's plan is done or the plan goes.
/// `Activity` is not Sendable and its `update` and `end` are async; the activity is only ever touched from here, on
/// the main actor, so the awaits below hand it over as `nonisolated(unsafe)`.
@MainActor final class PlanActivityController {
    private var activity: Activity<PlanActivityAttributes>?
    private var shown: PlanActivityAttributes.ContentState?
    private static let logger = Logger(subsystem: Identifiers.bundlePrefix, category: "activity")
    private static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        #if DEBUG
        print("horizon: activity: \(message)")
        #endif
    }

    /// An activity from an earlier launch is taken over; any other is ended.
    func adopt() {
        let existing = Activity<PlanActivityAttributes>.activities
        activity = existing.first
        for stray in existing.dropFirst() {
            nonisolated(unsafe) let stray = stray
            Task { await stray.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func sync(plan: DayPlan?, day: Date?, now: Date = Date()) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { Self.log("not enabled"); return }
        guard let plan, let day else { await end(); return }
        let state = Self.state(of: plan, at: now)
        if state.finished {
            guard let current = activity else { return }
            if shown?.finished != true {   // the last block done: say so, then go away on its own
                nonisolated(unsafe) let current = current
                await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(30 * 60)))
                shown = state
            }
            activity = nil
            return
        }
        guard state != shown else { return }
        shown = state   // before the await, so a sync arriving meanwhile (the minute's tick, a second mark) sees it done
        let content = ActivityContent(state: state, staleDate: state.current?.end ?? state.next?.start)
        if let running = activity, running.activityState == .active {
            nonisolated(unsafe) let running = running
            await running.update(content)
            Self.log("updated: \(state.current?.title ?? "-") then \(state.next?.title ?? "-"), \(state.done)/\(state.total)")
        } else {
            do {
                activity = try Activity.request(attributes: PlanActivityAttributes(day: day), content: content, pushType: nil)
                Self.log("started: \(state.current?.title ?? "-") then \(state.next?.title ?? "-")")
            } catch {
                Self.log("could not start: \(error)")
                shown = nil
            }
        }
    }

    func end() async {
        guard let running = activity else { return }
        nonisolated(unsafe) let live = running
        await live.end(nil, dismissalPolicy: .immediate)
        Self.log("ended")
        activity = nil
        shown = nil
    }

    static func state(of plan: DayPlan, at now: Date) -> PlanActivityAttributes.ContentState {
        let focus = plan.focus(at: now)
        return PlanActivityAttributes.ContentState(current: focus.current.map(block), next: focus.next.map(block), done: plan.doneCount, total: plan.blocks.count)
    }

    private static func block(_ b: PlanBlock) -> PlanActivityAttributes.Block {
        PlanActivityAttributes.Block(id: b.id, title: b.title, reason: b.reason, kind: b.kind.rawValue, start: b.start, end: b.end)
    }
}
#endif
