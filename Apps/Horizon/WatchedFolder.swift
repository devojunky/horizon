#if os(macOS)
import Foundation

/// `~/Horizon Inbox`: anything dropped there is ingested (SPEC §4.1). The macOS build is not sandboxed yet, so no bookmark is needed.
/// A file is imported once its size and modification date have stopped changing, so a copy in progress is never read half-way.
@MainActor
enum WatchedFolder {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Horizon Inbox", isDirectory: true)
    private static var source: DispatchSourceFileSystemObject?
    private static var imported: Set<String> = []          // path + size + modification date
    private static var pending: [String: (size: Int, modified: Date)] = [:]

    static func start(model: AppModel) async {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await sweep(model: model)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0, source == nil else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { Task { @MainActor in await sweep(model: model) } }
        source.setCancelHandler { close(fd) }
        source.resume()
        Self.source = source
    }

    private static func sweep(model: AppModel) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var ready: [URL] = []
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { continue }
            let key = "\(file.path)|\(size)|\(modified.timeIntervalSince1970)"
            if imported.contains(key) { continue }
            if let last = pending[file.path], last.size == size, last.modified == modified {
                ready.append(file); imported.insert(key); pending[file.path] = nil
            } else {
                pending[file.path] = (size, modified)   // look again after it settles
            }
        }
        if !ready.isEmpty { await model.importFiles(ready) }
        if !pending.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            await sweep(model: model)
        }
    }
}
#endif
