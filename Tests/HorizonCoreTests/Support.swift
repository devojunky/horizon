import Foundation
import SwiftData
import IngestKit
@testable import HorizonCore

/// In-memory stand-in for Reminders shared by every "device" in a test.
actor FakeReminderStore: ReminderStore {
    private(set) var items: [ReminderItem] = []
    private var counter = 0
    /// False until the first create, or after the user deletes the whole list.
    private(set) var listExists = false
    var fetches = 0

    func requestAccess() async throws -> Bool { true }
    func fetchHorizonItems() async throws -> [ReminderItem]? { fetches += 1; return listExists ? items : nil }
    func remove(externalID: String) async throws { items.removeAll { $0.externalID == externalID } }

    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        listExists = true
        counter += 1
        let item = ReminderItem(externalID: "ext-\(counter)", title: draft.title, due: draft.due, hasTime: draft.hasTime, notes: draft.notes, url: draft.url)
        items.append(item)
        return item
    }

    func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem? {
        guard let i = items.firstIndex(where: { $0.externalID == externalID }) else { return nil }
        items[i].title = draft.title; items[i].due = draft.due; items[i].hasTime = draft.hasTime; items[i].notes = draft.notes; items[i].url = draft.url
        return items[i]
    }

    // What a user does in the Reminders app.
    func userDeletes(externalID: String) { items.removeAll { $0.externalID == externalID } }
    func userCompletes(externalID: String) { if let i = items.firstIndex(where: { $0.externalID == externalID }) { items[i].isCompleted = true; items[i].completionDate = Date() } }
    func userEdits(externalID: String, title: String? = nil, due: Date? = nil) {
        guard let i = items.firstIndex(where: { $0.externalID == externalID }) else { return }
        if let title { items[i].title = title }
        if let due { items[i].due = due }
    }
    func userCreates(title: String, due: Date?) { listExists = true; counter += 1; items.append(ReminderItem(externalID: "ext-\(counter)", title: title, due: due, hasTime: false)) }
    func userAddsNote(externalID: String, _ text: String) {
        guard let i = items.firstIndex(where: { $0.externalID == externalID }) else { return }
        items[i].notes = (items[i].notes ?? "") + "\n" + text
    }
    func userDeletesList() { items.removeAll(); listExists = false }
}

extension SyncCoordinator {
    /// A coordinator for one "device" in a test.
    static func device(_ name: String, store: HorizonStore, reminders: FakeReminderStore) -> SyncCoordinator {
        SyncCoordinator(store: store, reminders: reminders, seen: InMemorySeenIDs(), deviceName: name)
    }
}

enum Fixture {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    static func day(_ m: Int, _ d: Int, year: Int = 2026, hour: Int = 23, minute: Int = 59) -> Date {
        calendar.date(from: DateComponents(year: year, month: m, day: d, hour: hour, minute: minute))!
    }

    /// A Calculus II syllabus result: two homeworks, one quiz, one exam, one TBD final.
    static func calculus(hw1: Date = day(9, 9), quizStatus: ObligationStatus = .ready, sha: String = "abc") -> IngestResult {
        IngestResult(
            document: DocumentInfo(name: "calc.pdf", sha256: sha, kind: .pdf, pageCount: 2),
            course: ParsedCourse(code: "MA-UY 1124", title: "Calculus II", term: "Fall 2026", termStart: day(9, 2, hour: 0, minute: 0)),
            gradeComponents: [ParsedGradeComponent(name: "Homework", weight: 0.15, expectedCount: 10), ParsedGradeComponent(name: "Quizzes", weight: 0.12), ParsedGradeComponent(name: "Final Exam", weight: 0.33)],
            obligations: [
                ParsedObligation(title: "HW 1", platform: .webAssign, componentName: "Homework", dateAsWritten: "Wed 9/9", due: hw1, status: .ready, pointsAtStake: 1.5, sourcePage: 1),
                ParsedObligation(title: "HW 2", platform: .webAssign, componentName: "Homework", dateAsWritten: "9/16", due: day(9, 16), status: .ready, pointsAtStake: 1.5, sourcePage: 1),
                ParsedObligation(title: "Quiz 1", componentName: "Quizzes", dateAsWritten: "Thu 9/17", due: day(9, 17), status: quizStatus, confidence: quizStatus == .ready ? 0.9 : 0.5),
                ParsedObligation(title: "Midterm 1", componentName: "Midterm 1", dateAsWritten: "Wednesday, October 7", due: day(10, 7), status: .ready, pointsAtStake: 20),
                ParsedObligation(title: "Final Exam", componentName: "Final Exam", dateAsWritten: "TBA", due: nil, status: .awaitingDate, pointsAtStake: 33),
            ],
            policies: [ParsedPolicy(kind: .lateWork, text: "Late homework is not accepted.")])
    }

    static func store() throws -> HorizonStore { HorizonStore(modelContainer: try HorizonContainer.inMemory()) }

    @discardableResult
    static func ingest(_ result: IngestResult, into store: HorizonStore, device: String = "A") async throws -> IngestSummary {
        let doc = try await store.enqueueDocument(filename: result.document.name, sha256: result.document.sha256, kind: "pdf", deviceName: device)
        return try await store.ingest(result, documentID: doc.id, calendar: calendar)
    }

    /// CloudKit stand-in: copy device A's rows into device B, optionally before A's external IDs have synced.
    static func replicate(from a: HorizonStore, to b: HorizonStore, includingExternalIDs: Bool) async throws {
        let doc = try await a.documents().first!
        let bDoc = try await b.enqueueDocument(filename: doc.filename, sha256: doc.sha256, kind: doc.kind, deviceName: doc.deviceName)
        try await b.replicate(try await a.obligations(includeDeleted: true), documentID: bDoc.id, includingExternalIDs: includingExternalIDs)
    }
}

extension HorizonStore {
    /// Test-only: insert rows with the same identities another device has (what CloudKit mirroring would do).
    func replicate(_ rows: [ObligationSnapshot], documentID: UUID, includingExternalIDs: Bool) throws {
        for row in rows {
            let o = Obligation(title: row.title)
            o.id = row.id; o.due = row.due; o.dueHasTime = row.dueHasTime; o.platform = row.platform; o.componentName = row.componentName
            o.pointsAtStake = row.pointsAtStake; o.confidence = row.confidence; o.state = row.state; o.origin = row.origin
            o.ekExternalID = includingExternalIDs ? row.ekExternalID : nil
            o.projectedTitle = row.projectedTitle; o.projectedDue = row.projectedDue; o.projectedNotes = row.projectedNotes; o.deletedAt = row.deletedAt
            o.createdOn = row.createdOn
            if !includingExternalIDs, row.state == .projected { o.state = .readyToProject }   // B has not seen A's projection yet
            modelContext.insert(o)
        }
        try modelContext.save()
    }
}
