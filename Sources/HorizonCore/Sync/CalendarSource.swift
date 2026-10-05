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

    /// Timed events the user will be at: an all-day entry (a holiday, a birthday) is not a stop in the day, and nor is
    /// an event cancelled, shown as free, or an invitation the user declined.
    public func busy(in interval: DateInterval) async throws -> [PlanBusy] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).filter(Self.holds).map { PlanBusy(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate) }
    }

    private static func holds(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled, event.availability != .free else { return false }
        return event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
    }
}
