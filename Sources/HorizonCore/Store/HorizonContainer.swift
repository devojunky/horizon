import Foundation
import SwiftData
import CryptoKit

public enum HorizonContainer {
    /// The shared store: App Group container so the share extension and the macOS folder watcher write to the same
    /// database as the app. CloudKit mirroring is compiled in with `HORIZON_CLOUDKIT` (needs a paid team).
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
            let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("Horizon.store"), cloudKitDatabase: .none)
            return try ModelContainer(for: schema, migrationPlan: HorizonMigrationPlan.self, configurations: [config])
        }
        #if HORIZON_CLOUDKIT
        let config = ModelConfiguration(schema: schema, groupContainer: .identifier(Identifiers.appGroup), cloudKitDatabase: .private(Identifiers.cloudKitContainer))
        #else
        let config = ModelConfiguration(schema: schema, groupContainer: .identifier(Identifiers.appGroup), cloudKitDatabase: .none)
        #endif
        return try ModelContainer(for: schema, migrationPlan: HorizonMigrationPlan.self, configurations: [config])
    }

    /// Throwaway store for tests and previews.
    public static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: HorizonSchemaV1.self)
        return try ModelContainer(for: schema, migrationPlan: HorizonMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}

/// Source files live on disk in the App Group container, keyed by content hash; the store keeps only metadata.
/// Other devices see "ingested on <device>, not available here" (SPEC §4.4).
public struct DocumentStorage: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The App Group's Documents folder, or Application Support when the build has no App Group entitlement.
    public static func appGroup() -> DocumentStorage? {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup) {
            return DocumentStorage(root: group.appendingPathComponent("Documents", isDirectory: true))
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
