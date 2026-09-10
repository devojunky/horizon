import Foundation

/// Where a read stands, part by part, so a read that stops (the app suspended, quit or killed, a network lost) goes
/// on from the last finished part instead of starting over. The finished parts' facts are kept whole; the read that
/// resumes feeds them to the merger as if it had just read them. A checkpoint is only good for the same route and the
/// same chunking: a document read on another route, or a build that chunks differently, starts afresh.
public struct IngestCheckpoint: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var index: Int
        var outcomes: [ExtractionOutcome]
    }
    public var route: ModelRoute
    public var textChunks: Int
    public var images: Int
    var entries: [Entry] = []

    public init(route: ModelRoute, textChunks: Int, images: Int) {
        self.route = route; self.textChunks = textChunks; self.images = images
    }

    /// How many parts (text chunks and image pages) are finished.
    public var finishedParts: Int { entries.count }
    public var totalParts: Int { textChunks + images }

    /// Whether this checkpoint can stand in for the first parts of a read chunked as described.
    public func applies(route: ModelRoute, textChunks: Int, images: Int) -> Bool {
        self.route == route && self.textChunks == textChunks && self.images == images && !entries.isEmpty
    }

    func entry(at index: Int) -> Entry? { entries.first { $0.index == index } }

    mutating func record(index: Int, outcomes: [ExtractionOutcome]) {
        entries.removeAll { $0.index == index }
        entries.append(Entry(index: index, outcomes: outcomes))
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(data: Data) throws { self = try JSONDecoder().decode(IngestCheckpoint.self, from: data) }
}
