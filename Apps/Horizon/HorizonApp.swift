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
        _model = State(initialValue: model)
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
                    // `xcrun simctl launch booted com.daniel.horizon --ingest-sample` drives the sample read without a tap.
                    if CommandLine.arguments.contains("--ingest-sample"), let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") {
                        await model.importFiles([sample]); return
                    }
                    #endif
                    await model.drainAndSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await model.drainAndSync() } }
                #if os(macOS)
                .task { await WatchedFolder.start(model: model) }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.drainAndSync() } }
            #if os(iOS)
            if phase == .background { BackgroundIngest.schedule() }
            #endif
        }
    }
}

#if os(iOS)
/// Drains the inbox when iOS gives the app background time, so a document shared at night is in Reminders by morning.
enum BackgroundIngest {
    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Identifiers.backgroundIngestTask, using: nil) { task in
            let work = Task { @MainActor in
                await model.drainAndSync()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = {
                work.cancel()   // the drain checks cancellation between documents; the rest stays queued
                task.setTaskCompleted(success: false)
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: Identifiers.backgroundIngestTask)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
