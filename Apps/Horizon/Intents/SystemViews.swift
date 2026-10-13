import AppIntents
import CoreSpotlight
import Foundation
import HorizonCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What Horizon keeps current outside its own windows, a moment after every change the store saves (a read, a check,
/// an edit, a sync): Spotlight's index of its courses, items, policies and documents (also Siri's semantic index, so
/// Siri can find and answer from them), the widgets' glance (`Glance`, iOS), and App Shortcuts' parameters (course
/// names). A scratch run touches none of them: a copy of someone's store never reaches their Spotlight or Home Screen.
@MainActor
final class SystemViews {
    private var pending: Task<Void, Never>?
    /// What was indexed this launch, per type: anything gone since is deleted from the index.
    private var indexed: [ObjectIdentifier: Set<UUID>] = [:]

    /// Gathers changes that come in a burst (a read saves item by item) into one pass.
    func storeChanged(_ model: AppModel) {
        pending?.cancel()
        pending = Task { [weak self, weak model] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, let model else { return }
            await self.refresh(model)
        }
    }

    func refresh(_ model: AppModel) async {
        guard model.storeFailure == nil, AppModel.scratchStore == nil else { return }
        guard let (items, courses) = try? await model.intentItems(), let policies = try? await model.intentPolicies(),
              let documents = try? await model.intentDocuments() else { return }
        #if os(iOS)
        if let url = Glance.sharedURL {
            do {
                try Glance.build(items: items, now: .now, calendar: .current).write(to: url)
                WidgetCenter.shared.reloadAllTimelines()
            } catch { AppModel.log("widgets: the glance was not written: \(error.localizedDescription)") }
        }
        #endif
        await index(courses.values.map(CourseEntity.init))
        await index(items.map { ItemEntity($0, course: $0.courseID.flatMap { courses[$0] }) })
        await index(policies.map(PolicyEntity.init))
        await index(documents)
        HorizonShortcuts.updateAppShortcutParameters()
    }

    /// Spotlight asking for Horizon's entities again (`IndexedEntityQuery`: its index was lost, or is being rebuilt):
    /// every kind is cleared and indexed afresh, as at a launch. The library is small enough to do whole.
    func reindex(_ model: AppModel) async {
        indexed = [:]
        await refresh(model)
    }

    /// Indexes every entity of a kind (an entity indexed again replaces itself) and deletes those gone since the last
    /// pass. The first pass of a launch clears the kind first, so what was deleted while the app was away goes too.
    private func index<E: IndexedEntity>(_ entities: [E]) async where E.ID == UUID {
        let index = CSSearchableIndex.default()
        let key = ObjectIdentifier(E.self)
        let ids = Set(entities.map(\.id))
        do {
            if let before = indexed[key] {
                let gone = before.subtracting(ids)
                if !gone.isEmpty { try await index.deleteAppEntities(identifiedBy: Array(gone), ofType: E.self) }
            } else {
                try await index.deleteAppEntities(ofType: E.self)
            }
            if !entities.isEmpty { try await index.indexAppEntities(entities) }
            indexed[key] = ids
        } catch {
            AppModel.log("spotlight: \(E.self) not indexed: \(error.localizedDescription)")
        }
    }
}

// MARK: Reindexing on Spotlight's request (iOS 27, macOS 27)
// Any request reindexes the whole library into the default index (the only one Horizon writes), so the description,
// which carries only a protection class, is not needed; the work hops to the main actor without it.

extension AppModel {
    func reindexForSpotlight() async { await systemViews.reindex(self) }
}

extension CourseQuery: IndexedEntityQuery {
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
}

extension ItemQuery: IndexedEntityQuery {
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
}

extension PolicyQuery: IndexedEntityQuery {
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
}

extension DocumentQuery: IndexedEntityQuery {
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws { await model.reindexForSpotlight() }
}

// MARK: Search through the system's index

/// What Spotlight found for one query, kept with the query, so a search page never shows the finds of the words before.
struct SpotlightFinds: Equatable {
    var query = ""
    var ranked = HorizonSearch.Ranked()
    func ranking(for query: String) -> HorizonSearch.Ranked { self.query == query ? ranked : HorizonSearch.Ranked() }
}

/// Horizon's search through the system's own index: Core Spotlight's `CSUserQuery` over what `SystemViews` indexes,
/// ranked by Spotlight and matched by meaning where the device has the models ("makeup exam policy for Calc" finds
/// Calculus II's make-up policy, words the policy does not print included). Each find names its entity
/// (`relatedAppEntityIdentifier`), so it maps back to an item, course, policy or document; `HorizonSearch` puts the
/// finds first and its own matching after them. A scratch run, whose index is the owner's, asks nothing.
enum SpotlightSearch {
    /// Loads Spotlight's models ahead of a search (Apple: just before the search interface appears).
    @MainActor static func prepare() {
        guard AppModel.scratchStore == nil else { return }
        CSUserQuery.prepare()
    }

    @MainActor static func finds(for text: String) async -> SpotlightFinds {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var finds = SpotlightFinds(query: text)
        guard !query.isEmpty, AppModel.scratchStore == nil else { return finds }
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title"]
        context.maxResultCount = 40
        context.enableRankedResults = true
        var items: [CSUserQuery.Item] = []
        do {
            for try await response in CSUserQuery(userQueryString: query, userQueryContext: context).responses {
                if case .item(let item) = response { items.append(item) }
            }
        } catch {
            AppModel.log("spotlight search: \(error.localizedDescription)")
        }
        for item in items.sorted(by: >) {
            guard let (type, id) = reference(item.item) else { continue }
            switch type {
            case String(describing: ItemEntity.self): finds.ranked.items.append(id)
            case String(describing: CourseEntity.self): finds.ranked.courses.append(id)
            case String(describing: PolicyEntity.self): finds.ranked.policies.append(id)
            case String(describing: DocumentEntity.self): finds.ranked.documents.append(id)
            default: break
            }
        }
        #if DEBUG
        AppModel.log("spotlight search: \(items.count) found for “\(query)”, \(finds.ranked.items.count + finds.ranked.courses.count + finds.ranked.policies.count + finds.ranked.documents.count) mapped"
                     + (items.first.map { "; first \($0.item.uniqueIdentifier), entity \($0.item.relatedAppEntityIdentifier?.description ?? "none")" } ?? ""))
        #endif
        return finds
    }

    /// The entity a find stands for: its related entity when Spotlight says, else its identifier, which for an entity
    /// indexed through `indexAppEntities` reads "<entity type>/<id>" ("ItemEntity/22C9A231-…", iOS 27.0, where the
    /// related entity came back empty). Not a documented form, so a find that fits neither is passed over.
    static func reference(_ item: CSSearchableItem) -> (type: String, id: UUID)? {
        if let entity = item.relatedAppEntityIdentifier, let id = UUID(uuidString: entity.identifier) {
            return (String(describing: entity.entityType), id)
        }
        let parts = item.uniqueIdentifier.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (String(parts[0]), id)
    }
}
