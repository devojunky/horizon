#if os(iOS)
import ActivityKit
import Foundation
import IngestKit
import HorizonCore
import os

/// Keeps the plan's Live Activity in step with the plan on file: started when there is something ahead, updated when
/// what it shows changes (the app does this on every change it makes, every minute while Now is open, and in a
/// background refresh at the moment the activity next changes), ended as soon as the day's plan has nothing on, ahead
/// or asking (HIG: end a Live Activity when its task ends). Between updates the system draws it again at its stale
/// date, and the views work out from the blocks' own times what that moment shows (`ContentState.phase(at:)`).
/// `Activity` is not Sendable and its `update` and `end` are async; the activity is only ever touched from here, on
/// the main actor, so the awaits below hand it over as `nonisolated(unsafe)`.
@MainActor final class PlanActivityController {
    private var activity: Activity<PlanActivityAttributes>?
    private var shown: PlanActivityAttributes.ContentState?
    private static let logger = Logger(subsystem: Identifiers.bundlePrefix, category: "activity")
    private static func log(_ message: String) {
        // The lines carry the user's own words (titles, calendar events, file names): readable in a DEBUG build, where
        // they are how the app is tested, and private in a release, where the unified log keeps them.
        #if DEBUG
        logger.notice("\(message, privacy: .public)")
        #else
        logger.notice("\(message, privacy: .private)")
        #endif
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

    /// Brings the activity in step with `plan` at `now`. Returns the next moment what it shows changes by itself, for
    /// the background refresh that brings it in step again then; nil when there is none (no activity: it ended, the user
    /// removed it, or it could not start).
    @discardableResult
    func sync(plan: DayPlan?, day: Date?, now: Date = Date()) async -> Date? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { Self.log("not enabled"); return nil }
        guard let plan, let day else { await end(); return nil }
        let state = Self.state(of: plan, at: now)
        guard !state.finished else { await end(); return nil }   // the day's plan is over: nothing on, ahead or asking
        let change = state.nextChange(after: now)
        guard state != shown else { return change }
        shown = state   // before the await, so a sync arriving meanwhile (the minute's tick, a second mark) sees it done
        let content = ActivityContent(state: state, staleDate: change)
        if let running = activity, running.activityState == .active || running.activityState == .stale {
            nonisolated(unsafe) let running = running
            await running.update(content)
            Self.log("updated: \(Self.describe(state, at: now))")
        } else if activity?.activityState == .dismissed || dismissed == plan.id {
            dismissed = plan.id   // the user removed it from the Lock Screen: not again for this plan (a new plan may start one)
            activity = nil
            return nil            // and no background refresh for an activity that is not there
        } else {
            do {
                activity = try Activity.request(attributes: PlanActivityAttributes(day: day), content: content, pushType: nil)
                Self.log("started: \(Self.describe(state, at: now))")
            } catch {
                Self.log("could not start: \(error)")
                shown = nil
                return nil        // started from the foreground or not at all: a refresh in the background could not either
            }
        }
        return change
    }

    /// Ends the activity at once, from the Dynamic Island and the Lock Screen alike: the day's plan is over, or gone.
    func end() async {
        let running = activity.map { [$0] } ?? Activity<PlanActivityAttributes>.activities   // one from an earlier launch the app never adopted too
        activity = nil
        shown = nil
        for live in running where live.activityState != .ended && live.activityState != .dismissed && !ending.contains(live.id) {
            ending.insert(live.id)   // a sync arriving while this one awaits the end must not end it twice
            nonisolated(unsafe) let live = live
            await live.end(nil, dismissalPolicy: .immediate)
            Self.log("ended")
        }
    }
    private var ending: Set<String> = []
    /// The plan whose activity the user removed. Kept with the app's settings: iOS ends a backgrounded app, and the next
    /// launch's sync would otherwise start the removed activity again for the same plan.
    private var dismissed: UUID? {
        get { AppModel.defaults.string(forKey: "dismissedPlanActivity").flatMap(UUID.init(uuidString:)) }
        set { AppModel.defaults.set(newValue?.uuidString, forKey: "dismissedPlanActivity") }
    }

    static func state(of plan: DayPlan, at now: Date) -> PlanActivityAttributes.ContentState {
        let focus = plan.focus(at: now)
        return PlanActivityAttributes.ContentState(current: focus.current.map(block), next: focus.next.map(block),
                                                   asking: plan.awaitingAnswer(at: now).map(block), done: plan.doneCount, total: plan.workBlocks.count)
    }

    private static func block(_ b: PlanBlock) -> PlanActivityAttributes.Block {
        PlanActivityAttributes.Block(id: b.id, title: b.title, reason: b.reason, kind: b.kind.rawValue, start: b.start, end: b.end, answerBy: DayPlan.answerBy(b))
    }

    private static func describe(_ state: PlanActivityAttributes.ContentState, at now: Date) -> String {
        switch state.phase(at: now) {
        case .on(let b): "on \(b.title), then \(state.next?.title ?? "-"), \(state.done)/\(state.total)"
        case .upNext(let b): "up next \(b.title), \(state.done)/\(state.total)"
        case .asking(let b): "asking whether \(b.title) is finished, then \(state.current?.title ?? state.next?.title ?? "-")"
        case .done: "done"
        }
    }
}
#endif
