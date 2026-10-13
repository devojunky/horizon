import AppIntents
import SwiftUI
import HorizonCore

// What is on screen, for Siri ("push this to Sunday", "what's the late policy here?"): WWDC26's view annotations. A page
// whose subject is one thing (a course's page, an item's editor) says so with a user activity naming its entity; a row
// among many carries `.appEntityIdentifier` itself (`ObligationRow`, the course page's policies and documents, Search,
// the Mac's tables by their selection).

extension View {
    /// This page is about one course, item, policy or document: its entity is Siri's "this".
    func showsEntity<E: AppEntity>(_ type: E.Type, id: E.ID?, title: String) -> some View {
        userActivity("\(Identifiers.activityPrefix).\(String(describing: E.self))", isActive: id != nil) { activity in
            guard let id else { return }
            activity.title = title
            activity.appEntityIdentifier = EntityIdentifier(for: E.self, identifier: id)
        }
    }
}

extension Identifiers {
    /// The activity types the app's pages publish (Info.plist `NSUserActivityTypes` lists them).
    static let activityPrefix = bundlePrefix + ".showing"
}
