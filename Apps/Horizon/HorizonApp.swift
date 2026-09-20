import SwiftUI
import SwiftData
import HorizonCore
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
        do { container = try HorizonContainer.shared() }
        catch {
            // Only a misconfigured build gets here; stay usable (nothing persists) and say so in the log.
            Logger(subsystem: Identifiers.bundlePrefix, category: "store").error("shared store failed: \(error.localizedDescription, privacy: .public); using an in-memory store")
            container = try! HorizonContainer.inMemory()
        }
        let model = AppModel(container: container)
        #if DEBUG
        // `--claude-key <key>` stores a key and reads with Claude, to exercise the route and its failures without typing;
        // `--read-on-device` / `--read-with-claude` set the route. Set here, before the first drain can read the route.
        if let i = CommandLine.arguments.firstIndex(of: "--claude-key"), i + 1 < CommandLine.arguments.count {
            model.claudeKey = CommandLine.arguments[i + 1]; model.readingRoute = .claude
        }
        if CommandLine.arguments.contains("--read-on-device") { model.readingRoute = .onDevice }
        if CommandLine.arguments.contains("--read-with-claude") { model.readingRoute = .claude }
        #endif
        _model = State(initialValue: model)
        Design.installAppearance()
        #if os(iOS)
        BackgroundIngest.register(model: model)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MainTabs()
                .environment(model)
                .modelContainer(model.container)
                .tint(Design.accent)
                .onOpenURL { url in Task { await model.open(url) } }
                .task {
                    #if DEBUG
                    print("horizon: launch task, arguments \(CommandLine.arguments.dropFirst().joined(separator: " "))")
                    // `xcrun simctl launch booted com.daniel.horizon --ingest-sample` drives the sample read without a tap.
                    if CommandLine.arguments.contains("--ingest-sample"), let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") {
                        await model.importFiles([sample]); return
                    }
                    if CommandLine.arguments.contains("--demo-reading") { model.demoReading(); return }   // the reading section at its widest; nothing is read
                    // `--ingest-file <path>` reads any file the simulator can see: unreadable ones, duplicates, and so on.
                    if let i = CommandLine.arguments.firstIndex(of: "--ingest-file"), i + 1 < CommandLine.arguments.count {
                        await model.importFiles([URL(fileURLWithPath: CommandLine.arguments[i + 1])]); return
                    }
                    #endif
                    await model.drainAndSync()
                    #if DEBUG
                    // `--read-first-waiting-on-device`: the confirmation's outcome without a tap (a document waiting for Claude is read on the device).
                    if CommandLine.arguments.contains("--read-first-waiting-on-device"),
                       let waiting = try? await model.store.documents().first(where: { $0.status == .awaitingCloudParse }) {
                        await model.readOnDevice(documentID: waiting.id)
                    }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await model.drainAndSync() } }
                #if os(macOS)
                .task { await WatchedFolder.start(model: model) }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
            #if os(iOS)
            if phase == .background { model.appEnteredBackground() }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 800)
        .commands { HorizonCommands(model: model) }
        #endif
        #if os(macOS)
        Settings {   // ⌘, — its own window, the way a Mac keeps its settings
            MacSettingsView().environment(model).modelContainer(model.container).tint(Design.accent)
        }
        #endif
    }
}

#if os(iOS)
/// Drains the inbox when iOS gives the app background time, so a document shared at night is in Reminders by morning,
/// and a read paused when the user left goes on from its checkpoint.
enum BackgroundIngest {
    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Identifiers.backgroundIngestTask, using: nil) { task in
            let work = Task { @MainActor in
                await model.drainAndSync()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = {
                work.cancel()   // reaches the read under way: the part being read is lost, the checkpoint keeps the rest, the document stays queued
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// `needsNetwork`: a read with Claude is only worth starting with the network there.
    static func schedule(needsNetwork: Bool) {
        let request = BGProcessingTaskRequest(identifier: Identifiers.backgroundIngestTask)
        request.requiresNetworkConnectivity = needsNetwork
        request.requiresExternalPower = false
        BGTaskScheduler.shared.submitTaskRequest(request) { error in   // submission is asynchronous now; a refusal is worth a log line
            if let error { Logger(subsystem: Identifiers.bundlePrefix, category: "ingest").error("background ingest not scheduled: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
#endif
