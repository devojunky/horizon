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

    #if HORIZON_CLOUDKIT
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
    #endif

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
        #expect(report.created == 0 && report.waiting == 0 && report.listGone) // nothing recreated behind the user's back, and the app is told
        // Re-sharing the syllabus later still matches the existing rows instead of duplicating them.
        let again = try await Fixture.ingest(Fixture.calculus(sha: "v2"), into: store)
        #expect(again.created == 0)
    }

    @Test func aDeletedListHoldsNewItemsAndComesBackWhole() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        try await store.setCompleted(id: hw1.id, true)
        _ = try await sync.sync()
        await reminders.userDeletesList()
        // An item added while the list is gone waits: its create would make a list with only it in it, and the next
        // sync would then read the other four's absence as four deletions.
        let course = try await store.courses().first!
        _ = try await store.addManual(title: "Bring calculator to exam", due: Fixture.day(10, 7), dueHasTime: false, courseID: course.id, componentName: nil, notes: nil, deviceName: "A")
        let held = try await sync.sync()
        var exists = await reminders.listExists
        #expect(held.listGone && held.created == 0 && held.waiting == 1 && !exists)
        // Recreate List: the list comes back with every item, the checked one checked.
        let back = try await sync.restoreList()
        let items = await reminders.items
        exists = await reminders.listExists
        #expect(back?.items.count == 5 && back?.items.filter(\.isCompleted).count == 1 && exists && items.count == 5)
        let hw1Reminder = items.first { $0.title.hasPrefix("HW 1") }
        #expect(hw1Reminder?.isCompleted == true)
        var live = try await store.obligations()
        #expect(live.count == 6 && live.filter { $0.due != nil }.allSatisfy { $0.state == .projected && $0.ekExternalID != nil })
        #expect(live.first { $0.id == hw1.id }?.completedAt != nil && live.allSatisfy { !$0.completionPending })
        // And it stays whole: nothing is read as deleted, nothing is written twice.
        let after = try await sync.sync()
        live = try await store.obligations()
        let count = await reminders.items.count
        #expect(after.created == 0 && !after.listGone && live.count == 6 && count == 5)
    }

    @Test func aSyncArrivingDuringRecreateMakesNoSecondListAndCountsTrue() async throws {
        // The new list's own change notification asks for a sync while the restore is writing: it waits its turn.
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        await reminders.userDeletesList()
        _ = try await sync.sync()
        async let restored = sync.restoreList()
        async let other = sync.sync()
        let (back, _) = try await (restored, other)
        let items = await reminders.items
        let list = await reminders.listID
        #expect(back?.items.count == 4 && items.count == 4 && list == "list-2")   // one new list, every item once, and the count says so
    }

    @Test func aListMadeAgainElsewhereIsFilledNotEmptied() async throws {
        // Two devices with stores of their own (the Mac and the phone, no CloudKit) and one Reminders account.
        let reminders = FakeReminderStore()
        let a = try Fixture.store(), b = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: a, device: "A")
        _ = try await b.addManual(title: "Renew library card", due: Fixture.day(9, 30), dueHasTime: false, courseID: nil, componentName: nil, notes: nil, deviceName: "B")
        let syncA = SyncCoordinator.device("A", store: a, reminders: reminders)
        let seenB = InMemorySeenIDs()
        let syncB = SyncCoordinator(store: b, reminders: reminders, seen: seenB, deviceName: "B")
        _ = try await syncA.sync(); _ = try await syncB.sync()
        var count = await reminders.items.count
        #expect(count == 5)
        await reminders.userDeletesList()
        let goneA = try await syncA.sync(), goneB = try await syncB.sync()
        #expect(goneA.listGone && goneB.listGone)
        // Recreated on A. B finds a new list under the old name and writes its own item to it; it deletes nothing.
        _ = try await syncA.restoreList()
        let filled = try await syncB.sync()
        count = await reminders.items.count
        let bLive = try await b.obligations()
        #expect(filled.created == 1 && !filled.listGone && count == 5 && bLive.count == 1 && bLive[0].state == .projected)
        // A device that never recorded the list (it last synced before the list was recorded) tells a new one by
        // content: a list holding none of the reminders it wrote is a new list.
        seenB.saveListID(nil)
        await reminders.userDeletesList()
        _ = try await syncA.sync(); _ = try await syncB.sync()
        _ = try await syncA.restoreList()
        let again = try await syncB.sync()
        count = await reminders.items.count
        let bAgain = try await b.obligations()
        #expect(again.created == 1 && count == 5 && bAgain.count == 1)
    }

    @Test func deletingEveryReminderByHandIsStillDeletion() async throws {
        // The same list with every item deleted is the user's intent, item by item, not a list made again.
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        for item in await reminders.items { await reminders.userDeletes(externalID: item.externalID) }
        let report = try await sync.sync()
        let live = try await store.obligations()
        let count = await reminders.items.count
        #expect(report.created == 0 && !report.listGone && count == 0 && live.map(\.title) == ["Final Exam"])   // only the undated final, which never had one
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

    @Test func aCheckInTheAppReachesRemindersAndThenRemindersOwnsItAgain() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        let when = Fixture.day(9, 8, hour: 20, minute: 15)
        try await store.setCompleted(id: hw1.id, true, at: when)
        var row = try await store.obligations().first { $0.id == hw1.id }!
        #expect(row.completedAt == when && row.completionPending)
        let report = try await sync.sync()   // the reconciler sees an unchecked reminder and leaves the app's check alone; the projector writes it
        var reminder = await reminders.items.first { $0.externalID == hw1.ekExternalID }!
        row = try await store.obligations().first { $0.id == hw1.id }!
        #expect(report.checked == 1 && reminder.isCompleted && reminder.completionDate == when && row.completedAt == when && !row.completionPending)
        #expect(row.state == .projected)   // a check changes nothing else
        // Unchecked in Reminders: with nothing pending, Reminders' word wins again.
        await reminders.userUncompletes(externalID: reminder.externalID)
        _ = try await sync.sync()
        row = try await store.obligations().first { $0.id == hw1.id }!
        #expect(row.completedAt == nil)
        // And unchecked in the app after a check in Reminders.
        await reminders.userCompletes(externalID: reminder.externalID)
        _ = try await sync.sync()
        try await store.setCompleted(id: hw1.id, false)
        _ = try await sync.sync()
        reminder = await reminders.items.first { $0.externalID == hw1.ekExternalID }!
        row = try await store.obligations().first { $0.id == hw1.id }!
        #expect(!reminder.isCompleted && reminder.completionDate == nil && row.completedAt == nil && !row.completionPending)
        // Another device sees the check through its reminder.
        try await store.setCompleted(id: hw1.id, true)
        _ = try await sync.sync()
        let b = try Fixture.store()
        try await Fixture.replicate(from: store, to: b, includingExternalIDs: true)
        _ = try await SyncCoordinator.device("B", store: b, reminders: reminders).sync()
        #expect(try await b.obligations().first { $0.id == hw1.id }?.completedAt != nil)
    }

    @Test func aCheckWithNoReminderWaitsInTheStore() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(quizStatus: .needsReview), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        let quiz = try await store.obligations().first { $0.title == "Quiz 1" }!
        let exam = try await store.obligations().first { $0.title == "Midterm 1" }!
        // Checked before anything has been written to Reminders: the reminder is created, then checked, in one sync.
        try await store.setCompleted(id: exam.id, true)
        try await store.setCompleted(id: quiz.id, true)   // in review: it has no reminder, and a check does not confirm it
        let report = try await sync.sync()
        let written = await reminders.items
        #expect(report.created == 3 && report.checked == 1 && written.first { $0.title.hasPrefix("Midterm 1") }?.isCompleted == true)
        var row = try await store.obligations().first { $0.id == quiz.id }!
        #expect(row.state == .pendingReview && row.completedAt != nil && row.completionPending)
        #expect(try await store.reviewQueue().isEmpty)   // done needs no review
        // Unchecked, it is back in the queue; confirmed and checked again, the check follows it into Reminders.
        try await store.setCompleted(id: quiz.id, false)
        #expect(try await store.reviewQueue().map(\.title) == ["Quiz 1"])
        try await store.confirm(id: quiz.id)
        try await store.setCompleted(id: quiz.id, true)
        _ = try await sync.sync()
        row = try await store.obligations().first { $0.id == quiz.id }!
        let quizReminder = await reminders.items.first { $0.title.hasPrefix("Quiz 1") }
        #expect(quizReminder?.isCompleted == true && !row.completionPending)
        // A deleted item cannot be checked.
        try await store.softDelete(id: exam.id)
        try await store.setCompleted(id: exam.id, false)
        #expect(try await store.obligations(includeDeleted: true).first { $0.id == exam.id }?.completedAt != nil)
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

/// Races and edges between the app, the store and Reminders.
struct SyncFollowThroughTests {
    @Test func aRestoredCheckedItemKeepsItsCheck() async throws {
        for byDocument in [false, true] {
            let reminders = FakeReminderStore()
            let store = try Fixture.store()
            try await Fixture.ingest(Fixture.calculus(), into: store)
            let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
            _ = try await sync.sync()
            let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
            try await store.setCompleted(id: hw1.id, true)
            _ = try await sync.sync()
            let course = try await store.courses().first!, doc = try await store.documents().first!
            if byDocument { try await store.deleteDocument(id: doc.id) } else { try await store.deleteCourse(id: course.id) }
            _ = try await sync.sync()                                                  // the checked reminder goes with it
            if byDocument { try await store.restoreDocument(id: doc.id) } else { try await store.restoreCourse(id: course.id) }
            _ = try await sync.sync()                                                  // a new one, checked
            _ = try await sync.sync()                                                  // and Reminders' word on it agrees
            let row = try await store.obligations().first { $0.id == hw1.id }!
            let reminder = await reminders.items.first { $0.title.hasPrefix("HW 1") }
            #expect(row.completedAt != nil && !row.completionPending && reminder?.isCompleted == true, "restored by \(byDocument ? "document" : "course")")
        }
    }

    @Test(.timeLimit(.minutes(1))) func recreateDuringASyncFinishesAndASyncDuringARerunRunsAgain() async throws {
        let fake = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator(store: store, reminders: HeldReminders(inner: fake, fetchDelay: .milliseconds(150)), seen: InMemorySeenIDs(), deviceName: "A")
        _ = try await sync.sync()
        await fake.userDeletesList()
        // Recreate List tapped while an ordinary sync is under way: it waits its turn, then runs (it once spun for ever).
        let running = Task { try await sync.sync() }
        try await Task.sleep(for: .milliseconds(50))
        let restored = try await sync.restoreList()
        _ = try await running.value
        #expect(restored?.items.count == 4)
        // A sync asked for while a rerun is under way is not handed the rerun's stale report: it runs once more.
        await fake.userCreates(title: "Bring the lab notebook", due: Fixture.day(9, 8))
        let before = await fake.fetches                                                 // a run fetches the list twice
        let first = Task { try await sync.sync() }
        while await fake.fetches < before + 1 { try await Task.sleep(for: .milliseconds(10)) }
        let second = Task { try await sync.sync() }                                    // during the first run: asks for a rerun
        while await fake.fetches < before + 3 { try await Task.sleep(for: .milliseconds(10)) }
        let third = Task { try await sync.sync() }                                     // during the rerun
        _ = try await (first.value, second.value, third.value)
        #expect(await fake.fetches - before == 6)                                       // three runs
        #expect(try await store.obligations().filter { $0.origin == .reminders }.count == 1)
    }

    @Test func aCheckUndoneWhileItIsWrittenStaysUndone() async throws {
        let fake = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        _ = try await SyncCoordinator.device("A", store: store, reminders: fake).sync()
        let entered = Gate(), proceed = Gate()
        let sync = SyncCoordinator(store: store, reminders: HeldReminders(inner: fake, holdCompletion: (entered, proceed)), seen: InMemorySeenIDs(), deviceName: "A")
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        try await store.setCompleted(id: hw1.id, true)                                  // a tap on the ring by mistake
        let running = Task { try await sync.sync() }
        await entered.wait()                                                            // the check is in Reminders, not yet settled
        try await store.setCompleted(id: hw1.id, false)                                 // and the tap undone
        await proceed.release()
        _ = try await running.value
        _ = try await sync.sync()
        let row = try await store.obligations().first { $0.id == hw1.id }!
        let reminder = await fake.items.first { $0.externalID == hw1.ekExternalID }!
        #expect(row.completedAt == nil && !row.completionPending && !reminder.isCompleted)
    }

    @Test func aReconcileFromAnOlderSnapshotLeavesTheAppsNewerWordAlone() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        await reminders.userCompletes(externalID: hw1.ekExternalID!)
        await reminders.userEdits(externalID: hw1.ekExternalID!, title: "HW 1 (online) · Calculus II")
        // What a sync does: read, compare, apply. The user acts in the app between the read and the apply.
        let list = try await reminders.fetchHorizonList()!
        let read = Date()
        let changes = Reconciler.changes(obligations: try await store.obligations(includeDeleted: true), reminders: list.items, seen: Set(list.items.map(\.externalID)))
        try await store.setCompleted(id: hw1.id, true)
        try await store.setCompleted(id: hw1.id, false)                                 // checked and unchecked: pending, open
        try await store.applyReconciliation(changes, since: read)
        let row = try await store.obligations().first { $0.id == hw1.id }!
        #expect(row.completedAt == nil && row.completionPending && row.title == "HW 1")   // the app's word stands; the next pass compares again
        _ = try await sync.sync()
        let after = try await store.obligations().first { $0.id == hw1.id }!
        #expect(after.title == "HW 1 (online)")                                         // the hand edit in Reminders still arrives
    }

    @Test func aRereadDuringAProjectionKeepsItsReview() async throws {
        let fake = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let entered = Gate(), proceed = Gate()
        let sync = SyncCoordinator(store: store, reminders: HeldReminders(inner: fake, holdCreate: (entered, proceed)), seen: InMemorySeenIDs(), deviceName: "A")
        let running = Task { try await sync.sync() }
        await entered.wait()                                                            // HW 1's reminder is being written
        try await Fixture.ingest(Fixture.calculus(hw1: Fixture.day(9, 11), sha: "v2"), into: store)   // the reissue moves it to Sep 11
        await proceed.release()
        _ = try await running.value
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        let reminder = await fake.items.first { $0.title.hasPrefix("HW 1") }!
        #expect(hw1.state == .pendingReview && hw1.ekExternalID == reminder.externalID)  // still in review, its reminder known
        #expect(try await store.reviewQueue().map(\.id) == [hw1.id])
        try await store.confirm(id: hw1.id)
        _ = try await sync.sync()
        let written = await fake.items.first { $0.externalID == reminder.externalID }!
        let state = try await store.obligations().first { $0.id == hw1.id }?.state
        #expect(written.due == Fixture.day(9, 11) && state == .projected)
    }

    @Test func twoItemsOfOneNameStayTwoAfterOneIsMovedInReminders() async throws {
        func result(sha: String) -> IngestResult {
            IngestResult(document: DocumentInfo(name: "span.pdf", sha256: sha, kind: .pdf, pageCount: 1),
                         course: ParsedCourse(code: "SPAN-UA 1", title: "Elementary Spanish I"),
                         obligations: [ParsedObligation(title: "Quiz", dateAsWritten: "9/10", due: Fixture.day(9, 10), status: .ready),
                                       ParsedObligation(title: "Quiz", dateAsWritten: "9/17", due: Fixture.day(9, 17), status: .ready)])
        }
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(result(sha: "s1"), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let first = try await store.obligations().first { Fixture.calendar.isDate($0.due!, inSameDayAs: Fixture.day(9, 10)) }!
        await reminders.userEdits(externalID: first.ekExternalID!, due: Fixture.day(9, 11))
        _ = try await sync.sync()
        let summary = try await Fixture.ingest(result(sha: "s2"), into: store)
        let report = try await sync.sync()
        let count = try await store.obligations().count
        #expect(summary.created == 0 && report.created == 0 && count == 2)
    }

    @Test func aTimeZoneChangeIsNotAHandEdit() {
        var west = Calendar(identifier: .gregorian); west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let east = Fixture.calendar
        let written = west.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 23, minute: 59))!   // projected in Los Angeles
        let seenEast = east.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 23, minute: 59))! // EventKit's day, read in New York
        let movedEast = east.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 23, minute: 59))!
        let id = UUID()
        let row = ObligationSnapshot(id: id, title: "Essay", due: written, dueHasTime: false, platform: .syllabusOnly, componentName: nil, pointsAtStake: nil, confidence: 1,
                                     state: .projected, origin: .document, flags: [], notes: nil, userOverrides: [], ekExternalID: "e1", projectedTitle: "Essay", projectedDue: written,
                                     projectedNotes: nil, completedAt: nil, deletedAt: nil, changeNote: nil, createdOn: "A", courseID: nil, courseCode: nil, sourceDocumentID: nil, sourcePage: nil)
        func reminder(_ due: Date) -> ReminderItem { ReminderItem(externalID: "e1", title: "Essay", due: due, hasTime: false, url: Identifiers.link(for: id)) }
        #expect(Reconciler.changes(obligations: [row], reminders: [reminder(seenEast)], seen: ["e1"], calendar: east).isEmpty)
        // A day moved by hand still is, once the store's days are anchored where the device is (`DayAnchor`).
        var anchored = row; anchored.due = seenEast; anchored.projectedDue = seenEast
        #expect(Reconciler.changes(obligations: [anchored], reminders: [reminder(movedEast)], seen: ["e1"], calendar: east).count == 1)
    }

    @Test func aRemindersOwnItemIsNeverADocumentsToTake() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        await reminders.userCreates(title: "Read chapter 3", due: Fixture.day(9, 20))
        _ = try await sync.sync()
        let loose = IngestResult(document: DocumentInfo(name: "notes.pdf", sha256: "loose", kind: .pdf, pageCount: 1),
                                 obligations: [ParsedObligation(title: "Read chapter 3", dateAsWritten: "9/21", due: Fixture.day(9, 21), status: .ready)])
        let summary = try await Fixture.ingest(loose, into: store)
        var mine = try await store.obligations().first { $0.origin == .reminders }!
        #expect(summary.created == 0 && Fixture.calendar.isDate(mine.due!, inSameDayAs: Fixture.day(9, 20)) && mine.sourceDocumentID == nil)   // the user's date stands
        let doc = try await store.documents().first { $0.sha256 == "loose" }!
        try await store.deleteDocument(id: doc.id)
        _ = try await sync.sync()
        mine = try await store.obligations().first { $0.origin == .reminders }!
        let stillThere = await reminders.items.contains { $0.title == "Read chapter 3" }
        #expect(mine.deletedAt == nil && stillThere)
    }

    @Test func recreateWithTheListThereLeavesADeletionDeleted() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        await reminders.userDeletes(externalID: hw1.ekExternalID!)
        _ = try await sync.restoreList()                                               // a stale Recreate: the list is there
        let row = try await store.obligations(includeDeleted: true).first { $0.id == hw1.id }!
        let back = await reminders.items.contains { $0.title.hasPrefix("HW 1") }
        #expect(row.deletedAt != nil && !back)
    }

    @Test func aRenamedDeviceStillWritesTheRowsItMade() async throws {
        // Without CloudKit every row in a store is this device's, whatever it was called when it made them.
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store, device: "Daniel's MacBook")
        let report = try await SyncCoordinator.device("Daniel's MacBook (2)", store: store, reminders: reminders).sync()
        #expect(report.created == 4 && report.waiting == 0)
    }

    @Test func anItemDeletedByHandComesBackAsItWas() async throws {
        let reminders = FakeReminderStore()
        let store = try Fixture.store()
        try await Fixture.ingest(Fixture.calculus(), into: store)
        let sync = SyncCoordinator.device("A", store: store, reminders: reminders)
        _ = try await sync.sync()
        let hw1 = try await store.obligations().first { $0.title == "HW 1" }!
        try await store.setCompleted(id: hw1.id, true)
        _ = try await sync.sync()
        try await store.softDelete(id: hw1.id)
        _ = try await sync.sync()                                                      // its reminder goes
        #expect(!(await reminders.items.contains { $0.title.hasPrefix("HW 1") }))
        try await store.undelete(id: hw1.id)                                           // ⌘Z
        _ = try await sync.sync()
        _ = try await sync.sync()
        let row = try await store.obligations().first { $0.id == hw1.id }
        let reminder = await reminders.items.first { $0.title.hasPrefix("HW 1") }
        #expect(row?.completedAt != nil && row?.state == .projected && reminder?.isCompleted == true)
        #expect(abs((row?.pointsAtStake ?? 0) - 1.5) < 1e-9)
        // One that went with its document comes back only with it.
        let doc = try await store.documents().first!
        try await store.deleteDocument(id: doc.id)
        try await store.undelete(id: hw1.id)
        #expect(try await store.obligations().isEmpty)
    }
}
