import Foundation
import SwiftData
import CryptoKit

public enum HorizonContainer {
    /// The generation of what a row stores. Bump it with every change to a stored property: a model's, or a field of a
    /// Codable value kept in one (`GradeComponent`, `ClosedDateRange`, `DocumentWord`, `MeetingSlot`), and record the
    /// schema's new fingerprint in `StoreTests`. A store remembers the highest generation that opened it, and a build
    /// older than that refuses to open it (`StoreTooNew`) rather than let SwiftData migrate it down to its own schema
    /// and drop every field it lacks (what an old build did to the owner's store on 2026-09-28). Only builds with this
    /// guard are protected: an old build left on disk is still a hazard.
    /// 2 (2026-10-05): `Obligation.documentWords`, `SourceDocument.failureIsPermanent`.
    /// 3 (2026-10-13): `Obligation.skippedAt`, `Obligation.notesFromSiri`.
    public static let storeGeneration = 3

    /// The shared store: on iOS in the App Group container, so the share extension writes to the same database as the
    /// app; on a Mac, which has no App Group (its Inbox folder is read by the app itself), a store of its own in
    /// Application Support/Horizon. CloudKit mirroring is compiled in with `HORIZON_CLOUDKIT` (needs a paid team). Throws
    /// `StoreTooNew` when a newer build has opened the store: nothing is opened, and the app must say so, never fall
    /// back to an empty store.
    public static func shared() throws -> ModelContainer {
        let schema = Schema(versionedSchema: HorizonSchemaV1.self)
        // macOS hands back a group container path even without the entitlement but never creates it; make sure the
        // store's directory exists, and fall back to a private store in Application Support when it cannot.
        let groupReady = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup).map { group in
            (try? FileManager.default.createDirectory(at: group.appendingPathComponent("Library/Application Support", isDirectory: true), withIntermediateDirectories: true)) != nil
        } ?? false
        guard groupReady else {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Horizon", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try open(schema, ModelConfiguration(schema: schema, url: dir.appendingPathComponent("Horizon.store"), cloudKitDatabase: .none))
        }
        #if HORIZON_CLOUDKIT
        let config = ModelConfiguration(schema: schema, groupContainer: .identifier(Identifiers.appGroup), cloudKitDatabase: .private(Identifiers.cloudKitContainer))
        #else
        let config = ModelConfiguration(schema: schema, groupContainer: .identifier(Identifiers.appGroup), cloudKitDatabase: .none)
        #endif
        return try open(schema, config)
    }

    /// Opens a store on disk unless a newer build has opened it, then records this build's generation beside it (the
    /// higher of the two). A store with no record is older than the guard, never a refusal.
    static func open(_ schema: Schema, _ config: ModelConfiguration) throws -> ModelContainer {
        let marker = generationMarker(for: config.url)
        let recorded = recordedGeneration(at: marker)
        if let recorded, recorded > storeGeneration { throw StoreTooNew(recorded: recorded, supported: storeGeneration) }
        let container = try ModelContainer(for: schema, migrationPlan: HorizonMigrationPlan.self, configurations: [config])
        if recorded != storeGeneration { try? String(max(recorded ?? 0, storeGeneration)).write(to: marker, atomically: true, encoding: .utf8) }
        return container
    }

    /// Beside the store, its name and `.generation` (`default.store.generation` in the App Group, `Horizon.store.generation`
    /// in Application Support or a scratch folder), holding the number alone.
    static func generationMarker(for store: URL) -> URL { store.appendingPathExtension("generation") }

    static func recordedGeneration(at marker: URL) -> Int? {
        (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Throwaway store for tests and previews.
    public static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: HorizonSchemaV1.self)
        return try ModelContainer(for: schema, migrationPlan: HorizonMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A store in a file of its own, for tools that open a copy of one (the app's DEBUG `--scratch-store`). Never the
    /// user's: a path in a folder their store can live in is refused before anything is opened. Opening a store
    /// migrates it to this build's schema, so the user's is only ever opened by `shared()`. A copy a newer build has
    /// opened is refused too (`StoreTooNew`).
    public static func at(_ url: URL) throws -> ModelContainer {
        guard !isUserStoreFolder(url, folders: userStoreFolders) else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        let schema = Schema(versionedSchema: HorizonSchemaV1.self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try open(schema, ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
    }

    /// Where the user's store can be: the App Group's container, or Application Support when a build has no App Group.
    static var userStoreFolders: [URL] {
        [FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup),
         FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Horizon", isDirectory: true)].compactMap { $0 }
    }

    /// Whether `url` is in (or is) one of `folders`, symbolic links resolved.
    static func isUserStoreFolder(_ url: URL, folders: [URL]) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return folders.contains { folder in
            let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }
}

/// The store was last opened by a newer build of Horizon than this one, which would migrate it down and lose what the
/// newer build stores. Nothing was opened; the user should install the newer build.
public struct StoreTooNew: Error, LocalizedError, Equatable {
    /// The generation recorded beside the store, and the one this build understands.
    public let recorded: Int, supported: Int
    public var errorDescription: String? { "Horizon's data was saved by a newer version of Horizon. Install the latest version to open it; nothing was changed." }
}

/// Source files live on disk in the App Group container, keyed by content hash; the store keeps only metadata.
/// Other devices see "ingested on <device>, not available here" (SPEC §4.4).
public struct DocumentStorage: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The App Group's Documents folder, or Application Support when the build has no App Group entitlement. macOS
    /// hands back a group path either way but lets only an entitled app create anything there, so the folder is made
    /// here, and the fallback taken when it cannot be (the same rule the database follows).
    public static func appGroup() -> DocumentStorage? {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup) {
            let root = group.appendingPathComponent("Documents", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil { return DocumentStorage(root: root) }
        }
        return (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { DocumentStorage(root: $0.appendingPathComponent("Horizon/Documents", isDirectory: true)) }
    }

    public static func temporary() -> DocumentStorage {
        DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("HorizonDocuments-\(UUID().uuidString)", isDirectory: true))
    }

    public func url(sha256: String, extension ext: String) -> URL {
        root.appendingPathComponent(sha256).appendingPathExtension(ext.lowercased())
    }

    /// Largest document accepted (the share extension has ~120 MB of memory; hashing streams, but parsing does not).
    public static let maximumBytes = 50 * 1024 * 1024

    /// Copies a file in and returns its hash and stored location. A file already stored is not copied twice.
    public func store(_ source: URL) throws -> (sha256: String, url: URL) {
        var source = source
        // A link is followed to its file, which is then measured, hashed and copied as itself: measured as a link it
        // passes any cap, and copied as one it breaks when its target moves.
        if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { source = source.resolvingSymlinksInPath() }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumBytes else { throw StorageError.tooLarge(size) }
        let hash = try DocumentStorage.sha256(fileAt: source)
        let destination = url(sha256: hash, extension: source.pathExtension.isEmpty ? "bin" : source.pathExtension)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
        return (hash, destination)
    }

    /// Hash without loading the whole file into memory.
    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Removes a stored file; a file that is already gone is not an error.
    public func remove(sha256: String, extension ext: String) {
        try? FileManager.default.removeItem(at: url(sha256: sha256, extension: ext))
    }

    public func exists(sha256: String, extension ext: String) -> Bool {
        FileManager.default.fileExists(atPath: url(sha256: sha256, extension: ext).path)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum StorageError: Error, LocalizedError {
    case tooLarge(Int)
    public var errorDescription: String? {
        switch self { case .tooLarge(let bytes): "File is \(bytes / 1_048_576) MB; Horizon reads documents up to \(DocumentStorage.maximumBytes / 1_048_576) MB" }
    }
}
