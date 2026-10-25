import SwiftUI
import SwiftData
import QuickLook
import AppIntents
import HorizonCore
import IngestKit

#if os(iOS)
/// An item's page: a row tapped on any page, a reminder's link, Spotlight, Siri's Open Item. Its masthead (the course,
/// the name, the date, how soon and what it is worth, or that it is done or skipped), then Mark Done and Skip where the
/// thumb reaches them, then the description at the width of the page (what Siri writes, with the item's notes from
/// Reminders), then where it came from. Edit is in the bar, as Calendar's event details have it (HIG: a text button for
/// an action no symbol says), and opens the editor as a sheet, as the row once did.
struct ItemDetail: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    // Through a query, not a row handed over: the store saves from a context of its own, and only a query redraws for
    // that (a check, a skip, Siri's change, a sync).
    @Query private var found: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var editing: Editing?
    @State private var preview: URL?     // the document it was read from, in Quick Look
    /// The masthead's name has gone under the navigation bar, which then shows it (`nameHeight`: how far the page
    /// scrolls before it has), as a course's page does.
    @State private var nameUnderBar = false
    @State private var nameHeight: CGFloat = 40
    @State private var pageWidth: CGFloat = 0
    @State private var completed = 0     // the haptics answer the user's press, not a check arriving from Reminders
    @State private var changed = 0

    init(id: UUID) {
        self.id = id
        _found = Query(filter: #Predicate<Obligation> { $0.id == id })
    }

    /// The editor asked for, and whether it opens on the description (Add Description…). One value: a second state read
    /// by the sheet's content was the one from before the tap.
    private struct Editing: Identifiable {
        let item: Obligation
        var describing = false
        var id: UUID { item.id }
    }

    private var item: Obligation? { found.first.flatMap { $0.deletedAt == nil ? $0 : nil } }

    var body: some View {
        Group {
            if let item { page(item) } else {
                List {
                    EditorialEmpty(title: "Not in Horizon any more.", deck: "This item was deleted, here or in Reminders.") { EmptyView() }
                        .listRowSeparator(.hidden).onPaper()
                }
                .listStyle(.plain)
                .paper()
            }
        }
        .onChange(of: item == nil) { _, gone in if gone { dismiss() } }   // deleted while open (the editor's Delete Item, Siri, Reminders): the page goes with it
    }

    private func page(_ item: Obligation) -> some View {
        let done = item.completedAt != nil && item.skippedAt == nil
        let inReview = item.state == .pendingReview && item.completedAt == nil   // done needs no review
        return List {
            masthead(item)
            actions(item, done: done, skipped: item.skippedAt != nil)
            if inReview { review(item) }
            description(item)
            details(item)
        }
        .listStyle(.plain)
        .paper()
        .animation(.default, value: inReview)   // confirmed here: the review's section leaves animated, the rest close up
        .sensoryFeedback(.success, trigger: completed)
        .sensoryFeedback(.selection, trigger: changed)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > nameHeight + 24 } action: { _, under in nameUnderBar = under }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .navigationTitle(item.title)   // for the back button's menu and the system; the bar shows its own once the masthead's has gone
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(item.title).font(.system(.headline, design: .serif)).lineLimit(1)
                    .frame(maxWidth: max(pageWidth > 0 ? pageWidth - 2 * 80 : .infinity, 0))   // the room it has centred between Back and Edit
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .opacity(nameUnderBar ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: nameUnderBar)
                    .accessibilityHidden(!nameUnderBar)   // the masthead is the page's heading while it shows
            }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = Editing(item: item) } }
        }
        .sheet(item: $editing) { asked in
            ObligationEditor(mode: asked.item.state == .pendingReview ? .review(asked.item) : .edit(asked.item), courses: courses, focusesDescription: asked.describing)
        }
        .quickLookPreview($preview)
        .showsEntity(ItemEntity.self, id: item.id, title: item.title)   // Siri's "this": "add a note to this", "push this to Sunday"
        .onAppear { if MainTabs.debugOnce("--edit-item") { editing = Editing(item: item) } }
    }

    // MARK: The head

    /// The course as its kicker, the name whole, the date, then one quiet line: how soon (or that it is done, or
    /// skipped) and its share of the grade. The line's words change in place, never its height.
    private func masthead(_ item: Obligation) -> some View {
        let now = Date()
        let line = Self.figures(item, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            if let course = item.course?.displayName, !course.isEmpty { Kicker(course) }
            Text(item.title).display().fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameHeight = $0 }
            Text(Self.date(item, now: now)).font(.system(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(item.due == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if !line.text.isEmpty {
                ZStack(alignment: .leading) {   // one place: a new state fades through the old, never over it
                    Text(line.text).id(line.text).transition(.fadeThrough)
                }
                .font(.subheadline).foregroundStyle(line.urgent ? Design.accentInk : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: Design.margin, bottom: 14, trailing: Design.margin))
        .onPaper()
    }

    /// Mark Done, the likely act, prominent; Skip beside it, the same size (HIG: tell a preferred action by its style, not
    /// its size). Done, the first takes the check back; skipped, the second takes the skip back. Side by side while
    /// both labels fit, one above the other at the largest sizes.
    private func actions(_ item: Obligation, done: Bool, skipped: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            EqualWidths(spacing: 12) { actionButtons(item, done: done, skipped: skipped, whole: true) }
            VStack(spacing: 10) { actionButtons(item, done: done, skipped: skipped, whole: false) }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .lineLimit(1)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: Design.margin, bottom: 18, trailing: Design.margin))
        .onPaper()
    }

    /// Done: the check taken back, alone across the row (a pair wider than the row would stack, and the page jump as an
    /// item is checked off; Skip for a done item is in its row's swipe and menu). Otherwise Mark Done, and Skip or Undo Skip.
    /// Always the words with the symbol: the automatic label style drops the words where room is short, so at the largest
    /// sizes the pair measured as two symbols, stayed side by side, and showed "✓ …". `whole`: each label at its full
    /// width, the honest measure for the pair; stacked, a label too wide for the row shrinks a little rather than lose words.
    @ViewBuilder private func actionButtons(_ item: Obligation, done: Bool, skipped: Bool, whole: Bool) -> some View {
        let mark = {
            if done { changed += 1 } else { completed += 1 }
            Task { await model.setCompleted(item.id, !done) }
        }
        if done {
            Button(action: mark) {
                actionLabel(ItemActions.markTitle(done: true), ItemActions.markImage(done: true), whole: whole)
                    .foregroundStyle(.primary)   // its symbol too: left to the tint, it took the app's amber beside black words
            }
            .buttonStyle(.bordered).tint(.primary)
        } else {
            Button(action: mark) {
                actionLabel(ItemActions.markTitle(done: false), ItemActions.markImage(done: false), whole: whole)
            }
            .prominent()
            Button {
                changed += 1
                Task { await model.setSkipped(item.id, !skipped) }
            } label: {
                actionLabel(ItemActions.skipTitle(skipped: skipped), ItemActions.skipImage(skipped: skipped), whole: whole)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.bordered).tint(.primary)
            .accessibilityHint(skipped ? "Puts it back on your list." : "Takes it off your list without marking it done.")
        }
    }

    @ViewBuilder private func actionLabel(_ title: String, _ image: String, whole: Bool) -> some View {
        if whole {
            Label(title, systemImage: image).labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: image).labelStyle(.titleAndIcon).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
        }
    }

    /// An item the reader was unsure of: why, and Review's answers (Confirm as read, or the date a later document gave it).
    private func review(_ item: Obligation) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.reviewReason).font(.subheadline).foregroundStyle(item.changeNote == nil ? .secondary : Design.accentInk)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Confirm", systemImage: "checkmark") { changed += 1; Task { await model.confirm(item.id) } }
                        .buttonStyle(.bordered).tint(Design.accentInk).reachable()
                    if let other = item.otherDate {
                        Button("Use \(other.formatted(.dateTime.month(.abbreviated).day()))") {
                            changed += 1; Task { await model.confirm(item.id, edits: ObligationEdits(due: .some(other))) }
                        }
                        .buttonStyle(.bordered).reachable()
                    }
                }
                .controlSize(.small)
                .lineLimit(1)
            }
            .padding(.vertical, 4)
        } header: { Kicker("Waiting for your review", accent: true) }
        .listRowSeparator(.hidden)
        .onPaper()
        .transition(.opacity)
    }

    // MARK: The description

    /// What the item asks for, in its own words: the page's widest block, a body's size with room between the lines,
    /// selectable, its links live, never cut short. Siri writes it ("add a note to this…"), the editor and Reminders
    /// too; what came through Siri says so (HIG: disclose what a model may have written, and keep Edit near it).
    private func description(_ item: Obligation) -> some View {
        Section {
            if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.linked(notes))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)   // a reading measure, should the page ever be wide
                    if item.notesFromSiri {
                        Text("Added with Siri, which can make mistakes.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No description yet.").foregroundStyle(.secondary)
                    Text("Ask Siri, “Add a note to this,” while this page is open, or write one yourself.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Add Description…") { editing = Editing(item: item, describing: true) }.buttonStyle(.borderless).padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
        } header: { Kicker("Description") }
        .listRowSeparator(.hidden)
        .onPaper()
    }

    // MARK: Where it came from

    /// The rest, each on a line of its own and only when there is something to say: the grade row it counts toward,
    /// the site it is handed in on, the document it was read from (opened in Quick Look), the date as the document
    /// printed it, and what a later read changed.
    @ViewBuilder private func details(_ item: Obligation) -> some View {
        let row = item.componentName.flatMap { name in item.course?.gradeComponents.first { $0.name == name } }
        let document = item.origin == .document ? item.sourceDocument : nil
        let written = item.dateAsWritten.flatMap { $0.isEmpty ? nil : $0 }
        if item.componentName != nil || item.platform != .syllabusOnly || document != nil || written != nil || item.changeNote != nil {
            Section {
                if let name = item.componentName {
                    LabeledContent("Counts toward") {
                        Text(row?.weight.map { "\(name) · \(($0 * 100).formatted(.number.precision(.fractionLength(0...1))))% of the grade" } ?? name)
                    }
                }
                if item.platform != .syllabusOnly { LabeledContent("Site", value: Coverage.platformName(item.platform)) }
                if let document {
                    // `sourcePage` is where the read's part began: page 1 for any document read whole, so only a later
                    // part's first page says anything ("from page 9").
                    let name = (item.sourcePage ?? 0) > 0 ? "\(document.displayName), from page \((item.sourcePage ?? 0) + 1)" : document.displayName
                    if model.hasFile(document) {
                        Button { preview = model.previewFile(for: document) } label: {
                            LabeledContent("Source") {
                                HStack(spacing: 6) {
                                    Text(name).multilineTextAlignment(.trailing)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the document")
                    } else {
                        LabeledContent("Source", value: name)
                    }
                }
                if let written { LabeledContent("Date as written", value: "“\(written)”") }
                if let note = item.changeNote { LabeledContent("Changed", value: note) }
            } header: { Kicker("Details") }
            .onPaper()
        }
    }

    // MARK: Words

    /// "Thursday, October 16 at 11:59 PM", or the day alone when no time was given; the year only when it is not this one.
    static func date(_ item: Obligation, now: Date, calendar: Calendar = .current) -> String {
        guard let due = item.due else { return "No date yet" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: due) != calendar.component(.year, from: now) { style = style.year() }
        if item.dueHasTime { style = style.hour().minute() }
        return due.formatted(style)
    }

    /// The masthead's quiet line: how soon it is (or when it was done or skipped), and its share of the grade. Urgent
    /// (the accent's words) when it is still to do and its moment has passed.
    static func figures(_ item: Obligation, now: Date, calendar: Calendar = .current) -> (text: String, urgent: Bool) {
        var parts: [String] = []
        var urgent = false
        if let closed = item.completedAt {
            parts.append("\(item.skippedAt != nil ? "Skipped" : "Done") \(day(closed, now: now, calendar: calendar))")
        } else if let due = item.due {
            parts.append(soon(due, hasTime: item.dueHasTime, now: now, calendar: calendar))
            urgent = due < now
        }
        if let points = item.pointsAtStake { parts.append("\(points.formatted(.number.precision(.fractionLength(0...1))))% of the grade") }
        return (parts.joined(separator: " · "), urgent)
    }

    /// "Today", "Tomorrow", "In 3 days", "Yesterday", "4 days ago": by the calendar's days, so an item due at 23:59
    /// tomorrow is tomorrow, not "in 1 day" at breakfast.
    static func soon(_ due: Date, hasTime: Bool, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return hasTime && due < now ? "Earlier today" : "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...: return "In \(days) days"
        default: return "\(-days) days ago"
        }
    }

    /// When something was done: "today", "yesterday", else "on Monday, October 13".
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return "on " + date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// The description with its web addresses live (Siri's often carry one: where to hand it in, the reading).
    static func linked(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}
#endif
