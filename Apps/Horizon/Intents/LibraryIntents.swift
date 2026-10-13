import AppIntents
import Foundation
import HorizonCore
import IngestKit
import UniformTypeIdentifiers

// The library from outside the app: read documents (handed over by Shortcuts, say from iOS 27's "when a screenshot is
// saved" automation; one already in Horizon, again; or one chosen in the app), sync with Reminders, the bin, courses,
// and the settings that say what leaves the device. Each goes through the app's own `AppModel` call and the user's own
// switches: a document reaches Claude only on the reading route the user chose, and nothing is erased for good from
// here (Delete for Good stays in the app, where it is asked about and seen).

/// SPEC §7's `IngestDocumentIntent`, and every way a document is read: files handed over, a document already in Horizon
/// read again (Retry) or filed under a course, on this device instead of with Claude (the user's word, asked once more
/// as the app asks), or, given nothing, Horizon opened at Files, Photos or the camera to choose one. A read takes from
/// seconds (Claude) to minutes (the device's model), so it runs long with its progress shown, and stops waiting, never
/// reading, after ten minutes: whatever is left is read as the app reads anything queued.
struct ReadDocumentIntent: LongRunningIntent {
    static let title: LocalizedStringResource = "Read Document"
    static let description = IntentDescription("Reads a syllabus, schedule, screenshot or assignment list and adds what's due to Horizon and Reminders: files you give it, or a document already in Horizon that couldn't be read. Given neither, it opens Horizon to choose one from Files, Photos or the camera. It's read as Settings says, by Claude or on this device; On This Device keeps it on the device.",
                                               categoryName: "Documents", searchKeywords: ["syllabus", "screenshot", "import", "scan", "retry", "read again", "file under", "add document"],
                                               resultValueName: "Documents")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Files", default: [], supportedContentTypes: ReadDocumentIntent.types) var files: [IntentFile]
    @Parameter(title: "Document", description: "A document already in Horizon: one that couldn't be read is read again, and with a course it's filed under it.")
    var document: DocumentEntity?
    @Parameter(title: "Course", description: "The course the documents are filed under.") var course: CourseEntity?
    @Parameter(title: "On This Device", description: "Read by this device's own model: nothing leaves the device, and tables and pictures are read less well.", default: false)
    var onThisDevice: Bool
    @Parameter(title: "Choose From", description: "Given no file or document, where Horizon opens to choose one.", default: .screenshots) var source: ImportChoice
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary {
        When(\.$document, .hasAnyValue) {
            Summary("Read \(\.$document) into \(\.$course)") { \.$onThisDevice }
        } otherwise: {
            Summary("Read \(\.$files) into \(\.$course)") { \.$document; \.$onThisDevice; \.$source }
        }
    }

    static var types: [UTType] {
        #if os(macOS)
        [.pdf, .image, .plainText, UTType("org.openxmlformats.wordprocessingml.document") ?? .data]
        #else
        [.pdf, .image, .plainText]
        #endif
    }

    @MainActor func perform() async throws -> some ReturnsValue<[DocumentEntity]> & ProvidesDialog {
        try model.requireLibrary()
        let courseID = course.flatMap { $0.isUnfiled ? nil : $0.id }
        if courseID != nil, try await model.intentCourse(courseID) == nil { throw IntentFailure.message("That course is no longer in Horizon.") }
        // On This Device is the user's word for these documents; with Settings reading by Claude, it's asked once more,
        // as Read on This Device… asks in the app. Read on the device already, there's nothing to ask.
        let askFirst = onThisDevice && model.readingRoute == .claude
        let outcome: [ReadOutcome]

        if !files.isEmpty {
            if askFirst {
                try await requestConfirmation(actionName: .continue, dialog: "Read \(files.count == 1 ? "it" : "them") on this device instead of with Claude? Nothing leaves the device; tables and pictures are read less well.")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shared-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var urls: [URL] = []
            for file in files {
                var name = (file.filename as NSString).lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension { name += "." + ext }   // a document is typed by its extension
                let url = folder.appendingPathComponent(name.isEmpty ? "Document" : name)
                try file.data.write(to: url)
                urls.append(url)
            }
            let progress = self.progress
            let model = self.model
            let read = urls, onDevice = onThisDevice
            outcome = try await performBackgroundTask { @MainActor @Sendable in
                try await model.read(read, courseID: courseID, onDevice: onDevice, progress: progress)
            }
        } else if let document {
            guard let snapshot = try await model.store.document(id: document.id) else { throw IntentFailure.message("That document is no longer in Horizon.") }
            var filed = ""
            if let courseID, snapshot.courseID != courseID {
                await model.assignDocument(snapshot.id, to: courseID)
                filed = "Filed \(snapshot.displayName) under \(course?.name ?? "it")."
            }
            switch snapshot.status {
            case .parsed:
                return .result(value: [], dialog: "\(filed.isEmpty ? "\(snapshot.displayName.sentenceStart) is already read." : filed)")
            case .failed where snapshot.failureIsPermanent:
                throw IntentFailure.message("Reading \(snapshot.displayName) again would fail the same way: \(snapshot.failure ?? "the file can't be read").")
            case .queued, .failed, .cancelled, .awaitingCloudParse:
                if askFirst {
                    try await requestConfirmation(actionName: .continue, dialog: "Read \(snapshot.displayName) on this device instead of with Claude? Nothing leaves the device; tables and pictures are read less well.")
                }
                let progress = self.progress
                let model = self.model
                let id = snapshot.id, onDevice = onThisDevice, status = snapshot.status
                outcome = try await performBackgroundTask { @MainActor @Sendable in
                    // Queued again (Retry), or for the device (Read on This Device), then read as the app reads anything queued.
                    if onDevice { try await model.store.readOnDevice(id: id) } else if status != .queued { try await model.store.markDocument(id: id, status: .queued) }
                    return try await model.follow([id], progress: progress)
                }
            }
        } else {
            // Nothing handed over: Horizon opens at the chooser, and reading what's chosen is the user's tap there.
            try await continueInForeground(nil, alwaysConfirm: false)
            model.navigate(to: .importDocument(source))
            return .result(value: [], dialog: "Choose the document in Horizon.")
        }
        let entities = try await model.intentDocuments().filter { entity in outcome.contains { $0.id == entity.id } }
        return .result(value: entities, dialog: "\(ReadOutcome.sentence(outcome))")
    }
}

/// What became of one document handed over.
struct ReadOutcome: Sendable {
    var id: UUID
    var name: String
    var status: DocumentStatus
    var failure: String?
    var added: Int
    var toReview: Int
    var alreadyOnFile: Bool

    /// "Read Calculus II Syllabus: 18 items, 3 to review." for each document, said in turn.
    static func sentence(_ outcomes: [ReadOutcome]) -> String {
        outcomes.map { o in
            if o.alreadyOnFile { return "\(o.name.sentenceStart) is already on file." }
            switch o.status {
            case .parsed:
                let review = o.toReview > 0 ? ", \(o.toReview) to review" : ""
                return "Read \(o.name): \(Spoken.count(o.added, "new item"))\(review)."
            case .awaitingCloudParse: return "\(o.name.sentenceStart) waits for Claude: \(o.failure ?? "it could not be reached")."
            case .failed: return "Couldn't read \(o.name): \(o.failure ?? "it could not be read")."
            case .cancelled: return "Reading \(o.name) was cancelled."
            case .queued: return "\(o.name.sentenceStart) is queued; Horizon reads it as soon as it can."
            }
        }.joined(separator: " ")
    }
}

extension AppModel {
    /// Documents from an intent: queued as a share or a pick would queue them (for this device's model when the user
    /// said so), then read by the app's own drain (its route, its key, its sync), the intent's progress following the
    /// reading bar. Returns once each is read, has failed or waits for Claude, or after ten minutes.
    func read(_ urls: [URL], courseID: UUID?, onDevice: Bool, progress: Progress) async throws -> [ReadOutcome] {
        try requireLibrary()
        var queued: [UUID] = []
        var duplicates: Set<UUID> = []
        for url in urls {
            let document = try await coordinator.enqueue(fileURL: url, courseID: courseID)
            if document.status == .parsed { duplicates.insert(document.id) }   // the same file again: nothing to read
            else if onDevice { try await store.readOnDevice(id: document.id) }
            queued.append(document.id)
        }
        Self.log("intent: queued \(queued.count) document(s) to read")
        return try await follow(queued, alreadyOnFile: duplicates, progress: progress)
    }

    /// The documents still queued read by the app's own drain, waited for until each is read, has failed or waits for
    /// Claude, or ten minutes have gone; what became of each.
    func follow(_ ids: [UUID], alreadyOnFile duplicates: Set<UUID> = [], progress: Progress) async throws -> [ReadOutcome] {
        var queued: [DocumentSnapshot] = []
        for id in ids { if let document = try await store.document(id: id) { queued.append(document) } }
        progress.totalUnitCount = Int64(max(queued.count, 1) * 100)
        let waiting = queued.filter { !duplicates.contains($0.id) && $0.status == .queued }.map(\.id)
        let before = reports.count
        if !waiting.isEmpty {
            Task { await drainAndSync() }
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline, !Task.isCancelled {
                var open = 0
                for id in waiting where try await store.document(id: id)?.status == .queued { open += 1 }
                var done = Double(waiting.count - open)
                if let reading, waiting.contains(reading.documentID) { done += reading.fraction }
                progress.completedUnitCount = Int64(done / Double(max(waiting.count, 1)) * Double(progress.totalUnitCount))
                if open == 0 { break }
                if Self.scratchStore != nil { break }   // a scratch store reads nothing
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        progress.completedUnitCount = progress.totalUnitCount
        let recent = reports.prefix(max(0, reports.count - before + queued.count))
        var outcomes: [ReadOutcome] = []
        for document in queued {
            let now = try await store.document(id: document.id) ?? document
            let summary = recent.first { $0.document.id == document.id }?.summary
            outcomes.append(ReadOutcome(id: document.id, name: now.displayName, status: now.status, failure: now.failure, added: summary?.created ?? 0,
                                        toReview: summary?.pendingReview ?? 0, alreadyOnFile: duplicates.contains(document.id)))
        }
        return outcomes
    }
}

/// The pull to refresh, from outside: read what is queued and sync with Reminders. A Horizon list deleted from Reminders
/// is made again only on the user's word (Recreate List), which Recreate the List is, asked once more.
struct SyncIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync with Reminders"
    static let description = IntentDescription("Reads any documents waiting, then brings Horizon and its Reminders list into step: checks made in either, items added or changed. If the Horizon list was deleted from Reminders, Recreate the List makes it again with every item in it.",
                                               categoryName: "Reminders", searchKeywords: ["refresh", "update", "reminders", "recreate", "list"])
    @Parameter(title: "Recreate the List", description: "If the Horizon list was deleted from Reminders, make it again, with every item in it, the checked ones checked.", default: false)
    var recreate: Bool
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Sync with Reminders") { \.$recreate } }

    @MainActor func perform() async throws -> some ProvidesDialog {
        try model.requireLibrary()
        await model.drainAndSync()
        if model.remindersAuthorized != true { return .result(dialog: "Horizon can't reach Reminders: its access is off. Turn it on in Settings, under Privacy, Reminders.") }
        if model.remindersListGone {
            guard recreate else {
                return .result(dialog: "The Horizon list is gone from Reminders, so nothing was written there. Ask Horizon to sync and recreate the list, or open Horizon.")
            }
            try await requestConfirmation(actionName: .create, dialog: "Make the Horizon list again in Reminders, with every item in it?")
            await model.recreateRemindersList()
            return .result(dialog: "\(model.lastError.map { "That didn't work: \($0)" } ?? model.statusLine ?? "The Horizon list is back.")")
        }
        if let error = model.lastError { return .result(dialog: "The sync didn't finish: \(error)") }
        return .result(dialog: "\(model.statusLine ?? "Horizon and Reminders are in step.")")
    }
}

/// A course to Recently Deleted, with its items, documents and reminders: back from there for thirty days.
struct DeleteCourseIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Course"
    static let description = IntentDescription("Moves a course to Recently Deleted with its items, documents and reminders. It can be restored for 30 days.", categoryName: "Courses")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Course") var course: CourseEntity
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$course)") }

    @MainActor func perform() async throws -> some ProvidesDialog {
        try model.requireLibrary()
        guard !course.isUnfiled, try await model.intentCourse(course.id) != nil else { throw IntentFailure.message("That course is no longer in Horizon.") }
        // The app's own Delete asks nothing (the bin is the undo); a spoken one, heard wrong, would take a course's
        // reminders with it unseen, so it asks.
        try await requestConfirmation(actionName: .continue, dialog: "Delete \(course.name)? Its items and reminders go with it. It stays in Recently Deleted for 30 days.")
        await model.deleteCourse(course.id)
        return .result(dialog: "Deleted \(course.name). It's in Recently Deleted for 30 days.")
    }
}

/// Something in Recently Deleted: a course (with what went with it) or a document.
struct BinnedEntity: AppEntity {
    static let defaultQuery = BinnedQuery()
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recently Deleted", numericFormat: "\(placeholder: .int) deleted")

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Is a Course") var isCourse: Bool
    @Property(title: "Deleted") var deleted: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(isCourse ? "Course" : "Document")", image: .init(systemName: isCourse ? "book.closed" : "doc.text"))
    }

    init(id: UUID, name: String, isCourse: Bool, deleted: Date?) {
        self.id = id; self.name = name; self.isCourse = isCourse; self.deleted = deleted
    }
}

struct BinnedQuery: EntityStringQuery {
    @Dependency var model: AppModel

    @MainActor func all() async throws -> [BinnedEntity] {
        try model.requireLibrary()
        let courses = try await model.store.deletedCourses().map { BinnedEntity(id: $0.id, name: $0.displayName, isCourse: true, deleted: $0.deletedAt) }
        let documents = try await model.store.deletedDocuments().map { BinnedEntity(id: $0.id, name: $0.displayName, isCourse: false, deleted: $0.deletedAt) }
        return courses + documents
    }
    @MainActor func entities(for identifiers: [BinnedEntity.ID]) async throws -> [BinnedEntity] { try await all().filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [BinnedEntity] {
        let words = string.lowercased().split(separator: " ")
        return try await all().filter { entity in words.allSatisfy { entity.name.lowercased().contains($0) } }
    }
    @MainActor func suggestedEntities() async throws -> [BinnedEntity] { try await all() }
}

struct RestoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Restore from Recently Deleted"
    static let description = IntentDescription("Puts a course or document back from Recently Deleted, with exactly what went with it.", categoryName: "Courses")
    @Parameter(title: "What") var target: BinnedEntity
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Restore \(\.$target)") }

    @MainActor func perform() async throws -> some ProvidesDialog {
        try model.requireLibrary()
        if target.isCourse { await model.restoreCourse(target.id) } else { await model.restoreDocument(target.id) }
        return .result(dialog: "Restored \(target.name).")
    }
}

struct DeleteDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Document"
    static let description = IntentDescription("Moves a document to Recently Deleted. The items only it listed go with it; items another document lists stay.", categoryName: "Documents")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Document") var document: DocumentEntity
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$document)") }

    @MainActor func perform() async throws -> some ProvidesDialog {
        try model.requireLibrary()
        try await requestConfirmation(actionName: .continue, dialog: "Delete \(document.name)? The items only it lists go with it, for 30 days in Recently Deleted.")
        await model.deleteDocument(document.id)
        return .result(dialog: "Deleted \(document.name).")
    }
}

/// A course's name, code, term or instructor, by hand: each a field the documents then leave alone.
struct EditCourseIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Course"
    static let description = IntentDescription("Changes a course's name, code, term or instructor. A change by hand stays when a document is read again.", categoryName: "Courses")
    @Parameter(title: "Course") var course: CourseEntity
    @Parameter(title: "Name") var name: String?
    @Parameter(title: "Code") var code: String?
    @Parameter(title: "Term") var term: String?
    @Parameter(title: "Instructor") var instructor: String?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Edit \(\.$course)") { \.$name; \.$code; \.$term; \.$instructor }
    }

    @MainActor func perform() async throws -> some ReturnsValue<CourseEntity> & ProvidesDialog {
        try model.requireLibrary()
        guard !course.isUnfiled, try await model.intentCourse(course.id) != nil else { throw IntentFailure.message("That course is no longer in Horizon.") }
        func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        let edits = CourseEdits(title: clean(name), code: clean(code), term: clean(term).map { .some($0) }, instructor: clean(instructor).map { .some($0) })
        guard edits != CourseEdits() else { throw IntentFailure.message("Say what to change: its name, code, term or instructor.") }
        await model.updateCourse(course.id, edits: edits)
        guard let after = try await model.intentCourse(course.id) else { throw IntentFailure.message("That course is no longer in Horizon.") }
        return .result(value: CourseEntity(after), dialog: "Updated \(after.displayName).")
    }
}

/// Horizon's settings, in one action (Apple's apps change theirs through one, the setting a parameter): which model
/// reads documents and which plans the day, Claude (with the user's key) or this device's own, and which Claude.
/// What leaves the device is the user's to choose, so anything that would send more is asked about and wants the device
/// unlocked; the key itself is typed in Settings, never spoken or passed through a shortcut.
struct ChangeSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Settings"
    static let description = IntentDescription("Chooses what reads documents and what plans the day: Claude, with your Anthropic key (what it reads or plans from is sent to Anthropic), or this device's own model (nothing leaves the device); and which Claude model. Given nothing, it says how they're set.",
                                               categoryName: "Settings", searchKeywords: ["Claude", "on device", "privacy", "model", "AI", "provider", "Sonnet", "Opus", "Haiku"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Read Documents With") var reading: ModelProvider?
    @Parameter(title: "Plan the Day With") var planning: ModelProvider?
    @Parameter(title: "Claude Model", description: "The Claude model that reads and plans, for whichever uses Claude.") var claudeModel: ClaudeModelOption?
    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Read documents with \(\.$reading) and plan the day with \(\.$planning)") { \.$claudeModel }
    }

    @MainActor func perform() async throws -> some ProvidesDialog {
        let toClaude = (reading == .claude && model.readingRoute != .claude) || (planning == .claude && !model.planWithClaude)
        if toClaude || claudeModel != nil, model.claudeConfiguration == nil {
            throw IntentFailure.message("Claude needs your Anthropic API key first. Add it in Horizon's Settings.")
        }
        if toClaude {
            let sent = [reading == .claude && model.readingRoute != .claude ? "each document's text and pages" : nil,
                        planning == .claude && !model.planWithClaude ? "each plan's events, items and what you told the planner" : nil].compactMap { $0 }
            let which = (claudeModel?.choice ?? model.claudeModel).displayName
            try await requestConfirmation(actionName: .set, dialog: "Use Claude \(which)? \(Spoken.list(sent).sentenceStart) will be sent to Anthropic under your key.")
        }
        if let claudeModel { model.claudeModel = claudeModel.choice }
        if let reading { model.readingRoute = reading == .claude ? .claude : .onDevice }
        if let planning { model.planWithClaude = planning == .claude }
        let claude = "Claude \(model.claudeModel.displayName)"
        let reads = model.readingRoute == .claude ? "\(claude) reads documents" : "Documents are read on this device"
        let plans = model.planWithClaude ? (model.readingRoute == .claude ? "and plans your day" : "and \(claude) plans your day") : "and the device plans your day"
        let changed = reading != nil || planning != nil || claudeModel != nil
        return .result(dialog: "\(changed ? "Done. " : "")\(reads) \(plans).")
    }
}

/// Who does a job: Claude, or the device's own model.
enum ModelProvider: String, AppEnum {
    case claude, thisDevice
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Model"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .claude: DisplayRepresentation(title: "Claude", synonyms: ["in the cloud", "Anthropic"]),
        .thisDevice: DisplayRepresentation(title: "This Device", synonyms: ["on device", "on this device", "privately", "locally", "Apple Intelligence"]),
    ]
}

/// The Claude models Settings offers.
enum ClaudeModelOption: String, AppEnum {
    case sonnet5, opus5, haiku45
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Claude Model"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .sonnet5: DisplayRepresentation(title: "Sonnet 5", synonyms: ["Sonnet"]),
        .opus5: DisplayRepresentation(title: "Opus 5", synonyms: ["Opus"]),
        .haiku45: DisplayRepresentation(title: "Haiku 4.5", synonyms: ["Haiku"]),
    ]
    var choice: ClaudeModelChoice {
        switch self {
        case .sonnet5: .sonnet5
        case .opus5: .opus5
        case .haiku45: .haiku45
        }
    }
}
