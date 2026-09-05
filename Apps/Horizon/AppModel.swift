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
    private let reminders = EventKitReminderStore()

    var remindersAuthorized: Bool?
    var busy = false
    private var rerun = false
    var statusLine: String?
    var lastError: String?
    var reports: [IngestCoordinator.Report] = []
    /// Set by a `horizon://obligation/<id>` link (the provenance link on every reminder); RootView opens it.
    var linkedObligationID: UUID?
    /// What the parser is reading right now, item by item as the model streams. Nil when idle.
    var reading: Reading?
    /// Read documents in Private Cloud Compute instead of on device (slow and hot on a phone). Persisted; needs the
    /// PCC entitlement in the app's signature, which `cloudUnavailableReason` reports when missing.
    var readInCloud: Bool = UserDefaults.standard.bool(forKey: "readInCloud") {
        didSet { UserDefaults.standard.set(readInCloud, forKey: "readInCloud") }
    }
    let cloudUnavailableReason: String? = Ingestor.cloudAvailability()

    struct Reading: Equatable {
        var documentID: UUID
        var filename: String
        var chunk = 0
        var chunks = 0
        var images = 0
        var found: [ProvisionalObligation] = []      // finished chunks
        var current: [ProvisionalObligation] = []    // the chunk being written now
        var items: [ProvisionalObligation] { found + current }
        /// Never moves backwards: parts finished plus how far the current part has streamed (about a dozen rows per
        /// part). A part split in two reports the same index twice, so finishing counts half, and the next part's start 1.
        var fraction: Double = 0
        mutating func advance(to value: Double) { fraction = min(1, max(fraction, value)) }
        var total: Double { Double(max(chunks + images, 1)) }
    }
    /// Today's plan (SPEC §6.3). Never stored: it lives as long as the app does.
    var plan: DayPlan?
    var planning = false
    private let calendarSource: any CalendarSource = EventKitCalendarSource()
    private var drainTask: Task<Void, Never>?
    private var cancelledDocument: UUID?
    private var cancelNotice: String?   // shown until the next document is read

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
        coordinator = IngestCoordinator(store: store, storage: DocumentStorage.appGroup() ?? .temporary(), sync: sync, options: options, deviceName: Self.deviceName,
                                        progress: { p in Task { @MainActor in box.model?.apply(p) } })
        box.model = self
    }

    /// Breaks the init cycle between the coordinator's sink and self.
    private final class ProgressBox: @unchecked Sendable { weak var model: AppModel? }

    private func apply(_ p: DocumentProgress) {
        switch p.event {
        case .started(_, let chunks, let images):
            withAnimation { reading = Reading(documentID: p.documentID, filename: p.filename, chunks: chunks, images: images) }   // the user's name for it, not the stored hash
        case .chunkStarted(let index):
            guard var r = reading else { return }   // copy, mutate, write back: no overlapping access to `reading`
            r.chunk = index + 1; r.current = []; r.advance(to: Double(index) / r.total)
            reading = r
        case .partial(_, let items):
            guard var r = reading else { return }
            r.current = items; r.advance(to: (Double(r.chunk - 1) + min(0.9, Double(items.count) / 12)) / r.total)
            reading = r
        case .chunkFinished:
            guard var r = reading else { return }
            r.found += r.current; r.current = []; r.advance(to: (Double(r.chunk - 1) + 0.5) / r.total)   // a split part may follow under the same index
            reading = r
        case .finished:
            withAnimation { reading = nil }
        }
    }

    private static let logger = Logger(subsystem: Identifiers.bundlePrefix, category: "ingest")
    private static func log(_ message: String) { logger.notice("\(message, privacy: .public)") }

    func requestReminders() async {
        do { remindersAuthorized = try await reminders.requestAccess() } catch { remindersAuthorized = false; lastError = error.localizedDescription }
    }

    /// A `horizon://obligation/<id>` link opens that item; anything else is a file to ingest.
    func open(_ url: URL) async {
        if let id = Identifiers.obligationID(from: url) { linkedObligationID = id; return }
        guard url.isFileURL else { lastError = "Horizon cannot open \(url.absoluteString)"; return }
        await importFiles([url])
    }

    /// Files picked in the app or handed over by the system. Security-scoped URLs are opened for the copy only.
    /// `courseID` files the documents under a course before they are read (the course page's Add Document).
    func importFiles(_ urls: [URL], courseID: UUID? = nil) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { _ = try await coordinator.enqueue(fileURL: url, courseID: courseID) } catch { lastError = error.localizedDescription }
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
        guard !busy else { rerun = true; return }
        busy = true
        defer { busy = false }
        repeat {
            rerun = false
            let task = Task { await self.drainOnce() }   // held so that Cancel can reach the read in progress
            drainTask = task
            await task.value
            drainTask = nil
        } while rerun
    }

    /// Stops the document being read. It is marked cancelled (Documents offers Retry) and whatever else is queued
    /// is read on the next pass.
    func cancelReading() {
        cancelledDocument = reading?.documentID
        drainTask?.cancel()
    }

    private func drainOnce() async {
        Self.log("drain: reminders \(remindersAuthorized.map { "\($0)" } ?? "unknown")")
        if remindersAuthorized == nil { await requestReminders() }
        let cloud = readInCloud && cloudUnavailableReason == nil   // the setting only counts where the cloud can be used
        withAnimation { statusLine = cloud ? "Reading documents in Private Cloud Compute…" : "Reading documents…" }
        await coordinator.setRoute(cloud ? .privateCloudCompute : .onDeviceFirst)
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
        if !reports.isEmpty { self.reports = reports + self.reports.prefix(20); cancelNotice = nil }
            withAnimation { statusLine = "Syncing with Reminders…" }
            do {
                let report = try await sync.sync()
                lastError = nil
                withAnimation { statusLine = report.created + report.updated > 0 ? "\(report.created) added, \(report.updated) updated in Reminders" : cancelNotice }
                try? await store.purgeTombstones()
            } catch {
                withAnimation { lastError = error.localizedDescription; statusLine = nil }
            }
    }

    func retry(documentID: UUID) async {
        try? await store.markDocument(id: documentID, status: .queued)
        await drainAndSync()
    }

    func confirm(_ id: UUID, edits: ObligationEdits = ObligationEdits()) async {
        do { try await store.confirm(id: id, edits: edits) } catch { lastError = error.localizedDescription }
        await drainAndSync()
    }

    func discard(_ id: UUID) async {
        do { try await store.softDelete(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its reminder goes with it
    }

    /// One plan for the rest of today: calendar events are hard stops, the coming week's obligations fill the gaps.
    func planToday() async {
        guard !planning else { return }
        planning = true
        defer { planning = false }
        let now = Date()
        var busy: [PlanBusy] = []
        do {
            if try await calendarSource.requestAccess() { busy = try await calendarSource.busy(on: now, calendar: .current) }
        } catch { lastError = error.localizedDescription }
        let obligations = (try? await store.planObligations(from: now, days: 21)) ?? []   // three weeks out: enough to choose from
        let planner = DayPlanner(log: { message in Task { @MainActor in AppModel.log(message) } })
        let route: IngestOptions.RoutePolicy = readInCloud && cloudUnavailableReason == nil ? .privateCloudCompute : .onDeviceFirst
        let result = await planner.plan(PlanInput(date: now, now: now, busy: busy, obligations: obligations), route: route)
        withAnimation { plan = result }
    }

    func deleteCourse(_ id: UUID) async {
        do { try await store.deleteCourse(id: id) } catch { lastError = error.localizedDescription }
        await drainAndSync()   // its items' reminders go with it
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
