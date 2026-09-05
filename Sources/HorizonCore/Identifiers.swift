import Foundation

/// Every identifier the app, the share extension and the store agree on. Change them together with `project.yml`.
public enum Identifiers {
    public static let bundlePrefix = "app.horizon"
    public static let appGroup = "group.app.horizon"
    public static let cloudKitContainer = "iCloud.app.horizon"
    public static let urlScheme = "horizon"
    public static let remindersListTitle = "Horizon"
    public static let backgroundIngestTask = "app.horizon.ingest"

    /// Deep link stored on every reminder so items can be matched even before external identifiers sync.
    public static func link(for obligationID: UUID) -> URL { URL(string: "\(urlScheme)://obligation/\(obligationID.uuidString)")! }
    public static func obligationID(from url: URL?) -> UUID? {
        guard let url, url.scheme == urlScheme, url.host == "obligation" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
