import Foundation
import EventKit
import IngestKit

/// Fixed events of a day, from the user's calendars: the hard stops of a day plan (SPEC §6.3).
public protocol CalendarSource: Sendable {
    func requestAccess() async throws -> Bool
    func busy(on day: Date, calendar: Calendar) async throws -> [PlanBusy]
}

public final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    /// Timed events only: an all-day entry (a holiday, a birthday) is not a stop in the day.
    public func busy(on day: Date, calendar: Calendar) async throws -> [PlanBusy] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.map { PlanBusy(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate) }
    }
}
