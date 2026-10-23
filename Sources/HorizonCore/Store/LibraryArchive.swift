import Foundation
import AppleArchive
import System
import SQLite3

/// The whole library in one file, to carry it to a new install (a new signing team is a new app to iOS, and starts
/// empty: DECISIONS 2026-10-23). Lossless by construction: the store itself (a consistent copy, made with SQLite's
/// backup while the store stays open), the documents' files, the sync's memory (the reminders it has seen, the list's
/// identity) and the app's settings, so every item keeps its id and its reminder's identifier, and the new install
/// takes up the old reminders rather than writing new ones beside them. Not the Claude key: a secret is never written
/// to a file.
///
/// An import replaces the library and can only happen before the store opens, so it is staged (`stage`) and applied at
/// the next launch (`applyPending`).
public enum LibraryArchive {
    public static let typeIdentifier = "com.daniel.horizon.library"
    public static let fileExtension = "horizonlibrary"
    /// Raised when the archive's own layout changes; a later layout is refused by an older build.
    public static let format = 1

    /// What an archive holds, written beside its contents and read before anything is replaced.
    public struct Manifest: Codable, Sendable, Equatable {
        public var format: Int
        public var storeGeneration: Int
        public var exportedAt: Date
        public var deviceName: String
        public var courses: Int, items: Int, documents: Int
        public init(storeGeneration: Int = HorizonContainer.storeGeneration, exportedAt: Date = Date(), deviceName: String, courses: Int, items: Int, documents: Int) {
            self.format = LibraryArchive.format; self.storeGeneration = storeGeneration; self.exportedAt = exportedAt
            self.deviceName = deviceName; self.courses = courses; self.items = items; self.documents = documents
        }
    }

    public enum ArchiveError: Error, LocalizedError, Equatable {
        case notALibrary, tooNew, unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .notALibrary: "This file is not a Horizon library."
            case .tooNew: "This library was exported by a newer version of Horizon. Install the latest version to import it."
            case .unreadable(let why): "The library could not be read (\(why))."
            }
        }
    }

    // The names inside an archive (and inside a staged import).
    static let storeName = "Horizon.store", documentsName = "Documents", manifestName = "Manifest.json"
    static let syncName = "Sync.plist", settingsName = "Settings.plist"

    /// Writes the library to `destination`: the store at `store` (open or not), every file in `documents`, and the two
    /// preference domains as they are now.
    public static func export(store: URL, documents: URL, sync: [String: Any], settings: [String: Any], manifest: Manifest, to destination: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("HorizonExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try backup(from: store, to: work.appendingPathComponent(storeName))
        let docs = work.appendingPathComponent(documentsName, isDirectory: true)
        if fm.fileExists(atPath: documents.path) { try fm.copyItem(at: documents, to: docs) } else { try fm.createDirectory(at: docs, withIntermediateDirectories: true) }
        try plist(sync).write(to: work.appendingPathComponent(syncName))
        try plist(settings).write(to: work.appendingPathComponent(settingsName))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: work.appendingPathComponent(manifestName))
        try? fm.removeItem(at: destination)
        try compress(work, to: destination)
    }

    /// Reads an archive into `folder` (made empty first) and checks it can be imported: a library, in a layout and of
    /// a store generation this build understands. Throws before anything of the user's is touched.
    @discardableResult
    public static func unpack(_ archive: URL, into folder: URL) throws -> Manifest {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try extract(archive, to: folder) } catch { try? fm.removeItem(at: folder); throw ArchiveError.notALibrary }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let manifest = try? decoder.decode(Manifest.self, from: data),
              fm.fileExists(atPath: folder.appendingPathComponent(storeName).path) else { try? fm.removeItem(at: folder); throw ArchiveError.notALibrary }
        guard manifest.format <= format, manifest.storeGeneration <= HorizonContainer.storeGeneration else { try? fm.removeItem(at: folder); throw ArchiveError.tooNew }
        return manifest
    }

    /// Where an import waits for the next launch: beside the store it will replace.
    public static func pendingFolder(forStore store: URL) -> URL {
        store.deletingLastPathComponent().appendingPathComponent("PendingImport", isDirectory: true)
    }

    /// Unpacks `archive` to wait beside the store until the next launch. A second import staged before then replaces the first.
    @discardableResult
    public static func stage(_ archive: URL, forStore store: URL) throws -> Manifest {
        try unpack(archive, into: pendingFolder(forStore: store))
    }

    public static func pendingManifest(forStore store: URL) -> Manifest? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: pendingFolder(forStore: store).appendingPathComponent(manifestName))).flatMap { try? decoder.decode(Manifest.self, from: $0) }
    }

    public static func cancelPending(forStore store: URL) { try? FileManager.default.removeItem(at: pendingFolder(forStore: store)) }

    /// At launch, before the store opens: a staged import replaces the store, its generation marker, the documents'
    /// files and the two preference domains, and the staging folder goes. Nothing is applied from a folder that is not
    /// a whole import. Returns what was imported.
    public static func applyPending(store: URL, documents: URL, sync: UserDefaults?, settings: UserDefaults) -> Manifest? {
        let fm = FileManager.default
        let pending = pendingFolder(forStore: store)
        guard let manifest = pendingManifest(forStore: store), fm.fileExists(atPath: pending.appendingPathComponent(storeName).path) else { return nil }
        defer { try? fm.removeItem(at: pending) }
        do {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: store.path + suffix)) }
            try fm.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: pending.appendingPathComponent(storeName), to: store)
            try String(manifest.storeGeneration).write(to: HorizonContainer.generationMarker(for: store), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: documents)
            try fm.createDirectory(at: documents.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: pending.appendingPathComponent(documentsName, isDirectory: true), to: documents)
        } catch { return nil }
        if let sync { apply(pending.appendingPathComponent(syncName), to: sync) }
        apply(pending.appendingPathComponent(settingsName), to: settings)
        return manifest
    }

    /// A preference domain's own keys, without the system's (a domain read whole carries a few of those).
    public static func ownKeys(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { key, _ in !["Apple", "NS", "com.apple.", "WebKit", "PK", "AK"].contains { key.hasPrefix($0) } }
    }

    private static func apply(_ file: URL, to defaults: UserDefaults) {
        guard let data = try? Data(contentsOf: file),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for (key, value) in ownKeys(values) { defaults.set(value, forKey: key) }
    }

    private static func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ownKeys(values), format: .binary, options: 0)
    }

    // MARK: The store's copy

    /// SQLite's online backup: a consistent single-file copy of a database another connection has open, write-ahead
    /// log included, without stopping it.
    static func backup(from source: URL, to destination: URL) throws {
        var from: OpaquePointer?, to: OpaquePointer?
        guard sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(from); throw ArchiveError.unreadable("the library's database would not open") }
        defer { sqlite3_close(from) }
        sqlite3_busy_timeout(from, 5000)
        guard sqlite3_open_v2(destination.path, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { sqlite3_close(to); throw ArchiveError.unreadable("the copy could not be made") }
        defer { sqlite3_close(to) }
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else { throw ArchiveError.unreadable(String(cString: sqlite3_errmsg(to))) }
        var step = SQLITE_OK
        repeat {
            step = sqlite3_backup_step(backup, -1)
            if step == SQLITE_BUSY || step == SQLITE_LOCKED { usleep(50_000) }
        } while step == SQLITE_OK || step == SQLITE_BUSY || step == SQLITE_LOCKED
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw ArchiveError.unreadable(String(cString: sqlite3_errstr(step))) }
        // The copy is a database of its own: no write-ahead log to carry, so it is whole in one file.
        sqlite3_exec(to, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
    }

    // MARK: The archive (Apple Archive, LZFSE)

    static func compress(_ folder: URL, to file: URL) throws {
        guard let out = ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .writeOnly, options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)) else { throw ArchiveError.unreadable("the file could not be written") }
        defer { try? out.close() }
        guard let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: out) else { throw ArchiveError.unreadable("compression") }
        defer { try? compressed.close() }
        guard let encoder = ArchiveStream.encodeStream(writingTo: compressed) else { throw ArchiveError.unreadable("encoding") }
        defer { try? encoder.close() }
        guard let keys = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DAT,MOD,MTM") else { throw ArchiveError.unreadable("encoding") }
        try encoder.writeDirectoryContents(archiveFrom: FilePath(folder.path), keySet: keys)
    }

    static func extract(_ file: URL, to folder: URL) throws {
        guard let input = ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)) else { throw ArchiveError.notALibrary }
        defer { try? input.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: input) else { throw ArchiveError.notALibrary }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw ArchiveError.notALibrary }
        defer { try? decoder.close() }
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), flags: [.ignoreOperationNotPermitted]) else { throw ArchiveError.notALibrary }
        defer { try? extractor.close() }
        _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
    }
}
