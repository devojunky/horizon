import Foundation
import Testing
import SwiftData
@testable import HorizonCore

/// A library carried to a new install comes back as it was: the same rows under the same ids, each item's reminder
/// identifier with it, the documents' files and the sync's memory, so the new install takes up the old reminders.
struct LibraryArchiveTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryArchiveTests-\(UUID().uuidString)", isDirectory: true)

    @Test func aLibraryComesBackAsItWas() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = root.appendingPathComponent("old/Horizon.store"), oldDocs = root.appendingPathComponent("old/Documents", isDirectory: true)
        let itemID: UUID, courseID: UUID
        do {
            let container = try HorizonContainer.at(oldStore)
            let context = ModelContext(container)
            let course = Course(code: "MA 1124", title: "Calculus II")
            let item = Obligation(title: "Quiz 4"); item.course = course; item.ekExternalID = "reminder-external-1"
            let gone = Obligation(title: "Old quiz"); gone.course = course; gone.deletedAt = Date()   // a tombstone stays one
            context.insert(course); context.insert(item); context.insert(gone)
            try context.save()
            itemID = item.id; courseID = course.id
            try FileManager.default.createDirectory(at: oldDocs, withIntermediateDirectories: true)
            try Data("syllabus".utf8).write(to: oldDocs.appendingPathComponent("abc123.pdf"))
            // Exported while the store is still open, as it is in the app.
            let manifest = LibraryArchive.Manifest(deviceName: "iPhone", courses: 1, items: 1, documents: 1)
            try LibraryArchive.export(store: oldStore, documents: oldDocs, sync: ["seenReminderIDs": ["reminder-external-1"], "horizonListID": "list-1", "AppleLanguages": ["en"]],
                                      settings: ["planInstructions": "No work after 9"], manifest: manifest, to: root.appendingPathComponent("Library.horizonlibrary"))
            _ = container
        }

        let newStore = root.appendingPathComponent("new/Horizon.store"), newDocs = root.appendingPathComponent("new/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: newDocs, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: newDocs.appendingPathComponent("stale.pdf"))
        let staged = try LibraryArchive.stage(root.appendingPathComponent("Library.horizonlibrary"), forStore: newStore)
        #expect(staged.items == 1 && staged.deviceName == "iPhone" && LibraryArchive.pendingManifest(forStore: newStore) == staged)

        let suite = "LibraryArchiveTests-\(UUID().uuidString)"
        let sync = UserDefaults(suiteName: suite + ".sync")!, settings = UserDefaults(suiteName: suite + ".settings")!
        defer { sync.removePersistentDomain(forName: suite + ".sync"); settings.removePersistentDomain(forName: suite + ".settings") }
        let applied = LibraryArchive.applyPending(store: newStore, documents: newDocs, sync: sync, settings: settings)
        #expect(applied == staged && LibraryArchive.pendingManifest(forStore: newStore) == nil)

        let context = ModelContext(try HorizonContainer.at(newStore))
        let items = try context.fetch(FetchDescriptor<Obligation>())
        let item = try #require(items.first { $0.id == itemID })
        #expect(item.ekExternalID == "reminder-external-1" && item.course?.id == courseID && item.title == "Quiz 4")
        #expect(items.contains { $0.title == "Old quiz" && $0.deletedAt != nil })
        #expect(try context.fetch(FetchDescriptor<Course>()).map(\.id) == [courseID])
        #expect(FileManager.default.fileExists(atPath: newDocs.appendingPathComponent("abc123.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: newDocs.appendingPathComponent("stale.pdf").path))   // the library is replaced, not merged
        #expect(sync.stringArray(forKey: "seenReminderIDs") == ["reminder-external-1"] && sync.string(forKey: "horizonListID") == "list-1")
        #expect(LibraryArchive.ownKeys(["AppleLanguages": ["en"], "NSWindow Frame": "x", "dayPlan": 1]).keys.sorted() == ["dayPlan"])   // the system's keys are not carried
        #expect(settings.string(forKey: "planInstructions") == "No work after 9")
    }

    @Test func whatIsNotALibraryOrIsTooNewIsRefusedBeforeAnythingIsTouched() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notOne = root.appendingPathComponent("notes.horizonlibrary")
        try Data("not an archive".utf8).write(to: notOne)
        let store = root.appendingPathComponent("lib/Horizon.store")
        #expect(throws: LibraryArchive.ArchiveError.notALibrary) { try LibraryArchive.stage(notOne, forStore: store) }
        #expect(LibraryArchive.pendingManifest(forStore: store) == nil)

        let oldStore = root.appendingPathComponent("old/Horizon.store")
        _ = try HorizonContainer.at(oldStore)
        let newer = LibraryArchive.Manifest(storeGeneration: HorizonContainer.storeGeneration + 1, deviceName: "iPhone", courses: 0, items: 0, documents: 0)
        let archive = root.appendingPathComponent("newer.horizonlibrary")
        try LibraryArchive.export(store: oldStore, documents: root.appendingPathComponent("none"), sync: [:], settings: [:], manifest: newer, to: archive)
        #expect(throws: LibraryArchive.ArchiveError.tooNew) { try LibraryArchive.stage(archive, forStore: store) }
        #expect(LibraryArchive.applyPending(store: store, documents: root.appendingPathComponent("docs"), sync: nil, settings: .standard) == nil)
    }
}
