import Foundation
import IngestKit

/// What the Search tab offers before anything is typed, the way Siri Suggestions offer what is likely next: the items
/// most worth a look now, a few searches worth trying in this library, and the searches the user ran last. Pure: the
/// page draws.
public enum SearchSuggestions {
    /// Why an item is suggested, in the order the page lists them.
    public enum Reason: Equatable, Sendable { case dueToday, dueTomorrow, mattersMost, toReview, thisWeek }

    public struct Suggestion: Equatable, Sendable {
        public var id: UUID
        public var reason: Reason
    }

    /// At most `limit` open items, each once, for the first of its reasons: what is due today, soonest first, and what is
    /// due tomorrow; the one that matters most in the next two weeks (`DueQuery.nextByWeight`, the Lock Screen's item);
    /// the soonest item due this week that waits for the user's review; then the rest of the week by date. The urgent
    /// lead: a heavy item due in twelve days sat above tomorrow's homework, and read as a mistake.
    public static func items(_ items: [ObligationSnapshot], now: Date, calendar: Calendar, limit: Int = 5) -> [Suggestion] {
        let open = items.filter { $0.deletedAt == nil && $0.completedAt == nil }
        let week = DueQuery.items(open, in: DuePeriod.nextSevenDays.interval(at: now, calendar: calendar))
        var picked: [Suggestion] = []
        var seen = Set<UUID>()
        func add(_ found: some Sequence<ObligationSnapshot>, _ reason: Reason) {
            for o in found where picked.count < limit && seen.insert(o.id).inserted { picked.append(Suggestion(id: o.id, reason: reason)) }
        }
        add(DueQuery.items(open, in: DuePeriod.today.interval(at: now, calendar: calendar)), .dueToday)
        add(DueQuery.items(open, in: DuePeriod.tomorrow.interval(at: now, calendar: calendar)), .dueTomorrow)
        add([DueQuery.nextByWeight(open, now: now)].compactMap { $0 }, .mattersMost)
        add(week.filter { $0.state == .pendingReview && !seen.contains($0.id) }.prefix(1), .toReview)
        add(week, .thisWeek)
        return picked
    }

    /// Searches worth trying in this library, at most `limit`: the policies its courses state (what people ask most,
    /// "makeup exam policy"), the most stated first and at most two; the grade row with the most work ahead in the next
    /// two weeks; and "syllabus" when a document is one.
    public static func queries(policies: [PolicySnapshot], items: [ObligationSnapshot], documents: [DocumentSnapshot], now: Date, calendar: Calendar,
                               limit: Int = 4) -> [String] {
        var found: [String] = []
        let stated = Dictionary(grouping: policies.filter { $0.kind != .other }, by: \.kind).mapValues(\.count)
        let kinds = policyQueries.map(\.kind).filter { stated[$0] != nil }
            .enumerated().sorted { (stated[$0.element]!, -$0.offset) > (stated[$1.element]!, -$1.offset) }.map(\.element)
        found += kinds.prefix(2).compactMap { kind in policyQueries.first { $0.kind == kind }?.query }
        let ahead = DueQuery.items(items, in: DuePeriod.nextTwoWeeks.interval(at: now, calendar: calendar))
        let rows = Dictionary(grouping: ahead.compactMap { $0.componentName.flatMap { $0.isEmpty ? nil : $0 } }, by: { $0 }).mapValues(\.count)
        if let row = rows.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key { found.append(row) }
        if documents.contains(where: { $0.deletedAt == nil && $0.displayName.localizedCaseInsensitiveContains("syllabus") }) { found.append("syllabus") }
        return Array(found.prefix(limit))
    }

    /// What each kind of policy is searched as, in the order the kinds are offered when as many courses state them.
    private static let policyQueries: [(kind: PolicyKind, query: String)] = [
        (.makeupExam, "makeup exam policy"), (.lateWork, "late work policy"), (.attendance, "attendance policy"),
        (.extraCredit, "extra credit"), (.dropRule, "dropped scores"),
    ]

    /// The searches kept for the page, newest first: the words as typed, once each (case aside), at most `limit`.
    public static func remembering(_ query: String, in recent: [String], limit: Int = 6) -> [String] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return recent }
        return Array(([words] + recent.filter { $0.caseInsensitiveCompare(words) != .orderedSame }).prefix(limit))
    }
}
