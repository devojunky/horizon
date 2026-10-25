import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import HorizonCore
#if os(macOS)
import AppKit
#endif

/// Export Library and Import Library (DECISIONS 2026-10-23): the whole library in one file, for another install of
/// Horizon, such as the one a new signing team makes (to iOS a new app, empty). The file is `LibraryArchive`'s: the
/// store as it is, the documents' files, the sync's memory and the settings, so the new install takes up the reminders
/// the old one wrote instead of writing them again. The Claude key stays behind.

extension UTType {
    /// Declared in project.yml (`UTExportedTypeDeclarations`).
    static let horizonLibrary = UTType(exportedAs: LibraryArchive.typeIdentifier, conformingTo: .data)
}

extension AppModel {
    /// The store this run opens: the scratch copy in a `--scratch-store` run, else the shared one.
    static func libraryStoreURL() throws -> URL {
        if let scratch = scratchStore { return scratch.appendingPathComponent("Horizon.store") }
        return try HorizonContainer.sharedStoreURL()
    }

    /// The preference domain `AppModel.defaults` keeps the app's settings in.
    static var settingsDomain: String { scratchStore != nil ? Identifiers.bundlePrefix + ".scratch" : Bundle.main.bundleIdentifier ?? Identifiers.bundlePrefix }

    /// At launch, before the store opens: a staged import replaces the library. A scratch run's import replaces its
    /// scratch copy and leaves the sync's memory alone (it has none on disk).
    static func applyPendingImport() -> LibraryArchive.Manifest? {
        guard let store = try? libraryStoreURL(),
              let documents = scratchStore.map({ $0.appendingPathComponent("Documents", isDirectory: true) }) ?? DocumentStorage.appGroup()?.root else { return nil }
        let manifest = LibraryArchive.applyPending(store: store, documents: documents,
                                                   sync: scratchStore == nil ? UserDefaults(suiteName: Identifiers.appGroup) : nil, settings: defaults)
        if let manifest { log("library: imported the one exported from \(manifest.deviceName) on \(manifest.exportedAt.formatted())") }
        return manifest
    }

    /// Writes the library to a file of its own in a temporary folder, named for the day, for the user to put somewhere.
    func exportLibrary() async throws -> URL {
        let store = try Self.libraryStoreURL()
        let context = container.mainContext
        let manifest = LibraryArchive.Manifest(deviceName: Self.deviceName,
                                               courses: (try? context.fetchCount(FetchDescriptor<Course>(predicate: #Predicate { $0.deletedAt == nil }))) ?? 0,
                                               items: (try? context.fetchCount(FetchDescriptor<Obligation>(predicate: #Predicate { $0.deletedAt == nil }))) ?? 0,
                                               documents: (try? context.fetchCount(FetchDescriptor<SourceDocument>(predicate: #Predicate { $0.deletedAt == nil }))) ?? 0)
        let sync = Self.scratchStore == nil ? UserDefaults.standard.persistentDomain(forName: Identifiers.appGroup) ?? [:] : [:]
        let settings = UserDefaults.standard.persistentDomain(forName: Self.settingsDomain) ?? [:]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HorizonLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Horizon Library \(Date().formatted(.iso8601.year().month().day())).\(LibraryArchive.fileExtension)")
        let documents = storage.root
        // Plists and the manifest are Sendable once encoded; the copy itself is file work, off the main actor.
        let syncData = try PropertyListSerialization.data(fromPropertyList: LibraryArchive.ownKeys(sync), format: .binary, options: 0)
        let settingsData = try PropertyListSerialization.data(fromPropertyList: LibraryArchive.ownKeys(settings), format: .binary, options: 0)
        try await Task.detached(priority: .userInitiated) {
            func dict(_ data: Data) -> [String: Any] { (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:] }
            try LibraryArchive.export(store: store, documents: documents, sync: dict(syncData), settings: dict(settingsData), manifest: manifest, to: file)
        }.value
        Self.log("library: exported \(manifest.courses) courses, \(manifest.items) items, \(manifest.documents) documents")
        return file
    }

    /// Unpacks a chosen file to wait for the next launch, after checking it is a library this build can open. Nothing
    /// of the user's is touched until then, and `cancelImport` takes it back. The caller sets `pendingImport` once the
    /// user has confirmed.
    func stageImport(_ file: URL) throws -> LibraryArchive.Manifest {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        return try LibraryArchive.stage(file, forStore: Self.libraryStoreURL())
    }

    func cancelImport() {
        if let store = try? Self.libraryStoreURL() { LibraryArchive.cancelPending(forStore: store) }
        pendingImport = nil
    }

    /// An import staged by an earlier run and not applied yet (the app was not closed since).
    func loadPendingImport() {
        pendingImport = (try? Self.libraryStoreURL()).flatMap { LibraryArchive.pendingManifest(forStore: $0) }
    }
}

/// Settings' Library section: Export Library…, Import Library…, and an import waiting for the app to open again.
struct LibrarySettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var exported: URL?
    @State private var choosingImport = false
    @State private var candidate: LibraryArchive.Manifest?
    @State private var failure: String?

    var body: some View {
        Section {
            if let pending = model.pendingImport {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to import").font(.headline)
                    Text("The library exported from \(pending.deviceName) on \(pending.exportedAt.formatted(date: .abbreviated, time: .shortened)) replaces this one the next time Horizon opens.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    #if os(iOS)
                    Text("Close Horizon from the app switcher and open it again.").font(.subheadline).foregroundStyle(.secondary)
                    #endif
                }
                #if os(macOS)
                Button("Quit Horizon") { NSApp.terminate(nil) }.bordered()
                #endif
                Button("Cancel Import", role: .cancel) { model.cancelImport() }.macBordered()
            } else {
                Button {
                    exporting = true
                    Task {
                        do { exported = try await model.exportLibrary() } catch { failure = error.localizedDescription }
                        exporting = false
                    }
                } label: {
                    if exporting { Label("Exporting…", systemImage: "square.and.arrow.up") } else { Label("Export Library…", systemImage: "square.and.arrow.up") }
                }
                .macBordered()
                .disabled(exporting)
                // Each presentation hangs on its own row: on a Form's section they never present.
                .fileMover(isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } }), file: exported) { result in
                    if case .failure(let error) = result { failure = error.localizedDescription } else { failure = nil }
                    if let exported { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }   // the temporary folder it was written to
                    exported = nil
                }
                Button("Import Library…", systemImage: "square.and.arrow.down") { choosingImport = true }
                    .macBordered()
                    .fileImporter(isPresented: $choosingImport, allowedContentTypes: [.horizonLibrary]) { result in
                        switch result {
                        case .success(let file):
                            do { candidate = try model.stageImport(file); failure = nil } catch { failure = error.localizedDescription }
                        case .failure(let error): failure = error.localizedDescription
                        }
                    }
                    // Erasing asks (CLAUDE.md, Storage): the import deletes what is on this device now.
                    .confirmationDialog("Replace This Library?", isPresented: Binding(get: { candidate != nil }, set: { if !$0, candidate != nil { candidate = nil; model.cancelImport() } }),
                                        titleVisibility: .visible, presenting: candidate) { pending in
                        Button("Replace Library", role: .destructive) { model.pendingImport = pending; candidate = nil }
                        Button("Cancel", role: .cancel) { candidate = nil; model.cancelImport() }
                    } message: { pending in
                        Text("The library exported from \(pending.deviceName) on \(pending.exportedAt.formatted(date: .abbreviated, time: .shortened)) (\(pending.courses) courses, \(pending.items) items, \(pending.documents) documents) replaces everything Horizon has on this device when it next opens. This cannot be undone.")
                    }
            }
            if let imported = model.importedLibrary {
                Text("Imported the library exported from \(imported.deviceName) on \(imported.exportedAt.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).font(.subheadline).foregroundStyle(Design.accentInk) }
        } header: {
            Kicker("Library")
        } footer: {
            #if os(iOS)
            Text("One file with your courses, items, documents and settings, and what Horizon knows about its reminders, so another install of Horizon picks up where this one is. Save it outside Horizon (iCloud Drive, or On My iPhone): Horizon's own folder goes with the app. The Claude key is not in it; enter it again after importing.")
            #else
            Text("One file with your courses, items, documents and settings, and what Horizon knows about its reminders, so another install of Horizon picks up where this one is. The Claude key is not in it; enter it again after importing.")
            #endif
        }
        .onAppear { model.loadPendingImport() }
    }
}
