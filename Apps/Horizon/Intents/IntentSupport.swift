import AppIntents
import Foundation
import HorizonCore
import IngestKit

/// Why an intent could not do what was asked, in words Siri can say as they are (HIG: specific, helpful errors).
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    /// The library would not open (`StoreFailure`): nothing can be read or changed until it does.
    case noLibrary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        case .noLibrary: "Horizon could not open its library. Open Horizon to see why."
        }
    }
}

/// What the intents read and do, through the app's one model: the same store, the same sync and the same switches as
/// the app's own pages, so an intent can never do what the app would not (send a document to Claude unasked, write
/// Reminders around the sync, delete without its undo).
extension AppModel {
    func requireLibrary() throws {
        if storeFailure != nil { throw IntentFailure.noLibrary }
    }

    /// The live courses in the user's order (the Mac's sidebar, and Coverage once one is set), else by name.
    func intentCourses() async throws -> [CourseSnapshot] {
        try requireLibrary()
        return try await store.courses().sorted {
            ($0.sortOrder ?? .max, $0.displayName.localizedLowercase) < ($1.sortOrder ?? .max, $1.displayName.localizedLowercase)
        }
    }

    /// Live items, with their courses by id.
    func intentItems() async throws -> ([ObligationSnapshot], [UUID: CourseSnapshot]) {
        try requireLibrary()
        let courses = try await intentCourses()
        return (try await store.obligations(), Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    func intentItem(_ id: UUID) async throws -> ObligationSnapshot {
        try requireLibrary()
        guard let item = try await store.obligation(id: id) else { throw IntentFailure.message("That item is no longer in Horizon.") }
        return item
    }

    func intentPolicies() async throws -> [PolicySnapshot] {
        try requireLibrary()
        return try await store.policies()
    }

    func intentDocuments() async throws -> [DocumentEntity] {
        try requireLibrary()
        let names = Dictionary(try await intentCourses().map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return try await store.documents().sorted { $0.queuedAt > $1.queuedAt }.map { DocumentEntity($0, course: $0.courseID.flatMap { names[$0] }) }
    }

    func itemEntity(_ id: UUID) async throws -> ItemEntity {
        let item = try await intentItem(id)
        return ItemEntity(item, course: try await intentCourse(item.courseID))
    }

    /// A live course by id; nil for none.
    func intentCourse(_ id: UUID?) async throws -> CourseSnapshot? {
        guard let id else { return nil }
        return try await store.course(id: id)
    }

    /// A copy of a document's file under the name the app calls it, for handing to another app; nil when the file is
    /// not on this device (read elsewhere, or erased).
    func exportFile(sha256: String, kind: String, name: String) -> URL? {
        guard storage.exists(sha256: sha256, extension: kind) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let copy = folder.appendingPathComponent(safe).appendingPathExtension(kind)
        do { try FileManager.default.copyItem(at: storage.url(sha256: sha256, extension: kind), to: copy); return copy } catch { return nil }
    }
}

/// How the intents say dates and weights aloud: one form, so Siri's sentences and the app's rows agree.
enum Spoken {
    /// "today at 4 PM", "tomorrow", "Thursday, October 9 at 11:59 PM", "October 9" (a date with no time is a day).
    static func due(_ date: Date?, hasTime: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "with no date yet" }
        let time = hasTime ? " at " + date.formatted(date: .omitted, time: .shortened) : ""
        if calendar.isDate(date, inSameDayAs: now) { return "today" + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" + time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if (0..<7).contains(days) { return date.formatted(.dateTime.weekday(.wide)) + time }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day()) + time
    }

    /// "worth 20%", or nothing when no document gave a weight.
    static func weight(_ points: Double?) -> String? {
        points.map { "worth \($0.formatted(.number.precision(.fractionLength(0...1))))%" }
    }

    /// "Quiz 3, Thursday at 4 PM, worth 2%".
    static func item(_ o: ObligationSnapshot, course: Bool = false, now: Date = .now) -> String {
        [o.title + (course ? o.courseName.map { " for \($0)" } ?? "" : ""), due(o.due, hasTime: o.dueHasTime, now: now), weight(o.pointsAtStake)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// "a, b and c".
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        n == 1 ? "one \(singular)" : "\(n) \(plural ?? singular + "s")"
    }
}
