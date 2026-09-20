import SwiftUI
import SwiftData
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
    private let reminders = EventKitReminderStore()

    var remindersAuthorized: Bool?
    var busy = false
    private var rerun = false
    var statusLine: String?
    var lastError: String?
    var reports: [IngestCoordinator.Report] = []
    /// Set by a `horizon://obligation/<id>` link (the provenance link on every reminder); RootView opens it.
    var linkedObligationID: UUID?
    /// Set by a `horizon://now` link (a tap on the plan's Live Activity); the tabs open Now.
    var openNowRequested = false
    /// What the parser is reading right now, item by item as the model streams. Nil when idle.
    var reading: Reading?
    /// Where documents are read: Claude (the target model, with the user's own key) or the device's own model (nothing
    /// leaves the phone; no eye for tables or pictures). Persisted. A key entered turns Claude on; a key removed turns
    /// it off.
    enum ReadingRoute: String, CaseIterable { case claude, onDevice }
    var readingRoute: ReadingRoute = ReadingRoute(rawValue: UserDefaults.standard.string(forKey: "readingRoute") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(readingRoute.rawValue, forKey: "readingRoute") }
    }
    /// Which Claude. Persisted.
    var claudeModel: ClaudeModelChoice = ClaudeModelChoice(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(claudeModel.rawValue, forKey: "claudeModel") }
    }
    /// The user's own key, in the Keychain and nowhere else.
    var claudeKey: String = Keychain.read("claude") ?? "" {
        didSet { Keychain.write(claudeKey, account: "claude") }
    }
    /// The day plan is a small task: the device model makes it unless the user asks for Claude. Persisted.
    var planWithClaude: Bool = UserDefaults.standard.bool(forKey: "planWithClaude") {
        didSet { UserDefaults.standard.set(planWithClaude, forKey: "planWithClaude") }
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
    /// Today's plan (SPEC §6.3), with the user's edits. Kept for the day, so a relaunch does not lose an edited plan;
    /// discarded once the day ends. Tomorrow starts from nothing.
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
    var planInstructions: String = UserDefaults.standard.string(forKey: "planInstructions") ?? "" {
        didSet { UserDefaults.standard.set(planInstructions, forKey: "planInstructions") }
    }
    private struct SavedPlan: Codable { var day: Date; var plan: DayPlan; var candidates: [PlanObligation]; var edited: Bool }
    #if os(iOS)
    /// The plan's Live Activity (the Lock Screen and the Dynamic Island); its Done button comes back through `PlanCommands`.
    private let activities = PlanActivityController()
    #endif
    private let calendarSource: any CalendarSource = EventKitCalendarSource()
    private var drainTask: Task<Void, Never>?
    private var cancelledDocument: UUID?
    private var cancelNotice: String?   // shown until the next document is read
    #if os(iOS)
    /// iOS keeps the app running for a while after the user leaves, as long as it asks: every drain asks, so a read
    /// under way goes on in the background. When that time runs out the read is paused, not cancelled: the checkpoint
    /// keeps every part read so far, and the read goes on the moment the app is back, or in a background task.
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    private var paused = false   // background time ran out mid-read; nothing restarts until the app is active again
    #endif

    static let deviceName: String = {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }()

    init(container: ModelContainer) {
        self.container = container
        store = HorizonStore(modelContainer: container)
        sync = SyncCoordinator(store: store, reminders: reminders, seen: DefaultsSeenIDs(), deviceName: Self.deviceName)
        var options = IngestOptions()
        options.log = { message in Task { @MainActor in AppModel.log(message) } }
        let box = ProgressBox()
        storage = DocumentStorage.appGroup() ?? .temporary()
        coordinator = IngestCoordinator(store: store, storage: storage, sync: sync, options: options, deviceName: Self.deviceName,
                                        progress: { p in Task { @MainActor in box.model?.apply(p) } })
        box.model = self
        loadPlan()
        #if os(iOS)
        activities.adopt()
        PlanCommands.markDone = { [weak self] id in await self?.markBlock(id, done: true) }
        PlanCommands.log = { Self.log($0) }
        Task { await syncActivity() }
        #endif
    }

    /// The Live Activity follows the plan on file. Called after every change to the plan and every minute while Now is open.
    func syncActivity() async {
        #if os(iOS)
        await activities.sync(plan: plan, day: planDay)
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
    private static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
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

    /// A `horizon://obligation/<id>` link opens that item; anything else is a file to ingest.
    func open(_ url: URL) async {
        if let id = Identifiers.obligationID(from: url) { linkedObligationID = id; return }
        if url.scheme == "horizon", url.host == "now" { openNowRequested = true; return }
        guard url.isFileURL else { lastError = "Horizon cannot open \(url.absoluteString)"; return }
        await importFiles([url])
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
            cancelNotice = onFile.count == 1 ? "\(onFile[0]) is already on file." : "\(onFile.count) of those documents are already on file."
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
        #if DEBUG
        if demoing { return }
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

    private func drainOnce() async {
        if remindersAuthorized == nil { await requestReminders() }
        let route = readRoute
        Self.log("drain: reminders \(remindersAuthorized.map { "\($0)" } ?? "unknown"), route \(route == .claude ? "claude (\(claudeModel.rawValue), key of \(claudeKey.count) chars)" : "onDevice")")
        withAnimation { statusLine = route == .claude ? "Reading documents with Claude…" : "Reading documents on this device…" }
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
        withAnimation { statusLine = "Syncing with Reminders…" }
        do {
            let report = try await sync.sync()
            withAnimation {
                lastError = nil
                statusLine = report.created + report.updated > 0 ? "\(report.created) added, \(report.updated) updated in Reminders" : cancelNotice
            }
            _ = try? await store.purgeTombstones()
            try? await coordinator.expireBin()   // what has sat in Recently Deleted for 30 days goes for good
            await coordinator.nameUntitled()     // documents on file from before titles, a few at a time (the device model's small task)
        } catch {
            withAnimation { lastError = error.localizedDescription; statusLine = nil }
        }
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
        do { try await store.setCompleted(id: id, done) } catch { lastError = error.localizedDescription; return }
        guard remindersAuthorized == true else { return }   // the store keeps the mark; it reaches Reminders once there is access
        do { _ = try await sync.sync() } catch { Self.log("sync after a check failed: \(error.localizedDescription)") }
    }

    func discard(_ id: UUID) async {
        do { try await store.softDelete(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its reminder goes with it
    }

    /// One plan for the rest of today: calendar events are hard stops, the coming weeks' obligations fill the gaps, the
    /// user's instructions steer the model. Replaces the plan on file, edits and all.
    func planToday() async {
        guard !planning else { return }
        planning = true
        planDraft = []
        let now = Date()
        var busy: [PlanBusy] = []
        var calendarOff = false
        do {
            if try await calendarSource.requestAccess() { busy = try await calendarSource.busy(on: now, calendar: .current) } else { calendarOff = true }
        } catch { lastError = error.localizedDescription }
        let obligations = (try? await store.planObligations(from: now, days: 21)) ?? []   // three weeks out: enough to choose from
        let planner = DayPlanner(log: { message in Task { @MainActor in AppModel.log(message) } })
        let route: IngestOptions.RoutePolicy = planWithClaude && claudeConfiguration != nil ? .claude : .onDevice   // a small task: the device, unless asked
        let input = PlanInput(date: now, now: now, busy: busy, obligations: obligations, instructions: planInstructions)
        var result = await planner.plan(input, route: route, claude: claudeConfiguration) { blocks in
            Task { @MainActor in self.showDraft(blocks) }   // the timetable grows as the model writes
        }
        if calendarOff { result.note = ([result.note, "Calendar access is off, so nothing on it counted as fixed."].compactMap { $0 }).joined(separator: " ") }
        let streamed = !planDraft.isEmpty
        if streamed {
            result.blocks = Self.keepingIdentities(result.blocks, from: planDraft)
            showDraft(result.blocks)                                  // the calendar's last events arrive the same way
            try? await Task.sleep(for: .milliseconds(700))            // and the rail reaches them before the page settles
        }
        plan = result; planEdited = false; planDay = Calendar.current.startOfDay(for: now)
        planCandidates = DayPlanner.ranked(input)
        planStreamed = streamed
        planning = false
        planDraft = []   // in the same turn as `planning`, so the rows hand over without a frame apart
        persistPlan()
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
        if planDay == nil { planDay = Calendar.current.startOfDay(for: Date()) }
        setEdited(p)
    }

    func deleteBlock(_ id: UUID) {
        guard var p = plan else { return }
        p.blocks.removeAll { $0.id == id }
        setEdited(p)
    }

    /// A block done (or not, after all), from the Now tab or the Live Activity's button. Not an edit of the plan.
    func markBlock(_ id: UUID, done: Bool) {
        Self.log("plan: mark \(id) \(done ? "done" : "not done"); on file \(plan?.blocks.count ?? -1) blocks")
        guard var p = plan, let i = p.blocks.firstIndex(where: { $0.id == id }), p.blocks[i].isDone != done else { return }
        p.blocks[i].completedAt = done ? Date() : nil
        withAnimation { plan = p }
        persistPlan()
        Task { await syncActivity() }
    }

    private func setEdited(_ p: DayPlan) {
        var p = p
        p.blocks.sort { $0.start < $1.start }
        withAnimation { plan = p; planEdited = true }
        persistPlan()
        Task { await syncActivity() }
    }

    /// The plan is today's or nothing: called when the app comes forward and when Now appears.
    func expirePlanIfStale() {
        guard let planDay, planDay != Calendar.current.startOfDay(for: Date()) else { return }
        withAnimation { plan = nil; planEdited = false; planCandidates = [] }
        self.planDay = nil
        persistPlan()
        Task { await syncActivity() }
    }

    private func persistPlan() {
        let key = "dayPlan"
        guard let plan, let planDay, let data = try? JSONEncoder().encode(SavedPlan(day: planDay, plan: plan, candidates: planCandidates, edited: planEdited)) else {
            UserDefaults.standard.removeObject(forKey: key); return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadPlan() {
        guard let data = UserDefaults.standard.data(forKey: "dayPlan"), let saved = try? JSONDecoder().decode(SavedPlan.self, from: data) else { return }
        guard saved.day == Calendar.current.startOfDay(for: Date()) else { UserDefaults.standard.removeObject(forKey: "dayPlan"); return }
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

    func addManual(title: String, due: Date?, dueHasTime: Bool, courseID: UUID?, componentName: String?, notes: String?) async {
        do { _ = try await store.addManual(title: title, due: due, dueHasTime: dueHasTime, courseID: courseID, componentName: componentName, notes: notes, deviceName: Self.deviceName) }
        catch { lastError = error.localizedDescription }
        await drainAndSync()
    }
}
