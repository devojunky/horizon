#if os(macOS)
import AppKit

/// The Inbox (SPEC §4.1): a folder the user chose, whose documents are read as they arrive. The App Sandbox lets the app
/// into a folder outside its container only once the user has chosen it, so the choice is kept as a security-scoped
/// bookmark and opened again at every launch; nothing is watched until a folder is chosen.
/// What a folder holds when it is chosen is left alone: only what is saved or dropped into it afterwards is read, so
/// choosing Downloads sends nothing already there to Claude. A file is read once its size and modification date have
/// stopped changing, so a copy in progress is never read half-way, and then remembered (by its name, size and date in the
/// folder, so a folder renamed or moved reads nothing again): a document the user then deletes stays deleted, and one
/// that failed is not read again at every launch. A file changed since is read again.
/// The bookmark and the memory are kept in `AppModel.defaults` (a scratch run's are its own) and stay on this Mac:
/// Export Library leaves them out.
@MainActor
@Observable
final class WatchedFolder {
    static let shared = WatchedFolder()

    /// The folder being watched: nil until one is chosen, and when the one chosen cannot be opened (`problem` says why).
    private(set) var url: URL?
    private(set) var problem: String?

    /// The folder as Settings names it: in the home folder, from `~`.
    var path: String? {
        guard var path = url?.path(percentEncoded: false) else { return nil }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let home = Self.home.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var scoped: URL?   // a folder opened from its bookmark, whose access is let go of when it is closed
    @ObservationIgnored private var seen: Set<String>   // name + size + modification date
    @ObservationIgnored private var pending: [String: (size: Int, modified: Date)] = [:]
    @ObservationIgnored private var rescan: Task<Void, Never>?
    private static let bookmarkKey = "inboxBookmark"
    private static let seenKey = "inboxSeen"   // `inboxImported` held whole paths before the sandbox, and an old export still carries it

    private init() {
        seen = Set(AppModel.defaults.stringArray(forKey: Self.seenKey) ?? [])
    }

    /// At launch, once the library is open: the folder chosen before, opened again from its bookmark. The work is the
    /// folder's own, not the window's, so closing a window stops nothing.
    func start(model: AppModel) {
        guard self.model == nil else { return }   // a second window: the folder is already watched
        self.model = model
        AppModel.defaults.removeObject(forKey: "inboxImported")
        Task { await open() }
    }

    /// The open panel, a new folder allowed, then the folder chosen is watched in place of the last.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Horizon reads what is saved or dropped into this folder from now on. What it holds already is left alone."
        panel.directoryURL = url ?? Self.home
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await choose(folder) }
    }

    /// Watches `folder` from now on, in place of the last, leaving what it holds now alone (a choice in the open panel,
    /// or DEBUG `--inbox`).
    func choose(_ folder: URL) async {
        stop()
        guard watch(folder, keeping: true) else { return }
        seen = Set(listing()?.map(\.key) ?? [])
        AppModel.defaults.set(Array(seen), forKey: Self.seenKey)
    }

    /// Stops watching, and forgets the folder.
    func stop() {
        close()
        problem = nil
        AppModel.defaults.removeObject(forKey: Self.bookmarkKey)
    }

    /// The folder from its bookmark, which follows it when it is moved or renamed, then what arrived since it was last
    /// looked at. Whatever was being watched is closed first.
    private func open() async {
        close()
        guard let bookmark = AppModel.defaults.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            problem = "The folder chosen can no longer be found."
            return
        }
        guard !folder.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else {
            problem = "The folder chosen is in the Trash."
            return
        }
        if watch(folder, keeping: stale) { await sweep() }   // a stale bookmark (the folder moved or renamed) is made again
    }

    /// Opens `folder` (its security scope, when it came from a bookmark), keeps a bookmark of it when asked, and watches
    /// it: a change inside is swept, and the folder itself moving or going opens it again from its bookmark.
    private func watch(_ folder: URL, keeping: Bool) -> Bool {
        let opened = folder.startAccessingSecurityScopedResource()   // false for the open panel's own URL, which is open already
        let fd = Darwin.open(folder.path, O_EVTONLY)
        let bookmark = keeping ? try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        guard fd >= 0, !keeping || bookmark != nil else {
            if fd >= 0 { Darwin.close(fd) }
            if opened { folder.stopAccessingSecurityScopedResource() }
            problem = "Horizon could not open the folder chosen."
            return false
        }
        if let bookmark { AppModel.defaults.set(bookmark, forKey: Self.bookmarkKey) }
        scoped = opened ? folder : nil
        url = folder
        problem = nil
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak source] in
            let moved = !(source?.data.intersection([.rename, .delete]).isEmpty ?? true)
            Task { @MainActor in
                if moved { await WatchedFolder.shared.open() } else { await WatchedFolder.shared.sweep() }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
        return true
    }

    /// Stops watching the folder and lets go of it, keeping its bookmark.
    private func close() {
        source?.cancel()
        source = nil
        rescan?.cancel()
        rescan = nil
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        url = nil
        pending = [:]
    }

    /// The folder's files (hidden ones aside), each with its key; nil when the folder cannot be listed (moved, gone),
    /// which leaves what was seen alone.
    private func listing() -> [(file: URL, name: String, size: Int, modified: Date, key: String)]? {
        guard let url, let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return files.compactMap { file in
            guard !file.lastPathComponent.hasPrefix("."),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return (file, file.lastPathComponent, size, modified, "\(file.lastPathComponent)|\(size)|\(modified.timeIntervalSince1970)")
        }
    }

    /// Reads what has settled since the last look. A library that did not open reads nothing, and remembers nothing, so
    /// what arrived is read once it opens.
    private func sweep() async {
        guard let model, let files = listing() else { return }
        var ready: [URL] = []
        for entry in files where !seen.contains(entry.key) {
            if let last = pending[entry.name], last.size == entry.size, last.modified == entry.modified {
                ready.append(entry.file); seen.insert(entry.key); pending[entry.name] = nil
            } else {
                pending[entry.name] = (entry.size, entry.modified)   // look again after it settles
            }
        }
        let names = Set(files.map(\.name))
        pending = pending.filter { names.contains($0.key) }   // a file gone before it settled (a download renamed) is not waited for
        seen.formIntersection(files.map(\.key))   // a file gone from the folder is forgotten; put back, it is read again
        AppModel.defaults.set(Array(seen), forKey: Self.seenKey)
        if !pending.isEmpty, rescan == nil {
            rescan = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                rescan = nil
                await sweep()
            }
        }
        if !ready.isEmpty { await model.importFiles(ready) }
    }

    /// The user's home folder, where the open panel starts: in the sandbox, `homeDirectoryForCurrentUser` is the app's container.
    private static var home: URL {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
}
#endif
