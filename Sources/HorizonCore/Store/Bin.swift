import Foundation

/// Recently Deleted. A deleted course or document sits in the bin for `age`, restorable, before it goes for good.
/// What a deletion took (a course's items and documents, a document's items) is stamped with the same instant, so
/// restoring brings back exactly that and nothing the user had deleted by hand before.
public enum Bin {
    public static let age: TimeInterval = 30 * 86400

    /// Whether a row's deletion is the same deletion as its source's: the same recorded instant.
    public static func wentWith(_ deletedAt: Date?, _ sourceDeletedAt: Date?) -> Bool {
        guard let deletedAt, let sourceDeletedAt else { return false }
        return abs(deletedAt.timeIntervalSince(sourceDeletedAt)) < 0.001
    }

    /// When something deleted at `deletedAt` leaves the bin by itself.
    public static func expiry(of deletedAt: Date) -> Date { deletedAt.addingTimeInterval(age) }
}

extension Course {
    /// In the bin: deleted, not erased.
    public var isBinned: Bool { deletedAt != nil && erasedAt == nil }
    /// The items that went with the deletion, and come back with the restore.
    public var binnedObligations: [Obligation] { (obligations ?? []).filter { Bin.wentWith($0.deletedAt, deletedAt) } }
    /// The documents that went with the deletion.
    public var binnedDocuments: [SourceDocument] { (documents ?? []).filter { Bin.wentWith($0.deletedAt, deletedAt) } }
}

extension SourceDocument {
    /// In the bin on its own: deleted while its course, if any, is not (a document deleted with its course sits under it).
    public var isBinned: Bool { deletedAt != nil && course?.deletedAt == nil }
    /// The items that went with the deletion, and come back with the restore.
    public var binnedObligations: [Obligation] { (obligations ?? []).filter { Bin.wentWith($0.deletedAt, deletedAt) } }
}
