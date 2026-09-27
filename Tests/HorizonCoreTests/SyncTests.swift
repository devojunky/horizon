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
