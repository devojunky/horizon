import SwiftUI
import SwiftData
import AppIntents
import EventKit
import HorizonCore
import IngestKit
import os
#if os(iOS)
import BackgroundTasks
#endif

@main
struct HorizonApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        var failure: String?
        // A library staged for import replaces this one before anything opens it (`LibraryTransfer`).
        let imported = AppModel.applyPendingImport()
        do { container = try AppModel.scratchStore.map { try HorizonContainer.at($0.appendingPathComponent("Horizon.store")) } ?? HorizonContainer.shared() }
        catch {
            // The library would not open (a newer build's store, a failed migration, a full disk). The app says so and
            // does nothing else: an empty in-memory store that still read and synced would look like data lost, and
            // its reminders would be orphans at the next launch.
            Logger(subsystem: Identifiers.bundlePrefix, category: "store").error("shared store failed: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
            container = try! HorizonContainer.inMemory()
        }
        let model = AppModel(container: container, storeFailure: failure)
        model.importedLibrary = imported
        // The intents' way to the model (`@Dependency`), in place before any can run: one launched for an intent runs
        // this init and no scene.
        AppDependencyManager.shared.add(dependency: model)
        #if DEBUG
        // `--claude-key <key>` stores a key and reads with Claude, to exercise the route and its failures without typing;
        // `--read-on-device` / `--read-with-claude` set the route. Set here, before the first drain can read the route.
        if let i = CommandLine.arguments.firstIndex(of: "--claude-key"), i + 1 < CommandLine.arguments.count {
            model.claudeKey = CommandLine.arguments[i + 1]; model.readingRoute = .claude
        }
        if CommandLine.arguments.contains("--read-on-device") { model.readingRoute = .onDevice }
        if CommandLine.arguments.contains("--read-with-claude") { model.readingRoute = .claude }
        // `--read-through-horizon`: Claude through Horizon's reading service, where it is offered (a device with App Attest).
        if CommandLine.arguments.contains("--read-through-horizon") { model.claudeAccess = .service; model.readingRoute = .claude }
        #endif
        _model = State(initialValue: model)
        #if DEBUG
        // `--appearance-late`: the bars made before the serif is installed, as on the owner's iPhone, to see that
        // becoming active puts it right.
        if !CommandLine.arguments.contains("--appearance-late") { Design.installAppearance() }
        #else
        Design.installAppearance()
        #endif
        #if os(iOS)
        BackgroundIngest.register(model: model)
        ActivityRefresh.register(model: model)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let failure = model.storeFailure { StoreFailure(reason: failure) } else { MainTabs() }
            }
                .modifier(UndoHookup(model: model))
                .environment(model)
                .modelContainer(model.container)
                .defaultAppStorage(AppModel.defaults)
                .tint(Design.accentInk)
                .onOpenURL { url in Task { await model.open(url) } }
                .task {
                    #if DEBUG
                    let shown = CommandLine.arguments.dropFirst().enumerated().map { i, a in i > 0 && CommandLine.arguments[i] == "--claude-key" ? "<key>" : a }
                    print("horizon: launch task, arguments \(shown.joined(separator: " "))")   // never the key itself
                    // `xcrun simctl launch booted com.daniel.horizon --ingest-sample` drives the sample read without a tap.
                    if CommandLine.arguments.contains("--ingest-sample"), let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") {
                        await model.importFiles([sample]); return
                    }
                    if CommandLine.arguments.contains("--demo-reading") { model.demoReading(); return }   // the reading section at its widest; nothing is read
                    // `--probe-reading-service` [`--forget-reading-service-key`]: Test Connection through Horizon's reading service
                    // without a tap (attesting a key first when there is none, or a new one with the second flag), its
                    // answer printed: on a phone, `devicectl device process launch --console` shows it. Nothing is read.
                    if CommandLine.arguments.contains("--probe-reading-service") {
                        guard let service = AppModel.readingService else { print("horizon: reading service: not offered on this device"); return }
                        if CommandLine.arguments.contains("--forget-reading-service-key") { await service.renew() }
                        do { print("horizon: reading service: \(try await Ingestor.probe(claude: ClaudeConfiguration(service: service)))") }
                        catch { print("horizon: reading service: \(error.localizedDescription)") }
                        fflush(stdout)   // a Mac's `open --stdout` file is block-buffered; devicectl's console is not
                        return
                    }
                    if CommandLine.arguments.contains("--probe-app-attest") {   // `DeviceAttester.probe`: App Attest here, and its evidence's environment
                        print("horizon: app attest: \(await DeviceAttester.probe())")
                        fflush(stdout)
                    }
                    // `--probe-eventkit`: whether this build reaches EventKit (a Mac's sandbox and hardened runtime let it in
                    // through the calendars entitlement, Reminders and Calendar alike): each one's access and how many lists
                    // or calendars it shows, printed. Nothing is asked for, and nothing in them is read.
                    if CommandLine.arguments.contains("--probe-eventkit") {
                        let events = EKEventStore()
                        for (name, type) in [("reminders", EKEntityType.reminder), ("calendar", EKEntityType.event)] {
                            let access = switch EKEventStore.authorizationStatus(for: type) {
                                case .fullAccess: "full access"
                                case .writeOnly: "write only"
                                case .denied: "denied"
                                case .restricted: "restricted"
                                case .notDetermined: "not asked"
                                @unknown default: "unknown"
                            }
                            print("horizon: eventkit: \(name) \(access), \(events.calendars(for: type).count) lists")
                        }
                        fflush(stdout)
                    }
                    // `--ingest-file <path>` reads any file the simulator can see: unreadable ones, duplicates, and so on (a
                    // Mac Debug build's sandbox reaches one under /private/tmp only).
                    if let i = CommandLine.arguments.firstIndex(of: "--ingest-file"), i + 1 < CommandLine.arguments.count {
                        await model.importFiles([URL(fileURLWithPath: CommandLine.arguments[i + 1])]); return
                    }
                    #endif
                    await Task { await model.drainAndSync() }.value   // the app's, not the window's: closing a Mac's window must not pause the read
                    #if DEBUG
                    // `--read-first-waiting-on-device`: the confirmation's outcome without a tap (a document waiting for Claude is read on the device).
                    if CommandLine.arguments.contains("--read-first-waiting-on-device"),
                       let waiting = try? await model.store.documents().first(where: { $0.status == .awaitingCloudParse }) {
                        await model.readOnDevice(documentID: waiting.id)
                    }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await model.drainAndSync() } }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await model.drainAndSync() } }   // date-only deadlines keep their day (`DayAnchor`)
                #if os(macOS)
                .task {
                    guard model.storeFailure == nil else { return }
                    WatchedFolder.shared.start(model: model)
                    #if DEBUG
                    // `--inbox <dir>`: choose this folder as Settings' Choose… does, what it holds now left alone (a Debug
                    // build's sandbox reaches it under /private/tmp only).
                    if let i = CommandLine.arguments.firstIndex(of: "--inbox"), i + 1 < CommandLine.arguments.count {
                        await WatchedFolder.shared.choose(URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true))
                    }
                    #endif
                }
                #if DEBUG
                .task { await WindowSnapshot.writeIfAsked() }
                #endif
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
            #if os(iOS)
            if phase == .active { Design.installAppearance() }   // bars made before it was installed take the serif too
            if phase == .background { model.appEnteredBackground() }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 800)
        .commands {
            SidebarCommands()   // View ▸ Show/Hide Sidebar (⌃⌘S): HIG, a sidebar can be hidden from the View menu too
            ToolbarCommands()   // View ▸ Hide Toolbar, Customize Toolbar…
            HorizonCommands(model: model)
        }
        #endif
        #if os(macOS)
        Settings {   // ⌘, — its own window, the way a Mac keeps its settings
            MacSettingsView().environment(model).modelContainer(model.container).defaultAppStorage(AppModel.defaults).tint(Design.accentInk)
        }
        #endif
    }
}

/// Hands the window's undo manager to the model, so an item deleted anywhere can be put back with Edit ▸ Undo or a shake.
struct UndoHookup: ViewModifier {
    let model: AppModel
    @Environment(\.undoManager) private var undoManager
    func body(content: Content) -> some View {
        content
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }
}

/// The library could not be opened: said plainly, with nothing else on offer, since nothing else would work.
struct StoreFailure: View {
    let reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorialEmpty(title: "Horizon could not open its library.",
                           deck: "Nothing in it was changed, and nothing goes to Reminders until it opens. Quit Horizon and open it again; if this keeps happening, update the app.") { EmptyView() }
            Text(reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.margin)
        .padding(.top, 40)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.paper.ignoresSafeArea())
    }
}

#if os(iOS)
/// Drains the inbox when iOS gives the app background time, so a document shared at night is in Reminders by morning,
/// and a read paused when the user left goes on from its checkpoint.
enum BackgroundIngest {
    /// The launch handler runs on the main queue (`using: .main`): it is written on the main actor, and Swift checks that
    /// it runs there, so on the default background queue the first background launch would stop the app. The expiration
    /// handler is the system's to call from anywhere: it only cancels and reports, which may happen on any thread.
    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Identifiers.backgroundIngestTask, using: .main) { task in
            let work = Task { @MainActor in
                await model.drainAndSync()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            nonisolated(unsafe) let task = task   // BGTask's completion may be reported from any thread
            task.expirationHandler = { @Sendable in
                work.cancel()   // reaches the read under way: the part being read is lost, the checkpoint keeps the rest, the document stays queued
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// `needsNetwork`: a read with Claude is only worth starting with the network there. Submitted off the main thread,
    /// as the SDK asks.
    static func schedule(needsNetwork: Bool) {
        Task.detached {
            let request = BGProcessingTaskRequest(identifier: Identifiers.backgroundIngestTask)
            request.requiresNetworkConnectivity = needsNetwork
            request.requiresExternalPower = false
            BGTaskScheduler.shared.submitTaskRequest(request) { error in   // submission is asynchronous now; a refusal is worth a log line
                if let error { Logger(subsystem: Identifiers.bundlePrefix, category: "ingest").error("background ingest not scheduled: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
}

/// Brings the plan's Live Activity in step at the moment it next changes by itself (a block over and asking, a question
/// timed out, the day's plan over), so that it moves on, or ends, while the app is not running. iOS runs a refresh when
/// it chooses, never before the date asked: the activity's own views cover that moment (`ContentState.phase(at:)`),
/// and the refresh covers what comes after it. Each sync of the activity books the next one; a submission replaces the
/// one before.
enum ActivityRefresh {
    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Identifiers.activityRefreshTask, using: .main) { task in   // on the main queue: see `BackgroundIngest.register`
            let work = Task { @MainActor in
                model.expirePlanIfStale()     // a plan from another day goes, and its activity with it
                await model.syncActivity()
                task.setTaskCompleted(success: true)
            }
            nonisolated(unsafe) let task = task
            task.expirationHandler = { @Sendable in
                work.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Nil: nothing will change by itself, and no refresh is wanted. The same moment asked for again (Now's minute tick)
    /// books nothing; a new one replaces the last, submitted off the main thread as the SDK asks.
    @MainActor static func schedule(at date: Date?) {
        guard !hasBooked || date != booked else { return }
        hasBooked = true; booked = date
        Task.detached {
            guard let date else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Identifiers.activityRefreshTask); return }
            let request = BGAppRefreshTaskRequest(identifier: Identifiers.activityRefreshTask)
            request.earliestBeginDate = date.addingTimeInterval(5)
            BGTaskScheduler.shared.submitTaskRequest(request) { error in
                if let error { Logger(subsystem: Identifiers.bundlePrefix, category: "activity").error("activity refresh not scheduled: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
    @MainActor private static var booked: Date?
    @MainActor private static var hasBooked = false
}
#endif
