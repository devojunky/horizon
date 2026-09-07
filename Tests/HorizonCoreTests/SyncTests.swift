import Foundation
import Testing
import IngestKit
@testable import HorizonCore

/// SPEC §4.4 "What to test", against the fake Reminders store.
struct SyncTests {
    @Test func twoDevicesIngestTheSameDocumentOnce() async throws {
        let reminders = FakeReminderStore()
        let a = try Fixture.store(), b = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: a)
        let reportA = try await SyncCoordinator.device("A", store: a, reminders: reminders).sync()
        #expect(reportA.created == 4)   // four dated items; the TBD final is not written
        var count = await reminders.items.count
        #expect(count == 4)

        // Device B receives the records before A's external IDs synced, and projects too.
        try await Fixture.replicate(from: a, to: b, includingExternalIDs: false)
        let reportB = try await SyncCoordinator.device("B", store: b, reminders: reminders).sync()
        count = await reminders.items.count
        let bRows = try await b.obligations()
        #expect(reportB.created == 0 && count == 4)   // reconciliation repaired B's external IDs first; nothing to create
        #expect(bRows.allSatisfy { $0.state == .projected && $0.ekExternalID != nil || $0.state == .awaitingDate })

        // And once more with the IDs present: still four.
        let c = try Fixture.store()
        try await Fixture.replicate(from: a, to: c, includingExternalIDs: true)
        _ = try await SyncCoordinator.device("C", store: c, reminders: reminders).sync()
        count = await reminders.items.count
        #expect(count == 4)
    }

    @Test func recordsArrivingBeforeRemindersDoNotCreateASecondSet() async throws {
        // CloudKit delivers A's rows to B before iCloud delivers A's reminders: B must wait, not create.
        let remindersA = FakeReminderStore(), remindersB = FakeReminderStore()
        let a = try Fixture.store(), b = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: a, device: "A")
        try await Fixture.replicate(from: a, to: b, includingExternalIDs: false)
        let reportB = try await SyncCoordinator.device("B", store: b, reminders: remindersB).sync()
        let countB = await remindersB.items.count
        #expect(reportB.created == 0 && reportB.waiting == 4 && countB == 0)
        _ = try await SyncCoordinator.device("A", store: a, reminders: remindersA).sync()
        let countA = await remindersA.items.count
        #expect(countA == 4)
    }

    @Test func aRestoredCourseGetsItsRemindersBack() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let calc = try await store.courses().first!
        try await store.deleteCourse(id: calc.id)
        let gone = try await sync.sync()
        var count = await reminders.items.count
        #expect(gone.removed == 4 && count == 0)                          // the deletion took the reminders
        try await store.restoreCourse(id: calc.id)
        let back = try await sync.sync()
        count = await reminders.items.count
        #expect(back.created == 4 && count == 4)                          // the restore brought them back
        // Restored before the sync ran: the reminders never left, and nothing is doubled.
        try await store.deleteCourse(id: calc.id)
        try await store.restoreCourse(id: calc.id)
        let kept = try await sync.sync()
        count = await reminders.items.count
        #expect(kept.created == 0 && kept.removed == 0 && count == 4)
    }

    @Test func aDeletedListIsNotTwentyDeletions() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        await reminders.userDeletesList()
        let report = try await sync.sync()
        let live = try await store.obligations()
        #expect(live.count == 5 && live.allSatisfy { $0.deletedAt == nil })   // nothing tombstoned
        #expect(report.created == 0 && report.waiting == 0)                    // and nothing recreated behind the user's back
        // Re-sharing the syllabus later still matches the existing rows instead of duplicating them.
        let again = try await Fixture.ingest(Fixture.calculus(sha: "v2"), into: store)
        #expect(again.created == 0)
    }

    @Test func deletionWhileInReviewStillCounts() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        // A reissued syllabus moves HW 1 into review; meanwhile the user deletes its reminder.
        try await Fixture.ingest(Fixture.calculus(hw1: Fixture.day(9, 10), sha: "v2"), into: store)
        let hw1 = await reminders.items.first { $0.title.hasPrefix("HW 1") }!
        await reminders.userDeletes(externalID: hw1.externalID)
        _ = try await sync.sync()
        let gone = try await store.obligations(includeDeleted: true).first { $0.title == "HW 1" }!
        #expect(gone.deletedAt != nil && gone.ekExternalID == nil)
        let count = await reminders.items.count
        #expect(count == 3)
    }

    @Test func discardRemovesTheReminderHorizonMade() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw2 = try await store.obligations().first { $0.title == "HW 2" }!
        try await store.softDelete(id: hw2.id)
        let report = try await sync.sync()
        let titles = await reminders.items.map(\.title)
        #expect(report.removed == 1 && !titles.contains { $0.hasPrefix("HW 2") })
        // But a reminder the user made themselves is never removed by a discard.
        await reminders.userCreates(title: "Buy the lab notebook", due: Fixture.day(9, 8))
        _ = try await sync.sync()
        let imported = try await store.obligations().first { $0.title == "Buy the lab notebook" }!
        try await store.softDelete(id: imported.id)
        _ = try await sync.sync()
        let still = await reminders.items.contains { $0.title == "Buy the lab notebook" }
        #expect(still)
    }

    @Test func notesRoundTripBothWays() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = await reminders.items.first { $0.title.hasPrefix("HW 1") }!
        await reminders.userAddsNote(externalID: hw1.externalID, "bring ID")
        _ = try await sync.sync()
        let stored = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(stored.notes == "bring ID" && stored.userOverrides.contains(.notes))
        // An edit in the app reaches the reminder without losing Horizon's own lines.
        try await store.confirm(id: stored.id, edits: ObligationEdits(notes: .some("bring ID and calculator")))
        _ = try await sync.sync()
        let updated = await reminders.items.first { $0.externalID == hw1.externalID }!
        #expect(updated.notes?.contains("bring ID and calculator") == true && updated.notes?.contains("Worth 1.5%") == true)
    }

    @Test func overrideConflictIsSurfacedNotSwallowed() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = await reminders.items.first { $0.title.hasPrefix("HW 1") }!
        await reminders.userEdits(externalID: hw1.externalID, due: Fixture.day(9, 11))
        _ = try await sync.sync()
        try await Fixture.ingest(Fixture.calculus(hw1: Fixture.day(9, 10), sha: "v2"), into: store)
        let after = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(Fixture.calendar.component(.day, from: after.due!) == 11)                 // the hand edit stands
        #expect(after.changeNote?.contains("Document now says due Sep 10") == true)      // and the disagreement is visible
        #expect(after.state == .projected)                                                // without dragging it into review
    }

    @Test func projectionIsIdempotentAndUpdatesInPlace() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let again = try await sync.sync()
        let items = await reminders.items
        #expect(again == ReminderProjector.Report() && items.count == 4)
        let hw1 = items.first { $0.title.hasPrefix("HW 1") }!
        let stored = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(hw1.title == "HW 1 · Calculus II" && hw1.url == Identifiers.link(for: stored.id))   // reminders carry the course's name
        #expect(hw1.notes?.contains("Worth 1.5% of the grade") == true && hw1.notes?.contains("WebAssign") == true && hw1.notes?.contains("page 2") == true)
    }

    @Test func deletionInRemindersStaysDeleted() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let quiz = await reminders.items.first { $0.title.hasPrefix("Quiz 1") }!
        await reminders.userDeletes(externalID: quiz.externalID)

        for _ in 0..<3 { _ = try await sync.sync() }
        var count = await reminders.items.count
        let deleted = try await store.obligations(includeDeleted: true).first { $0.title == "Quiz 1" }!
        #expect(count == 3 && deleted.deletedAt != nil)
        // A re-ingest of the same syllabus does not resurrect it.
        try await Fixture.ingest(Fixture.calculus(sha: "def"), into: store)
        _ = try await sync.sync()
        count = await reminders.items.count
        let live = try await store.obligations().count
        #expect(count == 3 && live == 4)   // 3 dated + TBD final; Quiz 1 stays a tombstone
    }

    @Test func completionComesFromReminders() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = await reminders.items.first { $0.title.hasPrefix("HW 1") }!
        await reminders.userCompletes(externalID: hw1.externalID)
        _ = try await sync.sync()
        let completed = try await store.obligations().first { $0.title == "HW 1" }?.completedAt
        #expect(completed != nil)
    }

    @Test func handEditsInRemindersBecomeOverridesThatReingestRespects() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = await reminders.items.first { $0.title.hasPrefix("HW 1") }!
        await reminders.userEdits(externalID: hw1.externalID, due: Fixture.day(9, 11))
        _ = try await sync.sync()
        let edited = try await store.obligations().first { $0.title == "HW 1" }!
        #expect(Fixture.calendar.component(.day, from: edited.due!) == 11 && edited.userOverrides == [.due])

        // The professor reissues the syllabus with HW 1 on 9/10: the user's reschedule wins, nothing moves.
        try await Fixture.ingest(Fixture.calculus(hw1: Fixture.day(9, 10), sha: "v2"), into: store)
        _ = try await sync.sync()
        let after = try await store.obligations().first { $0.title == "HW 1" }!
        let reminderDue = await reminders.items.first { $0.externalID == hw1.externalID }?.due
        #expect(Fixture.calendar.component(.day, from: after.due!) == 11 && after.state == .projected && reminderDue == Fixture.day(9, 11))
    }

    @Test func reissuedSyllabusPresentsADiffInsteadOfMovingDates() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()

        let summary = try await Fixture.ingest(Fixture.calculus(hw1: Fixture.day(9, 10), sha: "v2"), into: store)
        #expect(summary.updated == 1 && summary.created == 0 && summary.pendingReview == 1)
        let hw1 = try await store.reviewQueue().first!
        #expect(hw1.title == "HW 1" && hw1.changeNote?.contains("Sep 9 → Sep 10") == true && hw1.state == .pendingReview)
        _ = try await sync.sync()
        let before = await reminders.items.first { $0.title.hasPrefix("HW 1") }?.due
        #expect(before == Fixture.day(9, 9))   // unchanged until confirmed

        try await store.confirm(id: hw1.id)
        _ = try await sync.sync()
        let items = await reminders.items
        #expect(items.first { $0.title.hasPrefix("HW 1") }?.due == Fixture.day(9, 10) && items.count == 4)
    }

    @Test func remindersMadeByHandAreImportedNotDeleted() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        await reminders.userCreates(title: "Buy the lab notebook", due: Fixture.day(9, 8))
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        for _ in 0..<2 { _ = try await sync.sync() }
        let imported = try await store.obligations()
        let count = await reminders.items.count
        #expect(imported.count == 1 && imported[0].origin == .reminders && imported[0].state == .projected && count == 1)
    }

    @Test func anotherDevicesRemindersAreNotImportedAsHandMade() async throws {
        // A's reminders (with Horizon links) reach B through iCloud before A's records reach B through CloudKit.
        let reminders = FakeReminderStore()
        let a = try Fixture.store(), b = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: a, device: "A")
        _ = try await SyncCoordinator.device("A", store: a, reminders: reminders).sync()
        _ = try await SyncCoordinator.device("B", store: b, reminders: reminders).sync()
        let imported = try await b.obligations()
        #expect(imported.isEmpty)   // nothing invented on B; the records will arrive
        await reminders.userCreates(title: "Buy the lab notebook", due: Fixture.day(9, 8))
        _ = try await SyncCoordinator.device("B", store: b, reminders: reminders).sync()
        let handMade = try await b.obligations()
        #expect(handMade.map(\.title) == ["Buy the lab notebook"])
    }

    @Test func manualEntryProjectsWithProvenance() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let course = try await store.courses().first!
        let manual = try await store.addManual(title: "Bring calculator to exam", due: Fixture.day(10, 7), dueHasTime: false, courseID: course.id, componentName: nil, notes: "Told in lecture", deviceName: "A")
        #expect(manual.origin == .manual && manual.state == .readyToProject && manual.userOverrides.contains(.title))
        _ = try await SyncCoordinator.device("A", store: store, reminders: reminders).sync()
        let items = await reminders.items
        #expect(items.contains { $0.title == "Bring calculator to exam · Calculus II" && $0.notes?.contains("Told in lecture") == true })
    }
}
