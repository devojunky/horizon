import Foundation
import EventKit
import IngestKit

/// Fixed events of a day, from the user's calendars: the hard stops of a day plan (SPEC §6.3).
public protocol CalendarSource: Sendable {
    func requestAccess() async throws -> Bool
    /// The events that touch `interval`: a day, and the night after it when the day runs past midnight.
    func busy(in interval: DateInterval) async throws -> [PlanBusy]
}

public final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    /// Timed events only: an all-day entry (a holiday, a birthday) is not a stop in the day.
    public func busy(in interval: DateInterval) async throws -> [PlanBusy] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.map { PlanBusy(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate) }
    }
}
