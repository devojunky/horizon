import SwiftUI
import SwiftData
import AppIntents
import HorizonCore
import IngestKit

extension Array where Element == Obligation {
    /// In date order, undated last: equally good matches read as the term runs.
    var byDue: [Obligation] { sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) } }
}

#if os(iOS)
/// Where the app goes when asked (`AppModel.destination`): the tab, then the page in it. Coverage's stack and the
/// Horizon strip take their own destinations once their tab is up (an item's details too: over its course's page, on
/// Coverage's stack); a document's Quick Look and the import pickers open here, over whichever tab is showing, so a
/// link never opens on a hidden tab.
struct AppRouter: ViewModifier {
    @Binding var tab: Int
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @State private var preview: URL?
    @State private var files = false
    @State private var photos: ImportPickers.Photos?
    @State private var scanning = false

    func body(content: Content) -> some View {
        content
            .onChange(of: model.destination, initial: true) { _, destination in route(destination) }
            .quickLookPreview($preview)
            .modifier(ImportPickers(courseID: nil, files: $files, photos: $photos, scanning: $scanning))
    }

    private func route(_ destination: AppDestination?) {
        guard let destination else { return }
        switch destination {
        case .page(.coverage), .page(.review), .page(.documents), .page(.recentlyDeleted), .page(.settings), .course, .policies, .item:
            tab = 0   // Coverage's stack takes it from here
        case .page(.horizon), .horizon:
            tab = 1   // the strip takes it from here
        case .page(.now):
            tab = 2; model.destination = nil
        case .page(.search), .search:
            tab = 3; model.destination = nil
        case .document(let id):
            model.destination = nil
            if let document = documents.first(where: { $0.id == id }) {
                preview = model.previewFile(for: document)
                if preview == nil { model.lastError = "\(document.displayName.sentenceStart) was read on another device; its file isn't here." }
            }
        case .importDocument(let choice):
            model.destination = nil
            switch choice {
            case .files: files = true
            case .photos: photos = .images
            case .screenshots: photos = .screenshots
            case .camera: scanning = true
            }
        }
    }
}

/// Search, the tab bar's search tab: the items, courses, policies and documents Spotlight finds for what is typed
/// (`SpotlightSearch`, by meaning where the device can), then those whose words match it (`HorizonSearch`), grouped by
/// kind under kickers, on the paper. Siri's "search Horizon for…" lands here with its words, a whole sentence at times.
/// Before anything is typed, the page suggests, as Siri Suggestions do: the block on now and the items most worth a look
/// (`SearchSuggestions`), the courses, and the searches the user ran last, or some worth trying while there are none.
struct SearchPage: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query private var policies: [Policy]
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The page a result opens: beside the results where there is room (iPhone Duo open, an iPad), else pushed over them.
    @State private var selection: Route?
    /// What that page has pushed over itself (an item from a course's page).
    @State private var path: [Route] = []
    @State private var preview: URL?
    @State private var finds = SpotlightFinds()

    /// A result's page, in place of whatever was open: once (a second tap while it is up changes nothing).
    private func open(_ route: Route) {
        guard selection != route || !path.isEmpty else { return }
        path = []
        selection = route
    }
    /// The result's page is the one open beside the results, or under what it opened there.
    private func isOpen(_ route: Route) -> Bool { sizeClass == .regular && selection == route }

    private var livePolicies: [PolicySnapshot] { policies.filter { $0.course != nil && $0.course?.deletedAt == nil }.map(PolicySnapshot.init) }

    private var results: HorizonSearch.Results {
        HorizonSearch.run(model.searchText, items: obligations.byDue.map(ObligationSnapshot.init), courses: courses.map(CourseSnapshot.init),
                          policies: livePolicies, documents: documents.map(DocumentSnapshot.init), spotlight: finds.ranking(for: model.searchText))
    }

    var body: some View {
        ListBesidePage(selection: $selection, path: $path) {
            List(selection: $selection) {
                if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestions
                } else {
                    found(results)
                }
            }
            .listStyle(.plain)
            .paper()
            .navigationTitle("Search")   // the field itself is the tab bar's (`MainTabs`), always in view on this tab
            .onAppear { SpotlightSearch.prepare() }
            .task(id: model.searchText) {   // a pause in the typing, then Spotlight's turn; the words' matching shows meanwhile
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = await SpotlightSearch.finds(for: model.searchText)
                if !Task.isCancelled { finds = found }
            }
        } aside: {
            PageAside()
        }
        .quickLookPreview($preview)
    }

    // MARK: Before anything is typed

    @ViewBuilder private var suggestions: some View {
        let now = Date()
        let suggested = SearchSuggestions.items(obligations.map(ObligationSnapshot.init), now: now, calendar: .current)
        let block = model.plan?.focus(at: now).current.flatMap { $0.asksWhenOver ? $0 : nil }   // work or study on now, not a meal
        let tries = model.recentSearches.isEmpty
            ? SearchSuggestions.queries(policies: livePolicies, items: obligations.map(ObligationSnapshot.init), documents: documents.map(DocumentSnapshot.init),
                                        now: now, calendar: .current)
            : []
        if block == nil, suggested.isEmpty, courses.isEmpty, model.recentSearches.isEmpty, tries.isEmpty {
            Text("Search your items, courses, policies and documents.")
                .font(.system(.body, design: .serif)).foregroundStyle(.secondary)
                .listRowSeparator(.hidden).onPaper().pageRow()
        }
        if block != nil || !suggested.isEmpty {
            Section {
                if let block { nowRow(block) }
                ForEach(suggested, id: \.id) { suggestion in
                    if let o = obligations.first(where: { $0.id == suggestion.id }) {
                        Button { open(.item(o.id)) } label: { ObligationRow(obligation: o, disclosure: true) }
                            .buttonStyle(.plain).onPaper(selected: isOpen(.item(o.id)))
                            .accessibilityHint(Self.why(suggestion.reason))
                    }
                }
            } header: { Kicker("Suggested") }.onPaper()
        }
        if !courses.isEmpty {
            Section { courseButtons } header: { Kicker("Courses") }.onPaper()
        }
        if !model.recentSearches.isEmpty {
            Section {
                ForEach(model.recentSearches, id: \.self) { words in
                    searchRow(words)
                        .swipeActions { Button("Remove", role: .destructive) { model.recentSearches.removeAll { $0 == words } } }
                }
            } header: {
                HStack {
                    Kicker("Recent")
                    Spacer()
                    Button("Clear") { withAnimation { model.recentSearches = [] } }.font(.caption).tint(Design.accentInk)
                }
            }
            .onPaper()
        } else if !tries.isEmpty {
            Section { ForEach(tries, id: \.self) { searchRow($0) } } header: { Kicker("Try Searching") }.onPaper()
        }
    }

    /// The plan's block on now, a tap from Now.
    private func nowRow(_ block: PlanBlock) -> some View {
        Button { model.navigate(to: .page(.now)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "clock").foregroundStyle(Design.accentInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.title).font(.body.weight(.medium)).lineLimit(2)
                    Text("On your plan now, until \(block.end.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onPaper()
    }

    /// Each course a button to its page, in the user's order, else by name: one row, scrolled sideways when they don't fit.
    private var courseButtons: some View {
        let ordered = courses.sorted { ($0.sortOrder ?? .max, $0.displayName.localizedLowercase) < ($1.sortOrder ?? .max, $1.displayName.localizedLowercase) }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ordered) { course in
                    Button { open(.course(course.id)) } label: { Text(course.displayName).lineLimit(1) }
                        .bordered().buttonBorderShape(.capsule)
                        .appEntityIdentifier(EntityIdentifier(for: CourseEntity.self, identifier: course.id))
                }
            }
            .padding(.horizontal, Design.margin)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))   // edge to edge, so the row scrolls under the margins
        .onPaper()
    }

    /// A search to run again, or one to try: its words go into the field.
    private func searchRow(_ words: String) -> some View {
        Button { model.searchText = words } label: {
            Label { Text(words).foregroundStyle(.primary) } icon: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onPaper()
    }

    /// What VoiceOver says of a suggestion: why it is there.
    static func why(_ reason: SearchSuggestions.Reason) -> String {
        switch reason {
        case .dueToday: "Due today."
        case .mattersMost: "Worth the most of what's due in the next two weeks."
        case .dueTomorrow: "Due tomorrow."
        case .toReview: "Waiting for your review."
        case .thisWeek: "Due this week."
        }
    }

    // MARK: What was found

    @ViewBuilder private func found(_ results: HorizonSearch.Results) -> some View {
        if results.isEmpty {
            Text("Nothing in Horizon matches “\(model.searchText)”.")
                .font(.system(.body, design: .serif)).foregroundStyle(.secondary)
                .listRowSeparator(.hidden).onPaper().pageRow()
        }
        if !results.items.isEmpty {
            Section {
                ForEach(results.items) { item in
                    if let o = obligations.first(where: { $0.id == item.id }) {
                        Button { model.rememberSearch(); open(.item(o.id)) } label: { ObligationRow(obligation: o, disclosure: true) }.buttonStyle(.plain).onPaper(selected: isOpen(.item(o.id)))
                    }
                }
            } header: { Kicker("Items") }.onPaper()
        }
        if !results.courses.isEmpty {
            Section {
                ForEach(results.courses) { course in
                    Button { model.rememberSearch(); open(.course(course.id)) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(course.displayName).font(.system(.headline, design: .serif))
                            if course.code != course.displayName, !course.code.isEmpty { Text(course.code).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appEntityIdentifier(EntityIdentifier(for: CourseEntity.self, identifier: course.id))
                    .onPaper(selected: isOpen(.course(course.id)))
                }
            } header: { Kicker("Courses") }.onPaper()
        }
        if !results.policies.isEmpty {
            Section {
                ForEach(results.policies) { policy in
                    Button { model.rememberSearch(); if let id = policy.courseID { open(.course(id)) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(PolicyLookup.name(policy.kind)) · \(policy.courseName ?? "")").font(.system(.headline, design: .serif))
                            Text(policy.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appEntityIdentifier(EntityIdentifier(for: PolicyEntity.self, identifier: policy.id))
                    .onPaper()
                }
            } header: { Kicker("Policies") }.onPaper()
        }
        if !results.documents.isEmpty {
            Section {
                ForEach(results.documents) { document in
                    Button {
                        model.rememberSearch()
                        if let d = documents.first(where: { $0.id == document.id }) { preview = model.previewFile(for: d) }
                    } label: {
                        Label { Text(document.displayName).font(.system(.headline, design: .serif)) } icon: { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appEntityIdentifier(EntityIdentifier(for: DocumentEntity.self, identifier: document.id))
                    .onPaper()
                }
            } header: { Kicker("Documents") }.onPaper()
        }
    }
}
#endif

#if os(macOS)
/// Search on a Mac: what matches the sidebar's field, by kind, on the paper. An item opens where it lives (Review, or
/// its course's page, selected), a course or a policy its course's page, a document Quick Look.
struct MacSearchPage: View {
    let nav: MacNavigation
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil }) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @Query(filter: #Predicate<SourceDocument> { $0.deletedAt == nil }) private var documents: [SourceDocument]
    @Query private var policies: [Policy]
    @State private var preview: URL?
    @State private var finds = SpotlightFinds()

    private var searchResults: HorizonSearch.Results {
        HorizonSearch.run(model.searchText, items: obligations.byDue.map(ObligationSnapshot.init), courses: courses.map(CourseSnapshot.init),
                          policies: policies.filter { $0.course != nil && $0.course?.deletedAt == nil }.map(PolicySnapshot.init),
                          documents: documents.map(DocumentSnapshot.init), spotlight: finds.ranking(for: model.searchText))
    }

    var body: some View {
        let results = searchResults
        List {
            if results.isEmpty {
                Text("Nothing in Horizon matches “\(model.searchText)”.").font(.system(.title3, design: .serif)).foregroundStyle(.secondary).onPaper().pageRow()
            }
            itemRows(results.items)
            courseRows(results.courses)
            policyRows(results.policies)
            documentRows(results.documents)
        }
        .listStyle(.plain)
        .paper()
        .navigationTitle("Search")
        .quickLookPreview($preview)
        .onAppear { SpotlightSearch.prepare() }
        .task(id: model.searchText) { await askSpotlight() }
    }

    @ViewBuilder private func itemRows(_ items: [ObligationSnapshot]) -> some View {
        if !items.isEmpty {
            Kicker("Items").onPaper().pageRow()
            ForEach(items) { item in
                Button { model.navigate(to: .item(item.id)) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(.headline, design: .serif))
                        Text(Design.itemLine(course: item.courseName, due: item.due, hasTime: item.dueHasTime, weight: item.pointsAtStake)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onPaper().pageRow()
                .appEntityIdentifier(EntityIdentifier(for: ItemEntity.self, identifier: item.id))
            }
        }
    }

    @ViewBuilder private func courseRows(_ found: [CourseSnapshot]) -> some View {
        if !found.isEmpty {
            Kicker("Courses").onPaper().pageRow()
            ForEach(found) { course in
                Button { nav.show(course: course.id) } label: {
                    Text(course.displayName).font(.system(.headline, design: .serif)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onPaper().pageRow()
                .appEntityIdentifier(EntityIdentifier(for: CourseEntity.self, identifier: course.id))
            }
        }
    }

    @ViewBuilder private func policyRows(_ found: [PolicySnapshot]) -> some View {
        if !found.isEmpty {
            Kicker("Policies").onPaper().pageRow()
            ForEach(found) { policy in
                Button { if let id = policy.courseID { nav.show(course: id) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(PolicyLookup.name(policy.kind)) · \(policy.courseName ?? "")").font(.system(.headline, design: .serif))
                        Text(policy.text).font(.body).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onPaper().pageRow()
                .appEntityIdentifier(EntityIdentifier(for: PolicyEntity.self, identifier: policy.id))
            }
        }
    }

    @ViewBuilder private func documentRows(_ found: [DocumentSnapshot]) -> some View {
        if !found.isEmpty {
            Kicker("Documents").onPaper().pageRow()
            ForEach(found) { document in
                Button { if let d = documents.first(where: { $0.id == document.id }) { preview = model.previewFile(for: d) } } label: {
                    Label { Text(document.displayName).font(.system(.headline, design: .serif)) } icon: { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onPaper().pageRow()
                .appEntityIdentifier(EntityIdentifier(for: DocumentEntity.self, identifier: document.id))
            }
        }
    }

    /// A pause in the typing, then Spotlight's turn; the words' own matching shows meanwhile.
    private func askSpotlight() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found = await SpotlightSearch.finds(for: model.searchText)
        if !Task.isCancelled { finds = found }
    }
}
#endif
