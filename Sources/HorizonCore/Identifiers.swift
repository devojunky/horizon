import Foundation

/// The identifiers the app, its extensions and the store agree on. Change them together with `project.yml` (which also
/// holds the extensions' bundle ids, and the widget extension's `horizon://` links are written out where they are made).
public enum Identifiers {
    /// A prefix for Horizon's own names (the log's subsystem, the Keychain's service, background tasks, activity types),
    /// not the bundle id, which is the paid team's `com.daniel.horizon.app` (project.yml; DECISIONS 2026-10-23).
    public static let bundlePrefix = "com.daniel.horizon"
    /// iOS's App Group, on the paid team (DECISIONS 2026-10-23). The Mac has no App Group: there the name only labels the
    /// preferences suite that holds the sync's memory, so it keeps the old one and remembers what it has seen.
    #if os(macOS)
    public static let appGroup = "group.com.daniel.horizon"
    #else
    public static let appGroup = "group.com.daniel.horizon.app"
    #endif
    public static let cloudKitContainer = "iCloud.com.daniel.horizon"
    public static let urlScheme = "horizon"
    public static let remindersListTitle = "Horizon"
    public static let backgroundIngestTask = "com.daniel.horizon.ingest"
    /// The background refresh that brings the plan's Live Activity in step when it next changes by itself (iOS).
    public static let activityRefreshTask = "com.daniel.horizon.activity"

    /// Deep link stored on every reminder so items can be matched even before external identifiers sync.
    public static func link(for obligationID: UUID) -> URL { URL(string: "\(urlScheme)://obligation/\(obligationID.uuidString)")! }
    public static func obligationID(from url: URL?) -> UUID? {
        guard let url, url.scheme == urlScheme, url.host == "obligation" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
