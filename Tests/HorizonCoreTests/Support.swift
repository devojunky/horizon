import Foundation
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import IngestKit
@testable import HorizonCore

/// In-memory stand-in for Reminders shared by every "device" in a test.
actor FakeReminderStore: ReminderStore {
    private(set) var items: [ReminderItem] = []
    private var counter = 0
    /// False until the first create, or after the user deletes the whole list.
    private(set) var listExists = false
    /// The list's identity: a list made again after a deletion is a new one.
    private(set) var listID = "list-0"
    private var lists = 0
    var fetches = 0

    func requestAccess() async throws -> Bool { true }
    func fetchHorizonList() async throws -> HorizonList? { fetches += 1; return listExists ? HorizonList(id: listID, items: items) : nil }
    func ensureHorizonList() async throws { makeList() }
    func remove(externalID: String) async throws { items.removeAll { $0.externalID == externalID } }

    private func makeList() {
        guard !listExists else { return }
        listExists = true
        lists += 1
        listID = "list-\(lists)"
    }

    // Notes are written as EventKit's store writes them (`ReminderDraft.notes(over:)`), over whatever the reminder holds.
    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        makeList()
        counter += 1
        let item = ReminderItem(externalID: "ext-\(counter)", title: draft.title, due: draft.due, hasTime: draft.hasTime, notes: draft.notes(over: nil), url: draft.url)
        items.append(item)
        return item
    }

    func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem? {
        guard let i = items.firstIndex(where: { $0.externalID == externalID }) else { return nil }
        items[i].title = draft.title; items[i].due = draft.due; items[i].hasTime = draft.hasTime; items[i].notes = draft.notes(over: items[i].notes); items[i].url = draft.url
        return items[i]
    }

    func setCompleted(externalID: String, _ completed: Bool, at date: Date?) async throws -> Bool {
        guard let i = items.firstIndex(where: { $0.externalID == externalID }) else { return false }
        items[i].isCompleted = completed; items[i].completionDate = completed ? date ?? Date() : nil
        return true
    }

    // What a user does in the Reminders app.
    func userDeletes(externalID: String) { items.removeAll { $0.externalID == externalID } }
    func userCompletes(externalID: String) { if let i = items.firstIndex(where: { $0.externalID == externalID }) { items[i].isCompleted = true; items[i].completionDate = Date() } }
    func userUncompletes(externalID: String) { if let i = items.firstIndex(where: { $0.externalID == externalID }) { items[i].isCompleted = false; items[i].completionDate = nil } }
    func userEdits(externalID: String, title: String? = nil, due: Date? = nil) {
        guard let i = items.firstIndex(where: { $0.externalID == externalID }) else { return }
        if let title { items[i].title = title }
        if let due { items[i].due = due }
    }
    func userCreates(title: String, due: Date?) { makeList(); counter += 1; items.append(ReminderItem(externalID: "ext-\(counter)", title: title, due: due, hasTime: false)) }
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

/// A one-way gate: whoever waits is held until it is released (and passes at once after).
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

actor Flag { var on = false; func set() { on = true } }

/// Reminders around a fake, with a hook on the calls a race needs to hold: every fetch can take a while, and a create or
/// a completion write can wait at a gate after it lands (the reminder written, the store not yet told).
struct HeldReminders: ReminderStore {
    let inner: FakeReminderStore
    var fetchDelay: Duration = .zero
    var holdCreate: (entered: Gate, proceed: Gate)? = nil
    var holdCompletion: (entered: Gate, proceed: Gate)? = nil
    func requestAccess() async throws -> Bool { true }
    func fetchHorizonList() async throws -> HorizonList? {
        if fetchDelay > .zero { try await Task.sleep(for: fetchDelay) }
        return try await inner.fetchHorizonList()
    }
    func ensureHorizonList() async throws { try await inner.ensureHorizonList() }
    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        if let holdCreate { await holdCreate.entered.release(); await holdCreate.proceed.wait() }
        return try await inner.create(draft)
    }
    func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem? { try await inner.update(externalID: externalID, with: draft) }
    func setCompleted(externalID: String, _ completed: Bool, at date: Date?) async throws -> Bool {
        let written = try await inner.setCompleted(externalID: externalID, completed, at: date)
        if let holdCompletion { await holdCompletion.entered.release(); await holdCompletion.proceed.wait() }
        return written
    }
    func remove(externalID: String) async throws { try await inner.remove(externalID: externalID) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var value: [String] { lock.withLock { stored } }
    func append(_ s: String) { lock.withLock { stored.append(s) } }
}

extension Fixture {
    /// A file of its own for a coordinator to enqueue.
    static func file(_ name: String, _ text: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(name)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A picture of its own, a blank page with no words in it, for a coordinator to enqueue.
    static func picture(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(name)")
        let page = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        page.setFillColor(CGColor(gray: 1, alpha: 1))
        page.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(file, page.makeImage()!, nil)
        guard CGImageDestinationFinalize(file) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
