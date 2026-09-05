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

    struct Reading: Equatable {
        var filename: String
        var chunk = 0
        var chunks = 0
        var images = 0
        var found: [ProvisionalObligation] = []      // finished chunks
        var current: [ProvisionalObligation] = []    // the chunk being written now
        var items: [ProvisionalObligation] { found + current }
    }

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
            reading = Reading(filename: p.filename, chunks: chunks, images: images)   // the user's name for it, not the stored hash
        case .chunkStarted(let index):
            reading?.chunk = index + 1
            reading?.current = []
        case .partial(_, let items):
            reading?.current = items
        case .chunkFinished:
            if let current = reading?.current { reading?.found += current; reading?.current = [] }
        case .finished:
            reading = nil
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
    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { _ = try await coordinator.enqueue(fileURL: url) } catch { lastError = error.localizedDescription }
        }
        await drainAndSync()
    }

    /// Parse whatever is queued, then reconcile with Reminders and write what is ready. Safe to run repeatedly; a call
    /// that arrives during a run makes it run once more afterwards.
    func drainAndSync() async {
        guard !busy else { rerun = true; return }
        busy = true
        defer { busy = false }
        repeat {
            rerun = false
            Self.log("drain: reminders \(remindersAuthorized.map { "\($0)" } ?? "unknown")")
            if remindersAuthorized == nil { await requestReminders() }
            statusLine = "Reading documents…"
            let reports = await coordinator.drain()
            if !reports.isEmpty { self.reports = reports + self.reports.prefix(20) }
            statusLine = "Syncing with Reminders…"
            do {
                let report = try await sync.sync()
                lastError = nil
                statusLine = report.created + report.updated > 0 ? "\(report.created) added, \(report.updated) updated in Reminders" : nil
                try? await store.purgeTombstones()
            } catch {
                lastError = error.localizedDescription
                statusLine = nil
            }
        } while rerun
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
    }

    func addManual(title: String, due: Date?, dueHasTime: Bool, courseID: UUID?, componentName: String?, notes: String?) async {
        do { _ = try await store.addManual(title: title, due: due, dueHasTime: dueHasTime, courseID: courseID, componentName: componentName, notes: notes, deviceName: Self.deviceName) }
        catch { lastError = error.localizedDescription }
        await drainAndSync()
    }
}
