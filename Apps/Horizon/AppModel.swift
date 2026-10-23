import SwiftUI
import SwiftData
import EventKit
import HorizonCore
import IngestKit
import os
#if canImport(UIKit)
import UIKit
#endif

/// The app's single object graph: store, ingest coordinator, Reminders sync. Views read state; work happens here.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let store: HorizonStore
    let coordinator: IngestCoordinator
    let sync: SyncCoordinator
    /// Where the documents' files are kept, each under its hash.
    let storage: DocumentStorage
    private let reminders: any ReminderStore

    var remindersAuthorized: Bool?
    /// The Horizon list this device wrote to is not in Reminders (deleted, or its account signed out). Nothing is written
    /// there until the user asks for it back; Coverage says so and offers Recreate List.
    var remindersListGone = false
    var busy = false
    private var rerun = false
    var statusLine: String?
    var lastError: String?
    var reports: [IngestCoordinator.Report] = []
    /// Where a link, an intent, a widget or a Spotlight result asked the app to go (`navigate(to:)`): the iOS tabs or
    /// the Mac's window in front take it and clear it. One router for all of them, so each place opens the same way.
    var destination: AppDestination?
    /// What Search looks for: the iOS Search tab's field, the Mac's sidebar field, or Siri's "search Horizon for…".
    var searchText = ""
    /// The searches the user ran on the iOS Search tab, newest first, shown there before anything is typed: a search is
    /// kept when it is submitted or one of its results is opened. This device's own, in the app's defaults.
    var recentSearches: [String] = AppModel.defaults.stringArray(forKey: "recentSearches") ?? [] {
        didSet { AppModel.defaults.set(recentSearches, forKey: "recentSearches") }
    }
    func rememberSearch() { recentSearches = SearchSuggestions.remembering(searchText, in: recentSearches) }
    /// Items an intent changed or deleted, perhaps while one is open in an editor: the editor loads them again, so its
    /// Save cannot write the fields it opened with back over the change.
    var changedElsewhere: ChangedItems?
    /// Spotlight's index, the widgets' glance and App Shortcuts' parameters, brought up to date as the store changes.
    @ObservationIgnored let systemViews = SystemViews()
    /// The model, for the few places App Intents' dependency injection cannot reach (an entity's file export).
    @ObservationIgnored static weak var current: AppModel?
    /// What the parser is reading right now, item by item as the model streams. Nil when idle.
    var reading: Reading?
    /// Where documents are read: Claude (the target model, with the user's own key) or the device's own model (nothing
    /// leaves the phone; no eye for tables or pictures). Persisted. A key entered turns Claude on; a key removed turns
    /// it off.
    enum ReadingRoute: String, CaseIterable { case claude, onDevice }
    var readingRoute: ReadingRoute = ReadingRoute(rawValue: AppModel.defaults.string(forKey: "readingRoute") ?? "") ?? .claude {
        didSet { AppModel.defaults.set(readingRoute.rawValue, forKey: "readingRoute") }
    }
    /// Which Claude. Persisted.
    var claudeModel: ClaudeModelChoice = ClaudeModelChoice(stored: AppModel.defaults.string(forKey: "claudeModel") ?? "") ?? .default {
        didSet { AppModel.defaults.set(claudeModel.rawValue, forKey: "claudeModel") }
    }
    /// The user's own key, in the Keychain and nowhere else.
    var claudeKey: String = AppModel.scratchStore == nil ? Keychain.read("claude") ?? "" : "" {   // a scratch run never sees the user's key
        didSet { if AppModel.scratchStore == nil { Keychain.write(claudeKey, account: "claude") } }
    }
    /// The day plan is a small task: the device model makes it unless the user asks for Claude. Persisted.
    var planWithClaude: Bool = AppModel.defaults.bool(forKey: "planWithClaude") {
        didSet { AppModel.defaults.set(planWithClaude, forKey: "planWithClaude") }
    }
    /// What a read or plan on Claude uses, or nil without a key.
    var claudeConfiguration: ClaudeConfiguration? {
        claudeKey.isEmpty ? nil : ClaudeConfiguration(apiKey: claudeKey, model: claudeModel)
    }
    /// Where the next read goes: Claude when chosen and keyed, else the device.
    var readRoute: IngestOptions.RoutePolicy { readingRoute == .claude && claudeConfiguration != nil ? .claude : .onDevice }

    struct Reading: Equatable {
        var documentID: UUID
        /// What the document is called while it is read: its title once the device model has named it, else its file's name, tidied.
        var name: String
        var chunk = 0
        var chunks = 0
        var images = 0
        /// Parts an earlier read of the document finished, taken from its checkpoint: the bar starts past them.
        var resumed = 0
        var found: [ProvisionalObligation] = []      // finished chunks
        var current: [ProvisionalObligation] = []    // the chunk being written now
        var items: [ProvisionalObligation] { found + current }
        /// Where the model is in the part being written: the stage and its count, with Claude's outline once it has
        /// committed to the items. Nil between parts.
        var progress: ReadProgress?
        /// Never moves backwards: parts finished plus how far the current part has come. With an outline the part's
        /// figure is exact (`ReadingProgress`); without one it is about a dozen rows per part. A part split in two
        /// reports the same index twice, so finishing counts half, and the next part's start 1.
        var fraction: Double = 0
        mutating func advance(to value: Double) { fraction = min(1, max(fraction, value)) }
        var total: Double { Double(max(chunks + images, 1)) }
        /// Where the bar creeps toward while the model thinks (`ProgressCreep`): the next item's share of the stage
        /// when the total is known, else the end of the part.
        var nextMark: Double {
            if let progress { return min(1, (Double(chunk - 1) + ReadingProgress.mark(progress)) / total) }   // never past the stage's band
            return min(1, Double(max(chunk, 1)) / total)
        }
        /// The obligations promised by the outline for the part being read, when Claude has said.
        var promised: Int? { progress?.outline?.titles.count }
    }
    /// Today's plan (SPEC §6.3), with the user's edits. Kept for the day, so a relaunch does not lose an edited plan:
    /// until 4 AM after it, or while a block of it is still on or asking (`DayPlan.kept`). Tomorrow starts from nothing.
    private(set) var plan: DayPlan?
    private(set) var planEdited = false
    /// The items the last plan chose from, for the block editor's picker.
    private(set) var planCandidates: [PlanObligation] = []
    private var planDay: Date?
    var planning = false
    /// The plan as the model writes it: complete blocks in time order, growing. Empty when nothing is being planned or
    /// nothing has arrived yet. Block identities are kept across updates, so the timetable's rows persist.
    private(set) var planDraft: [PlanBlock] = []
    /// Whether the plan on file arrived block by block (its rows are already on screen and need no reveal).
    private(set) var planStreamed = false
    /// The user's own instructions to the planner, standing or for today. Persisted; read on every plan.
    var planInstructions: String = AppModel.defaults.string(forKey: "planInstructions") ?? "" {
        didSet { AppModel.defaults.set(planInstructions, forKey: "planInstructions") }
    }
    /// The hours the planner fills on a usual day (Tell the Planner's "Your day"). Persisted.
    var usualPlanHours: PlanHours = AppModel.defaults.data(forKey: "planHours").flatMap { try? JSONDecoder().decode(PlanHours.self, from: $0) } ?? PlanHours() {
        didSet { AppModel.defaults.set(try? JSONEncoder().encode(usualPlanHours), forKey: "planHours") }
    }
    /// Tonight's end when the user changed it for one night (Now's "Tonight until"): for that day only, then the usual
    /// again. Persisted, so it outlasts the app leaving mid-evening.
    private var tonight: Tonight? = AppModel.defaults.data(forKey: "planTonight").flatMap { try? JSONDecoder().decode(Tonight.self, from: $0) } {
        didSet { AppModel.defaults.set(try? JSONEncoder().encode(tonight), forKey: "planTonight") }
    }
    private struct Tonight: Codable { var day: Date; var end: Int }
    private struct SavedPlan: Codable { var day: Date; var plan: DayPlan; var candidates: [PlanObligation]; var edited: Bool }
    #if os(iOS)
    /// The plan's Live Activity (the Lock Screen and the Dynamic Island); its Done button comes back through `PlanCommands`.
    private let activities = PlanActivityController()
    #endif
    private let calendarSource: any CalendarSource = EventKitCalendarSource()
    private var drainTask: Task<Void, Never>?
    private var cancelledDocument: UUID?
    private var cancelNotice: String?   // a notice that outlives the syncs after it (a cancel, a duplicate, the list back): shown until the next document is read
    #if os(iOS)
    /// iOS keeps the app running for a while after the user leaves, as long as it asks: every drain asks, so a read
    /// under way goes on in the background. When that time runs out the read is paused, not cancelled: the checkpoint
    /// keeps every part read so far, and the read goes on the moment the app is back, or in a background task.
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    private var paused = false   // background time ran out mid-read: the drain does not repeat until the app is active again (a background task, an intent or a Reminders change may still run one pass)
    #endif

    static let deviceName: String = {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }()

    /// Where the app's settings and the day's plan are kept: the user's own defaults, or for a scratch run a domain of
    /// its own, so testing on a copy never reads or rewrites the user's plan, hours or route (`.defaultAppStorage` puts
    /// the views' `@AppStorage` there too).
    static let defaults: UserDefaults = {
        guard scratchStore != nil else { return .standard }
        return UserDefaults(suiteName: Identifiers.bundlePrefix + ".scratch") ?? .standard
    }()

    /// DEBUG `--scratch-store <dir>`: the app on a copy of a store (`dir/Horizon.store`, copied there first) with its
    /// files in `dir/Documents`: nothing is read, Reminders is never reached, the inbox folder is not watched, nothing is
    /// indexed in Spotlight and no glance is written for the widgets. The calendar is the device's own: a plan made in a
    /// scratch run reads it (and sends it to Anthropic with a key and "Plan the day with Claude" on). Every run of the
    /// app on real data for testing goes this way, never on the user's own store (`HorizonContainer.at` refuses theirs).
    /// Nil in a release build.
    static let scratchStore: URL? = {
        #if DEBUG
        guard let i = CommandLine.arguments.firstIndex(of: "--scratch-store"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        #else
        return nil
        #endif
    }()

    /// Why the library could not be opened, when it could not: the app then shows only that (`StoreFailure`), reads
    /// nothing and never reaches Reminders.
    let storeFailure: String?

    /// An import waiting for the next launch to replace the library (`LibraryTransfer`), and the one the last launch
    /// applied.
    var pendingImport: LibraryArchive.Manifest?
    var importedLibrary: LibraryArchive.Manifest?

    init(container: ModelContainer, storeFailure: String? = nil) {
        self.container = container
        self.storeFailure = storeFailure
        store = HorizonStore(modelContainer: container)
        if storeFailure != nil {
            reminders = NoReminders()
            sync = SyncCoordinator(store: store, reminders: reminders, seen: InMemorySeenIDs(), deviceName: Self.deviceName)
            storage = .temporary()
        } else if let scratch = Self.scratchStore {
            reminders = NoReminders()
            sync = SyncCoordinator(store: store, reminders: reminders, seen: InMemorySeenIDs(), deviceName: Self.deviceName)
            storage = DocumentStorage(root: scratch.appendingPathComponent("Documents", isDirectory: true))
        } else {
            reminders = EventKitReminderStore()
            sync = SyncCoordinator(store: store, reminders: reminders, seen: DefaultsSeenIDs(), deviceName: Self.deviceName)
            storage = DocumentStorage.appGroup() ?? .temporary()
            remindersAuthorized = Self.remindersAccess()
        }
        var options = IngestOptions()
        options.log = { message in Task { @MainActor in AppModel.log(message) } }
        let box = ProgressBox()
        coordinator = IngestCoordinator(store: store, storage: storage, sync: sync, options: options, deviceName: Self.deviceName,
                                        progress: { p in Task { @MainActor in box.model?.apply(p) } })
        box.model = self
        loadPlan()
        Self.current = self
        if storeFailure == nil {
            // Every save the store makes (a read, a check, an edit, a sync) reaches Spotlight and the widgets a moment later.
            NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self.map { $0.systemViews.storeChanged($0) } }
            }
            systemViews.storeChanged(self)   // the first pass indexes everything afresh
        }
        #if os(iOS)
        activities.adopt()
        // The activity is brought in step before the intent returns: iOS may suspend an app it woke only for the
        // intent as soon as `perform()` is done, and an update left in a task of its own would never be drawn.
        PlanCommands.markDone = { [weak self] id in self?.markBlock(id, done: true, syncing: false); await self?.syncActivity() }
        PlanCommands.skip = { [weak self] id in self?.skipBlock(id, skipped: true, syncing: false); await self?.syncActivity() }
        PlanCommands.planDay = { [weak self] progress in await self?.planToday(reporting: progress) }
        PlanCommands.log = { Self.log($0) }
        Task { await syncActivity() }
        #endif
    }

    /// The Live Activity follows the plan on file. Called after every change to the plan, every minute while Now is open,
    /// and from the background refresh booked here for the moment it next changes by itself.
    func syncActivity() async {
        #if os(iOS)
        ActivityRefresh.schedule(at: await activities.sync(plan: plan, day: planDay))
        #endif
    }

    /// Breaks the init cycle between the coordinator's sink and self.
    private final class ProgressBox: @unchecked Sendable { weak var model: AppModel? }

    private func apply(_ p: DocumentProgress) {
        switch p.event {
        case .started(_, let chunks, let images, let resumed):
            withAnimation { reading = Reading(documentID: p.documentID, name: p.name, chunks: chunks, images: images, resumed: resumed) }   // the user's name for it, not the stored hash
        case .named(let title):
            guard var r = reading, let title, !title.isEmpty else { return }   // the device model's name for it takes over from the file's
            r.name = title
            withAnimation { reading = r }
        case .chunkStarted(let index):
            guard var r = reading else { return }   // copy, mutate, write back: no overlapping access to `reading`
            r.chunk = index + 1; r.current = []; r.advance(to: Double(index) / r.total)
            reading = r
        case .partial(_, let items):
            guard var r = reading else { return }
            r.current = items
            if r.progress?.outline == nil { r.advance(to: (Double(r.chunk - 1) + min(0.9, Double(items.count) / 12)) / r.total) }   // no outline (the device): rows are the measure
            reading = r
        case .progress(_, let stage):
            guard var r = reading else { return }
            r.progress = stage
            r.advance(to: (Double(r.chunk - 1) + ReadingProgress.fraction(stage)) / r.total)
            reading = r
        case .chunkFinished:
            guard var r = reading else { return }
            r.found += r.current; r.current = []; r.progress = nil
            r.advance(to: (Double(r.chunk - 1) + 0.5) / r.total)   // a split part may follow under the same index
            reading = r
        case .finished:
            withAnimation { reading = nil }
        }
    }

    #if DEBUG
    private var demoing = false
    /// `--demo-reading`: the reading section at its widest (a long title, a long item, a read in parts, picked up from a
    /// checkpoint), to check on any screen and at any type size that nothing in it wraps. Nothing is read.
    func demoReading() {
        demoing = true   // no drain clears it: the section stays up while the type size is changed under it
        reading = Reading(documentID: UUID(), name: "Organizational Behavior and Leadership Syllabus", chunk: 2, chunks: 3, resumed: 1,
                          progress: ReadProgress(stage: .obligations, done: 11, total: 18, current: "Problem Set 10: Sequences, Series and Convergence"), fraction: 0.55)
    }
    #endif

    private static let logger = Logger(subsystem: Identifiers.bundlePrefix, category: "ingest")
    static func log(_ message: String) {
        // The lines carry the user's own words (titles, calendar events, file names): readable in a DEBUG build, where
        // they are how the app is tested, and private in a release, where the unified log keeps them.
        #if DEBUG
        logger.notice("\(message, privacy: .public)")
        #else
        logger.notice("\(message, privacy: .private)")
        #endif
        #if DEBUG
        print("horizon: \(message)")   // the terminal sees what the unified log sees
        #endif
    }

    /// The scene is in front again: a plan from another day goes, and whatever is queued (a read paused when the app
    /// left, a document shared meanwhile) is read.
    func appBecameActive() {
        expirePlanIfStale()
        #if os(iOS)
        paused = false
        Task { await syncActivity() }   // an activity cannot start before the app is visible: the launch's try may have failed
        #endif
        Task { await drainAndSync() }
    }

    #if os(iOS)
    /// The user left: a read under way goes on under the background time asked for in `drainAndSync`; a processing
    /// task is booked for whatever is left, with the network when the reading happens in the cloud.
    func appEnteredBackground() {
        if reading != nil {
            let left = UIApplication.shared.backgroundTimeRemaining   // effectively infinite until iOS starts the clock: never an Int
            Self.log("background: reading goes on while iOS allows" + (left < 3600 ? " (\(Int(left)) s)" : ""))
        }
        BackgroundIngest.schedule(needsNetwork: readRoute == .claude)
    }

    private func holdBackgroundTime() {
        guard backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Reading documents") { [weak self] in self?.backgroundTimeExpired() }
    }

    private func releaseBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    /// Pauses the read: the document stays queued with its checkpoint, and the drain stops until the app is back.
    private func backgroundTimeExpired() {
        Self.log("background time ran out: the read is paused; it goes on when the app is back, or in a background task")
        paused = true
        drainTask?.cancel()
        BackgroundIngest.schedule(needsNetwork: readRoute == .claude)
        releaseBackgroundTime()
    }
    #endif

    func requestReminders() async {
        do { remindersAuthorized = try await reminders.requestAccess() } catch { remindersAuthorized = false; lastError = error.localizedDescription }
    }

    /// A `horizon://` link goes where it says (`AppDestination.init(url:)`: the item on a reminder, Now from the Live
    /// Activity, a day from a widget); anything else is a file to ingest.
    func open(_ url: URL) async {
        if let destination = AppDestination(url: url) { navigate(to: destination); return }
        guard url.isFileURL else { lastError = "Horizon cannot open that link."; return }
        await importFiles([url])
    }

    /// Asks the app to show a place: the iOS tabs or the Mac's window in front go there (and on a Mac the app comes forward).
    func navigate(to destination: AppDestination) {
        if case .search(let text) = destination { searchText = text }
        self.destination = destination
        #if os(macOS)
        NSApplication.shared.activate()
        #endif
    }

    /// Files picked in the app or handed over by the system. Security-scoped URLs are opened for the copy only.
    /// `courseID` files the documents under a course before they are read (the course page's Add Document).
    func importFiles(_ urls: [URL], courseID: UUID? = nil) async {
        var onFile: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let document = try await coordinator.enqueue(fileURL: url, courseID: courseID)
                if document.status == .parsed { onFile.append(document.displayName) }   // the same file again: nothing to read
            } catch {
                lastError = error.localizedDescription
                Self.log("import failed for \(url.lastPathComponent): \(error)")
            }
        }
        if !onFile.isEmpty {
            cancelNotice = onFile.count == 1 ? "\(onFile[0].sentenceStart) is already on file." : "\(onFile.count) of those documents are already on file."
            withAnimation { statusLine = cancelNotice }
        }
        await drainAndSync()
    }

    func assignDocument(_ id: UUID, to courseID: UUID) async {
        do { try await store.assignDocument(id: id, to: courseID) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its items now carry the course's name and points
    }

    /// Parse whatever is queued, then reconcile with Reminders and write what is ready. Safe to run repeatedly; a call
    /// that arrives during a run makes it run once more afterwards.
    func drainAndSync() async {
        if storeFailure != nil { return }   // the library did not open: nothing is read or synced
        #if DEBUG
        if demoing || Self.scratchStore != nil { return }   // a scratch store reads nothing and syncs nothing
        #endif
        guard !busy else { rerun = true; return }
        busy = true
        defer { busy = false }
        repeat {
            rerun = false
            #if os(iOS)
            holdBackgroundTime()
            #endif
            let task = Task { await self.drainOnce() }   // held so that Cancel, or the end of background time, can reach the read in progress
            drainTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }   // a background task expiring stops the read the same way
            drainTask = nil
            #if os(iOS)
            releaseBackgroundTime()
            if paused { return }
            #endif
        } while rerun && !Task.isCancelled
    }

    /// Stops the document being read. It is marked cancelled (Documents offers Retry) and whatever else is queued
    /// is read on the next pass.
    func cancelReading() {
        cancelledDocument = reading?.documentID
        drainTask?.cancel()
    }

    /// What the user decided about Reminders, read without asking: nil while undecided.
    private static func remindersAccess() -> Bool? {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: true
        case .notDetermined: nil
        default: false
        }
    }

    private func drainOnce() async {
        // The time zone moved (a flight) since the last pass: date-only deadlines keep their day, before anything syncs.
        try? await DayAnchor.settle(store, suite: Self.scratchStore == nil ? Identifiers.appGroup : Identifiers.bundlePrefix + ".scratch")
        // Read again each pass: access granted (or taken away) in Settings while the app was away shows at once.
        if reminders is EventKitReminderStore, let decided = Self.remindersAccess() { remindersAuthorized = decided }
        if remindersAuthorized == nil {
            // Asked for once there is something to write (HIG: ask in context), never over the empty first page.
            let items = (try? await store.obligations()) ?? [], queued = (try? await store.queuedDocuments()) ?? []
            if !items.isEmpty || !queued.isEmpty { await requestReminders() }
        }
        let route = readRoute
        Self.log("drain: reminders \(remindersAuthorized.map { "\($0)" } ?? "unknown"), route \(route == .claude ? "claude (\(claudeModel.rawValue), key of \(claudeKey.count) chars)" : "onDevice")")
        if let queued = try? await store.queuedDocuments(), !queued.isEmpty {   // nothing to read: no line saying so
            withAnimation { statusLine = route == .claude ? "Reading documents with Claude…" : "Reading documents on this device…" }
        }
        await coordinator.setClaude(claudeConfiguration)
        await coordinator.setRoute(route)
        let reports = await coordinator.drain()
        withAnimation { reading = nil }   // however the read ended, the live section must not outlive it
        if let id = cancelledDocument {
            cancelledDocument = nil
            try? await store.markDocument(id: id, status: .cancelled, failure: nil)   // the status says it
            cancelNotice = "Reading cancelled. Retry it from Documents."
            withAnimation { statusLine = cancelNotice }
            rerun = true   // finish the rest (and the Reminders sync) in a task that is not cancelled
            return
        }
        if Task.isCancelled {   // background time ran out: the checkpoint keeps what was read; the rest waits for the app, or a background task
            withAnimation { statusLine = "Reading paused. It goes on when Horizon is back." }
            return
        }
        if !reports.isEmpty { self.reports = reports + self.reports.prefix(20); cancelNotice = nil }   // failed reads stay visible from the store (RootView)
        if remindersAuthorized == true {   // not asked yet (nothing on file to write), or no access: no sync to run
            // Said only after a read: the sync that runs each time the app comes back is quiet, or the page would jump
            // for a line nobody asked for (a pull to refresh has the system's own spinner).
            if !reports.isEmpty { withAnimation { statusLine = "Syncing with Reminders…" } }
            do {
                let report = try await sync.sync()
                let read = !reports.isEmpty
                withAnimation {
                    lastError = nil
                    remindersListGone = report.listGone
                    // A pass that wrote nothing leaves the line alone, unless it put up "Syncing…" itself: the app's own
                    // writes to Reminders set off another pass a moment later, which once wiped the line it had just shown.
                    if report.created + report.updated > 0 { statusLine = "\(report.created) added, \(report.updated) updated in Reminders" }
                    else if read || cancelNotice != nil { statusLine = cancelNotice }
                }
            } catch {
                withAnimation { lastError = error.localizedDescription; statusLine = nil }
            }
        }
        // Whatever the sync's outcome (Reminders access off is a state the app supports): the bin still empties after
        // 30 days, old deletions are purged, and documents on file are named.
        _ = try? await store.purgeTombstones()
        try? await coordinator.expireBin()   // what has sat in Recently Deleted for 30 days goes for good
        await coordinator.nameUntitled()     // documents on file from before titles, a few at a time (the device model's small task)
    }

    // MARK: Looking at a document

    /// Whether the document's file is on this device (one read on another device is a record only).
    func hasFile(_ document: SourceDocument) -> Bool { storage.exists(sha256: document.sha256, extension: document.kind) }

    /// The document's file for Quick Look, copied under the name the app calls it (the stored file is named by its
    /// hash, and the preview's title is the file's name). One copy at a time: the last preview's goes.
    func previewFile(for document: SourceDocument) -> URL? {
        guard hasFile(document) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Preview", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = document.displayName.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let copy = folder.appendingPathComponent(name).appendingPathExtension(document.kind)
        do { try FileManager.default.copyItem(at: storage.url(sha256: document.sha256, extension: document.kind), to: copy); return copy }
        catch { Self.log("preview: could not copy \(document.filename): \(error.localizedDescription)"); return nil }
    }

    // MARK: Recently Deleted

    func deleteDocument(_ id: UUID) async {
        do { try await coordinator.deleteDocument(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // the reminders of what came from it go with it
    }

    func restoreDocument(_ id: UUID) async {
        do { try await coordinator.restoreDocument(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its items' reminders come back
    }

    func eraseDocument(_ id: UUID) async {
        do { try await coordinator.eraseDocument(id: id) } catch { lastError = error.localizedDescription }
    }

    func deleteCourse(_ id: UUID) async {
        do { try await coordinator.deleteCourse(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its items' reminders go with it
    }

    func restoreCourse(_ id: UUID) async {
        do { try await coordinator.restoreCourse(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its items' reminders come back
    }

    func eraseCourse(_ id: UUID) async {
        do { try await coordinator.eraseCourse(id: id) } catch { lastError = error.localizedDescription }
    }

    func retry(documentID: UUID) async {
        try? await store.markDocument(id: documentID, status: .queued)
        await drainAndSync()
    }

    /// The user's word: this document may be read by the device model instead of Claude (asked for, never assumed).
    func readOnDevice(documentID: UUID) async {
        try? await store.readOnDevice(id: documentID)
        await drainAndSync()
    }

    func confirm(_ id: UUID, edits: ObligationEdits = ObligationEdits()) async {
        do { try await store.confirm(id: id, edits: edits) } catch { lastError = error.localizedDescription }
        await drainAndSync()
    }

    /// An item checked off (or back on) in the app. Reminders owns completion, so the mark is written to its reminder
    /// by the sync that follows; nothing is read or drained, and no status line comes and goes for a check.
    func setCompleted(_ id: UUID, _ done: Bool) async {
        Self.log("check: \(id) \(done ? "done" : "not done")")   // every check is on the record: it reaches Reminders
        do { try await store.setCompleted(id: id, done) } catch { lastError = error.localizedDescription; return }
        guard remindersAuthorized == true else { return }   // the store keeps the mark; it reaches Reminders once there is access
        do { remindersListGone = try await sync.sync().listGone } catch { Self.log("sync after a check failed: \(error.localizedDescription)") }
    }

    /// An item skipped (set aside, not done) or taken back: closed or opened as a check does it, and synced as quietly.
    func setSkipped(_ id: UUID, _ skipped: Bool) async {
        Self.log("skip: \(id) \(skipped ? "skipped" : "taken back")")
        do { try await store.setSkipped(id: id, skipped) } catch { lastError = error.localizedDescription; return }
        guard remindersAuthorized == true else { return }
        do { remindersListGone = try await sync.sync().listGone } catch { Self.log("sync after a skip failed: \(error.localizedDescription)") }
    }

    /// The user's Recreate List: the Horizon list is made again and every item that was in it is written to it afresh,
    /// the checked ones checked. Only ever on the user's word: a list deleted wholesale is otherwise left deleted.
    func recreateRemindersList() async {
        Self.log("reminders: recreate the Horizon list")
        withAnimation { statusLine = "Recreating the Horizon list…" }
        do {
            let items = try await sync.restoreList()?.items ?? []
            let open = items.filter { !$0.isCompleted }.count   // what Reminders counts for the list; the checked ones are back too, checked
            Self.log("reminders: the Horizon list is back with \(open) to do and \(items.count - open) done")
            cancelNotice = open == 1 ? "The Horizon list is back with 1 item." : "The Horizon list is back with \(open) items."   // outlives the sync its writes set off
            withAnimation {
                lastError = nil
                remindersListGone = false
                statusLine = cancelNotice
            }
        } catch {
            withAnimation { lastError = error.localizedDescription; statusLine = nil }
        }
    }

    /// An item deleted by hand (a swipe, the Delete key, Review's Discard). Items do not wait in Recently Deleted, so
    /// the deletion is the window's to undo (Edit ▸ Undo, ⌘Z, or a shake on iOS) for as long as it is the last thing done.
    func discard(_ id: UUID) async { await discard([id]) }

    /// Items deleted together (a table's selection): one undo puts them all back.
    func discard(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            do { try await store.softDelete(id: id) } catch { lastError = error.localizedDescription; return }
        }
        registerUndo(restoring: ids)
        await drainAndSync()   // their reminders go with them
    }

    /// Undo puts the items back and, inside the undo itself, registers the redo that deletes them again. Registered any
    /// later (after an `await`), the redo would land on the undo stack as a new action: the next ⌘Z would delete them
    /// once more and Redo would never be offered.
    private func registerUndo(restoring ids: [UUID]) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {   // undo runs on the main thread
                model.registerUndo(deleting: ids)
                Task { await model.restore(ids) }
            }
        }
        undoManager?.setActionName(ids.count == 1 ? "Delete Item" : "Delete Items")
    }

    private func registerUndo(deleting ids: [UUID]) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerUndo(restoring: ids)
                Task { await model.deleteAgain(ids) }
            }
        }
        undoManager?.setActionName(ids.count == 1 ? "Delete Item" : "Delete Items")
    }

    /// Items deleted by hand, back (their reminders made again).
    private func restore(_ ids: [UUID]) async {
        for id in ids {
            do { try await store.undelete(id: id) } catch { lastError = error.localizedDescription }
        }
        await drainAndSync()
    }

    private func deleteAgain(_ ids: [UUID]) async {
        for id in ids {
            do { try await store.softDelete(id: id) } catch { lastError = error.localizedDescription }
        }
        await drainAndSync()
    }

    /// The window's undo manager (set by the root view): what Edit ▸ Undo and a shake reach.
    @ObservationIgnored weak var undoManager: UndoManager?

    /// One plan for the rest of today: calendar events are hard stops, the coming weeks' obligations fill the gaps, the
    /// user's instructions steer the model. Replaces the plan on file, edits and all.
    func planToday() async {
        guard !planning, storeFailure == nil else { return }   // a library that did not open has nothing to plan from
        expirePlanIfStale()
        planning = true
        planDraft = []
        let now = Date()
        let calendar = Calendar.current
        let day = PlanHours.day(of: now, calendar: calendar)   // after midnight, the night under way is still yesterday's
        let hours = planHours(for: day)
        var busy: [PlanBusy] = []
        var calendarOff = false
        do {
            // The day, and the night after it when the day runs past midnight.
            let reach = [PlanHours.moment(24, on: day, calendar: calendar), hours.closes(on: day, calendar: calendar)].compactMap { $0 }.max() ?? now
            if try await calendarSource.requestAccess() { busy = try await calendarSource.busy(in: DateInterval(start: day, end: max(day, reach))) } else { calendarOff = true }
        } catch { lastError = error.localizedDescription }
        let obligations = (try? await store.planObligations(from: now, days: 21)) ?? []   // three weeks out: enough to choose from
        let planner = DayPlanner(log: { message in Task { @MainActor in AppModel.log(message) } })
        let route: IngestOptions.RoutePolicy = planWithClaude && claudeConfiguration != nil ? .claude : .onDevice   // a small task: the device, unless asked
        let input = PlanInput(date: day, now: now, busy: busy, obligations: obligations, hours: hours, instructions: planInstructions)
        // Claude only when asked for: without the toggle the day's calendar and items never leave the device, and a device
        // without a model plans by the numbers (DECISIONS 2026-09-14).
        var result = await planner.plan(input, route: route, claude: planWithClaude ? claudeConfiguration : nil) { blocks in
            Task { @MainActor in self.showDraft(blocks) }   // the timetable grows as the model writes
        }
        if let close = hours.closes(on: day, calendar: calendar), now >= close, !result.blocks.contains(where: { $0.kind != .fixed }) {
            #if os(macOS)
            result.note = "The day ended at \(PlanHours.label(hours.end)). To keep going tonight, choose a later time beside the plan."   // Tonight Until sits in the column beside it
            #else
            result.note = "The day ended at \(PlanHours.label(hours.end)). To keep going tonight, choose a later time below."   // Tonight Until sits under the empty timetable
            #endif
        }
        if calendarOff { result.note = ([result.note, "Calendar access is off, so nothing on it counted as fixed."].compactMap { $0 }).joined(separator: " ") }
        let streamed = !planDraft.isEmpty
        if streamed {
            result.blocks = Self.keepingIdentities(result.blocks, from: planDraft)
            showDraft(result.blocks)                                  // the calendar's last events arrive the same way
            try? await Task.sleep(for: .milliseconds(700))            // and the rail reaches them before the page settles
        }
        plan = result; planEdited = false; planDay = day
        planCandidates = DayPlanner.ranked(input)
        planStreamed = streamed
        planning = false
        planDraft = []   // in the same turn as `planning`, so the rows hand over without a frame apart
        persistPlan()
        await syncActivity()
        if replanWhenDone { replanWhenDone = false; await planToday() }
    }

    /// A plan made for an intent or a control (`PlanDayIntent`, `PlanDayControlIntent`): `planToday`, its progress the
    /// blocks as they arrive, so a long-running intent shows it moving and is not taken for stalled; then the Live
    /// Activity brought in step before the intent returns.
    func planToday(reporting progress: Progress) async {
        progress.totalUnitCount = 100
        let ticker = Task { @MainActor [weak self] in   // the blocks as they arrive are the measure
            while !Task.isCancelled {
                progress.completedUnitCount = Int64(min(90, 10 + (self?.planDraft.count ?? 0) * 8))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        await planToday()
        ticker.cancel()
        progress.completedUnitCount = 100
        await syncActivity()
    }

    private func showDraft(_ blocks: [PlanBlock]) {
        guard planning else { return }
        planDraft = Self.keepingIdentities(blocks, from: planDraft)
    }

    /// The same block (same start, same title, at the same place) keeps its identity from one draft to the next, so
    /// a row on screen is the row that stays; a reply started over gets new rows.
    private static func keepingIdentities(_ blocks: [PlanBlock], from previous: [PlanBlock]) -> [PlanBlock] {
        var kept = blocks
        for i in kept.indices where i < previous.count && previous[i].start == kept[i].start && previous[i].title == kept[i].title {
            kept[i].id = previous[i].id
        }
        return kept
    }

    // MARK: Editing the plan

    /// A block changed by hand: put back in time order. Edits are the user's; Plan Again asks before replacing them.
    func updateBlock(_ block: PlanBlock) {
        guard var p = plan, let i = p.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        p.blocks[i] = block
        setEdited(p)
    }

    func addBlock(_ block: PlanBlock) {
        var p = plan ?? DayPlan(blocks: [])
        p.blocks.append(block)
        if planDay == nil { planDay = PlanHours.day(of: Date(), calendar: .current) }
        setEdited(p)
    }

    func deleteBlock(_ id: UUID) {
        guard var p = plan else { return }
        p.blocks.removeAll { $0.id == id }
        setEdited(p)
    }

    /// A block done (or not, after all), from the Now tab or the Live Activity's button (while it is on, or as the answer
    /// to "finished?"). Not an edit of the plan. Done and set aside exclude each other: marking one clears the other.
    /// `syncing`: bring the Live Activity in step in a task of its own; the intents pass false and await it themselves.
    func markBlock(_ id: UUID, done: Bool, syncing: Bool = true) {
        Self.log("plan: mark \(id) \(done ? "done" : "not done"); on file \(plan?.blocks.count ?? -1) blocks")
        guard var p = plan, let i = p.blocks.firstIndex(where: { $0.id == id }), p.blocks[i].isDone != done else { return }
        p.blocks[i].completedAt = done ? Date() : nil
        if done { p.blocks[i].skippedAt = nil }
        withAnimation { plan = p }
        persistPlan()
        if syncing { Task { await syncActivity() } }
    }

    /// A block set aside (or taken back), from the Now tab or the Live Activity: Skip before it ends, Not Yet as the
    /// answer to "finished?". The plan holds nobody to it; like done, it is not an edit of the plan.
    func skipBlock(_ id: UUID, skipped: Bool, syncing: Bool = true) {
        Self.log("plan: \(skipped ? "skip" : "unskip") \(id)")
        guard var p = plan, let i = p.blocks.firstIndex(where: { $0.id == id }), p.blocks[i].isSkipped != skipped else { return }
        p.blocks[i].skippedAt = skipped ? Date() : nil
        if skipped { p.blocks[i].completedAt = nil }
        withAnimation { plan = p }
        persistPlan()
        if syncing { Task { await syncActivity() } }
    }

    /// The block whose end is asking "finished?" now, for the timetable to ask it too.
    func blockAwaitingAnswer(at now: Date = Date()) -> PlanBlock? { plan?.awaitingAnswer(at: now) }

    // MARK: The day's hours

    /// The hours for `day`: the usual ones, with tonight's end when the user changed it for that night.
    func planHours(for day: Date) -> PlanHours {
        var hours = usualPlanHours
        if let tonight, tonight.day == day { hours.end = tonight.end }
        return hours
    }

    /// The end of the day a plan made now is for (Now's "Tonight until"). Setting it changes that night only; the next
    /// day starts from the usual end again. It does not plan: the caller plans again when there is a plan to redo.
    var tonightEnd: Int {
        get { planHours(for: PlanHours.day(of: Date(), calendar: .current)).end }
        set {
            let day = PlanHours.day(of: Date(), calendar: .current)
            tonight = newValue == usualPlanHours.end ? nil : Tonight(day: day, end: newValue)
        }
    }

    /// An end chosen for tonight while the plan on file has hand edits: it waits for the user's word to plan again.
    var pendingTonightEnd: Int?

    /// Tonight's end chosen (Now's pop-up, the Mac's Plan menu): the plan on file is made again up to it. True when that
    /// needs the user's word first because the plan was edited by hand; then the end waits (`pendingTonightEnd`).
    func chooseTonightEnd(_ end: Int) -> Bool {
        guard end != tonightEnd else { return false }
        if !planning, plan != nil, planEdited { pendingTonightEnd = end; return true }
        tonightEnd = end
        if planning { replanWhenDone = true }   // the plan under way was asked for with the old end: again once it lands
        else if plan != nil { Task { await planToday() } }
        return false
    }
    @ObservationIgnored private var replanWhenDone = false

    /// The user said yes to replacing an edited plan: the end chosen meanwhile, if any, applies, and the day is planned.
    func planAgain() {
        if let end = pendingTonightEnd { tonightEnd = end; pendingTonightEnd = nil }
        Task { await planToday() }
    }

    /// A block's hours from the editor's times of day, on the plan's day: after midnight is that night (`PlanHours.span`).
    func planSpan(from start: Date, to end: Date) -> DateInterval? {
        let calendar = Calendar.current
        let day = planDay ?? PlanHours.day(of: Date(), calendar: calendar)
        func clock(_ d: Date) -> (hour: Int, minute: Int) { (calendar.component(.hour, from: d), calendar.component(.minute, from: d)) }
        return PlanHours.span(from: clock(start), to: clock(end), on: day, calendar: calendar, now: Date())   // the repeated hour of a fall-back night: the one still to come
    }

    #if DEBUG
    /// `--demo-plan`: a plan around the present moment, to see the Live Activity through each phase without waiting on
    /// the planner: a work block on that ends two minutes from now (then asks "finished?"), a meal, and study later, in a
    /// study session from the calendar.
    func demoPlan(now: Date = Date()) {
        let at = { (minutes: Double) in now.addingTimeInterval(minutes * 60) }
        let blocks = [
            PlanBlock(start: at(-40), end: at(2), title: "Problem Set 4", reason: "Due Thursday; the longest of the week.", kind: .work),
            PlanBlock(start: at(4), end: at(34), title: "Lunch", reason: "Nothing good gets done hungry.", kind: .meal),
            PlanBlock(start: at(38), end: at(128), title: "Study for Midterm 1", reason: "Worth 20%, in six days: work through the practice exam.", kind: .study, within: "Lock in at library"),
        ]
        plan = DayPlan(blocks: blocks); planEdited = false; planDay = PlanHours.day(of: now, calendar: .current); planCandidates = []
        persistPlan()
        Task { await syncActivity() }
    }

    /// `--demo-plan-stream`: a plan arriving the way the planner's does (the working line, a block at a time, the hand
    /// over to the settled plan), long enough to scroll, and the same every time: the timetable's motion, to look at
    /// and to record, without a model. Nothing is kept: the plan on file before it comes back at the next launch.
    func demoPlanStream(now: Date = Date()) async {
        guard !planning else { return }
        let at = { (minutes: Double) in now.addingTimeInterval(minutes * 60) }
        let blocks = [
            PlanBlock(start: at(5), end: at(55), title: "Problem Set 4", reason: "Due Thursday; the longest of the week.", kind: .work),
            PlanBlock(start: at(60), end: at(90), title: "Lunch", reason: "Nothing good gets done hungry.", kind: .meal),
            PlanBlock(start: at(95), end: at(185), title: "Study for Midterm 1", reason: "Worth 20%, in six days: work through the practice exam.", kind: .study, within: "Lock in at library"),
            PlanBlock(start: at(190), end: at(200), title: "Walk", reason: "Ten minutes away from the desk.", kind: .rest),
            PlanBlock(start: at(205), end: at(265), title: "Lab Report 2", reason: "Due Monday; the data is in, the write-up is not.", kind: .work),
            PlanBlock(start: at(270), end: at(330), title: "Organizational Behavior", reason: "On your calendar.", kind: .fixed),
            PlanBlock(start: at(335), end: at(395), title: "Dinner", reason: "A real break before the evening.", kind: .meal),
            PlanBlock(start: at(400), end: at(460), title: "Reading for Unit 3", reason: "Two chapters before Tuesday's quiz.", kind: .work),
            PlanBlock(start: at(465), end: at(475), title: "Rest", reason: "Eyes off the screen.", kind: .rest),
            PlanBlock(start: at(480), end: at(540), title: "Study for Quiz 4", reason: "Worth 2.4%, on Friday: the practice set from section 7.3.", kind: .study),
            PlanBlock(start: at(545), end: at(575), title: "WebAssign 7.4", reason: "Due tonight at 11:59; short, and it keeps the streak.", kind: .work),
            PlanBlock(start: at(580), end: at(610), title: "Pack for tomorrow", reason: "The lab starts at eight.", kind: .rest),
        ]
        planning = true
        planDraft = []
        try? await Task.sleep(for: .seconds(2))   // reading the calendar and the coming weeks
        for n in 1...blocks.count {
            showDraft(Array(blocks.prefix(n)))
            try? await Task.sleep(for: .milliseconds(900))
        }
        try? await Task.sleep(for: .milliseconds(700))   // the rail reaches the last block before the page settles
        plan = DayPlan(blocks: Self.keepingIdentities(blocks, from: planDraft)); planEdited = false; planDay = PlanHours.day(of: now, calendar: .current)
        planCandidates = []
        planStreamed = true
        planning = false
        planDraft = []
    }
    #endif

    private func setEdited(_ p: DayPlan) {
        var p = p
        p.blocks.sort { $0.start < $1.start }
        withAnimation { plan = p; planEdited = true }
        persistPlan()
        Task { await syncActivity() }
    }

    /// The plan is the day's, night included, or nothing (`DayPlan.kept`): called when the app comes forward, when Now
    /// appears and on its minute's tick, in the activity's background refresh, and before an intent reads the plan.
    func expirePlanIfStale() {
        guard let planDay, Date() >= (plan?.kept(for: planDay, calendar: .current) ?? .distantPast) else { return }
        withAnimation { plan = nil; planEdited = false; planCandidates = [] }
        self.planDay = nil
        persistPlan()
        Task { await syncActivity() }
    }

    private func persistPlan() {
        let key = "dayPlan"
        guard let plan, let planDay, let data = try? JSONEncoder().encode(SavedPlan(day: planDay, plan: plan, candidates: planCandidates, edited: planEdited)) else {
            AppModel.defaults.removeObject(forKey: key); return
        }
        AppModel.defaults.set(data, forKey: key)
    }

    private func loadPlan() {
        guard let data = AppModel.defaults.data(forKey: "dayPlan"), let saved = try? JSONDecoder().decode(SavedPlan.self, from: data) else { return }
        guard Date() < saved.plan.kept(for: saved.day, calendar: .current) else { AppModel.defaults.removeObject(forKey: "dayPlan"); return }
        plan = saved.plan; planDay = saved.day; planCandidates = saved.candidates; planEdited = saved.edited
    }

    func reorderCourses(_ ids: [UUID]) async {
        do { try await store.reorderCourses(ids) } catch { lastError = error.localizedDescription }
    }

    func addCourse(_ edits: CourseEdits) async {
        do { _ = try await store.addCourse(edits) } catch { lastError = error.localizedDescription }
    }

    func updateCourse(_ id: UUID, edits: CourseEdits) async {
        do { try await store.updateCourse(id: id, edits: edits) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // reminder titles carry the course's name
    }

    func addManual(title: String, due: Date?, dueHasTime: Bool, courseID: UUID?, componentName: String?, platform: Platform = .syllabusOnly, notes: String?) async {
        do { _ = try await store.addManual(title: title, due: due, dueHasTime: dueHasTime, courseID: courseID, componentName: componentName, platform: platform, notes: notes, deviceName: Self.deviceName) }
        catch { lastError = error.localizedDescription }
        await drainAndSync()
    }
}

extension SourceDocument {
    /// Whether reading it again here could go differently: not for a file that cannot be opened, is empty or of a type
    /// the app does not read (`failureIsPermanent`), nor for a Word document on iOS (AppKit's converter reads it).
    var retryHelps: Bool {
        guard !failureIsPermanent else { return false }
        #if os(iOS)
        return kind != "docx"
        #else
        return true
        #endif
    }
}

/// Reminders for a scratch store (`AppModel.scratchStore`), or a library that did not open: never reached. Access reads as off and nothing can be
/// fetched or written, so no sync of a copy of someone's store can touch their lists.
struct NoReminders: ReminderStore {
    struct Off: LocalizedError { var errorDescription: String? { "Reminders is off for a scratch store." } }
    func requestAccess() async throws -> Bool { false }
    func fetchHorizonList() async throws -> HorizonList? { throw Off() }
    func ensureHorizonList() async throws { throw Off() }
    func create(_ draft: ReminderDraft) async throws -> ReminderItem { throw Off() }
    func update(externalID: String, with draft: ReminderDraft) async throws -> ReminderItem? { throw Off() }
    func setCompleted(externalID: String, _ completed: Bool, at date: Date?) async throws -> Bool { throw Off() }
    func remove(externalID: String) async throws { throw Off() }
}
