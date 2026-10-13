import Foundation
import HorizonCore

/// A place in the app, said the same way by every way in: a `horizon://` link (a reminder's provenance link, the Live
/// Activity, a widget), an intent (Siri, Shortcuts, Spotlight, a control), a DEBUG flag. `AppModel.navigate(to:)` asks
/// for it; the iOS tabs or the Mac's window in front take it.
enum AppDestination: Equatable, Sendable {
    case page(AppPage)
    case course(UUID)
    /// An item, opened for editing (on a Mac: in Review while it waits there, else on its course's page).
    case item(UUID)
    /// A document's file, in Quick Look.
    case document(UUID)
    /// A course's policies: its page, at them.
    case policies(course: UUID)
    /// The Horizon strip, narrowed to a course and looking at a day (its week on iOS's semester), either optional.
    case horizon(course: UUID?, day: Date?)
    case search(String)
    /// The file picker, Photos (screenshots only, for a control's one tap), or the camera.
    case importDocument(ImportChoice)

    /// `horizon://obligation/<id>` (the link on every reminder), `horizon://now`, `horizon://page/<page>`,
    /// `horizon://course/<id>`, `horizon://document/<id>`, `horizon://horizon?day=<yyyy-mm-dd>&course=<id>`,
    /// `horizon://search?q=<text>`, `horizon://import/<choice>`.
    init?(url: URL) {
        guard url.scheme == Identifiers.urlScheme, let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch host {
        case "obligation", "item": guard let id = parts.first.flatMap(UUID.init(uuidString:)) else { return nil }; self = .item(id)
        case "now": self = .page(.now)
        case "page": guard let page = parts.first.flatMap(AppPage.init(rawValue:)) else { return nil }; self = .page(page)
        case "course": guard let id = parts.first.flatMap(UUID.init(uuidString:)) else { return nil }; self = .course(id)
        case "document": guard let id = parts.first.flatMap(UUID.init(uuidString:)) else { return nil }; self = .document(id)
        case "horizon": self = .horizon(course: value("course").flatMap(UUID.init(uuidString:)), day: value("day").flatMap(Self.day(from:)))
        case "search": self = .search(value("q") ?? "")
        case "import": self = .importDocument(parts.first.flatMap(ImportChoice.init(rawValue:)) ?? .files)
        default: return nil
        }
    }

    /// The link for a place, for widgets and anything else that can only open a URL.
    var url: URL {
        var c = URLComponents()
        c.scheme = Identifiers.urlScheme
        switch self {
        case .page(let page): c.host = "page"; c.path = "/" + page.rawValue
        case .course(let id): c.host = "course"; c.path = "/" + id.uuidString
        case .item(let id): c.host = "obligation"; c.path = "/" + id.uuidString
        case .document(let id): c.host = "document"; c.path = "/" + id.uuidString
        case .policies(let id): c.host = "course"; c.path = "/" + id.uuidString
        case .horizon(let course, let day):
            c.host = "horizon"
            c.queryItems = [course.map { URLQueryItem(name: "course", value: $0.uuidString) }, day.map { URLQueryItem(name: "day", value: Self.dayString($0)) }].compactMap { $0 }
        case .search(let text): c.host = "search"; c.queryItems = [URLQueryItem(name: "q", value: text)]
        case .importDocument(let choice): c.host = "import"; c.path = "/" + choice.rawValue
        }
        return c.url!
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func day(from string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// The app's pages, as the iOS tabs and stack and the Mac's sidebar hold them.
enum AppPage: String, CaseIterable, Sendable {
    case coverage, horizon, now, review, documents, recentlyDeleted, settings, search
}

/// Where a document comes from when the app is asked to take one.
enum ImportChoice: String, CaseIterable, Sendable {
    case files, photos, screenshots, camera
}

/// Items changed by an intent, stamped so that changing the same ones twice is seen twice.
struct ChangedItems: Equatable, Sendable {
    var ids: Set<UUID>
    var at = Date()
}
