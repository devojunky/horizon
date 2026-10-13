import AppIntents
import Foundation
import HorizonCore
import IngestKit

// Items through Siri's reminders schema: add one ("add the lab report to Bio for Friday") or a numbered run of them ("for
// Calc, a quiz every Thursday at 4 until the midterm"), change one ("push this to Sunday", "mark it done", "move it to
// Biology", "confirm it"), delete some. Schema intents are the only actions Siri itself can take (WWDC26 "Build
// intelligent Siri experiences with App Schemas"); they also stand in Shortcuts and Spotlight. Where Horizon needs more
// than a schema carries (the item a run stops before, the number it starts at, a review's answer) the schema intent
// takes a few optional parameters of its own: one action per verb, as Apple's own apps have it (Mail's Update Message
// sets read, flagged, junk and mailbox at once), never a second action for a variant. Added items are the manual
// fallback (`Origin.manual`, SPEC §2's exception): a lecture's announcement, given in one breath, which no document will
// print.

/// Add an item: one, or a numbered run of them when it repeats.
@AppIntent(schema: .reminders.createReminder)
struct AddItemIntent {
    static let description = IntentDescription("Adds an item with its due date to a course, and to Reminders. One that repeats becomes numbered items (Quiz 4, Quiz 5…), one per date, skipping the course's breaks, up to the item it runs until or the end of the term.",
                                               categoryName: "Items", searchKeywords: ["assignment", "homework", "quiz", "task", "deadline", "every week", "weekly", "repeat"])

    var title: String
    var list: CourseEntity?
    var note: AttributedString?
    var isFlagged: Bool?
    // Empty unless given: Horizon's items carry no pictures, tags or links of their own, and Siri must never ask for them.
    @Parameter(title: "Images", default: [], supportedContentTypes: [.image]) var images: [IntentFile]
    @Parameter(default: []) var tags: Set<String>
    @Parameter(default: []) var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var locationTrigger: PlaceTriggerEntity?
    var section: GradeRowEntity?
    // Horizon's own, for a run. Siri gives a repeat as `recurrence`; a shortcut can name the weekday instead.
    @Parameter(title: "Every", description: "Makes a weekly run on this day of the week, numbered, as a repeat does.") var every: WeekdayChoice?
    @Parameter(title: "Until", description: "For a run: the item whose day it stops before (say, the midterm).") var until: ItemEntity?
    @Parameter(title: "First Number", description: "For a run: the number the first one takes. By default, the one after the highest of that name in the course.") var firstNumber: Int?

    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some ReturnsValue<ItemEntity> & ProvidesDialog {
        try model.requireLibrary()
        if locationTrigger != nil { throw IntentFailure.message("Horizon's items are due at a time, not at a place. Reminders can remind you at a place.") }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw $title.needsValueError("What's it called?") }
        let courseID = section.map(\.list.id) ?? list.flatMap { $0.isUnfiled ? nil : $0.id }
        let course = try await model.intentCourse(courseID)
        guard courseID == nil || course != nil else { throw IntentFailure.message("That course is no longer in Horizon.") }
        let calendar = Calendar.current
        let due = dueDate.flatMap { ItemSeries.due(from: $0, now: .now, calendar: calendar) }
        let notes = note.map { String($0.characters) }.flatMap { $0.isEmpty ? nil : $0 }

        if let rule = recurrence ?? every.map({ Calendar.RecurrenceRule.weekly(calendar: calendar, weekdays: [.every($0.locale)]) }) {
            // The first date: the one given, else (a weekday named alone) the run starts today, with no time.
            let start = due ?? (every != nil ? (calendar.date(bySettingHour: 23, minute: 59, second: 0, of: .now).map { (date: $0, hasTime: false) }) : nil)
            guard let start else { throw $dueDate.needsValueError("When is the first one due?") }
            var end = recurrence?.end.date, endIsItem = false
            if let until {
                guard let day = try await model.intentItem(until.id).due else { throw IntentFailure.message("\(until.title) has no date yet, so the run has nowhere to stop.") }
                end = day; endIsItem = true
            }
            let plan = try await SeriesPlan.make(stem: name, rule: rule, first: start.date, hasTime: start.hasTime, end: end, endIsItem: endIsItem,
                                                 course: course, row: section?.name, firstNumber: firstNumber, model: model)
            try await plan.confirm(with: self)
            let added = try await model.addItems(plan.items, courseID: course?.id, componentName: plan.row, notes: notes)
            guard let first = added.first else { throw IntentFailure.message("No date in that rhythm falls before it ends.") }
            return .result(value: ItemEntity(first, course: course), dialog: "\(plan.summary(added: true))")
        }

        let row = section?.name ?? course.flatMap { ItemSeries.component(for: ItemSeries.stem(of: name).stem, in: $0.gradeComponents) }
        let added = try await model.addItems([ItemSeries.Item(title: name, due: due?.date ?? .distantPast, dueHasTime: due?.hasTime ?? false)], courseID: course?.id,
                                             componentName: row, notes: notes, undated: due == nil)
        guard let item = added.first else { throw IntentFailure.message("Horizon could not add it.") }
        let place = course.map { " to \($0.displayName)" } ?? ""
        let when = due == nil ? ", with no date yet" : ", due " + Spoken.due(item.due, hasTime: item.dueHasTime)
        return .result(value: ItemEntity(item, course: course), dialog: "Added \(item.title)\(place)\(when).")
    }
}

/// A day of the week, as Shortcuts' picker and Siri name it.
enum WeekdayChoice: String, AppEnum {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Day of the Week"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .monday: "Monday", .tuesday: "Tuesday", .wednesday: "Wednesday", .thursday: "Thursday", .friday: "Friday", .saturday: "Saturday", .sunday: "Sunday",
    ]
    var locale: Locale.Weekday {
        switch self {
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        case .sunday: .sunday
        }
    }
}

/// A numbered run worked out and said back before anything is added: the dates the rhythm gives (breaks left out), the
/// names, the grade row the name falls under, and one sentence for the confirmation and the result.
struct SeriesPlan {
    var items: [ItemSeries.Item]
    var row: String?
    var courseName: String?
    var skipped: Int

    @MainActor static func make(stem raw: String, rule: Calendar.RecurrenceRule, first: Date, hasTime: Bool, end: Date?, endIsItem: Bool, course: CourseSnapshot?,
                                row: String?, firstNumber: Int? = nil, model: AppModel) async throws -> SeriesPlan {
        let calendar = Calendar.current
        let parsed = ItemSeries.stem(of: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let stem = parsed.stem.isEmpty ? raw : parsed.stem
        let titles = try await model.intentItems().0.filter { $0.courseID == course?.id }.map(\.title)
        let number = firstNumber ?? parsed.number ?? ItemSeries.nextNumber(for: stem, existing: titles)
        // An item's day ends the run before it ("until the midterm"); a date the user names is the last it may fall on;
        // with neither, the term's end, else fifteen weeks: the confirmation says which.
        let stop: Date = if let end { endIsItem ? ItemSeries.end(beforeDayOf: end, calendar: calendar) : ItemSeries.end(throughDay: end, calendar: calendar) }
                         else if let termEnd = course?.termEnd { ItemSeries.end(throughDay: termEnd, calendar: calendar) }
                         else { calendar.date(byAdding: .weekOfYear, value: 15, to: first) ?? first }
        let closed = course?.noClassDates ?? []
        let all = ItemSeries.dates(rule: rule, start: first, end: stop, skipping: [], calendar: calendar)
        let dates = ItemSeries.dates(rule: rule, start: first, end: stop, skipping: closed, calendar: calendar)
        let items = ItemSeries.items(stem: stem, first: number, dates: dates, hasTime: hasTime)
        guard !items.isEmpty else { throw IntentFailure.message("No date in that rhythm falls before \(Spoken.due(stop, hasTime: false)).") }
        return SeriesPlan(items: items, row: row ?? course.flatMap { ItemSeries.component(for: stem, in: $0.gradeComponents) }, courseName: course?.displayName,
                          skipped: max(0, all.count - dates.count))
    }

    /// "Quiz 4 to Quiz 9 in Calculus II, Thursdays at 4 PM from October 8 to November 12, skipping one break."
    func summary(added: Bool) -> String {
        guard let first = items.first, let last = items.last else { return "" }
        let names = items.count == 1 ? first.title : "\(first.title) to \(last.title)"
        let place = courseName.map { " in \($0)" } ?? ""
        let day = first.due.formatted(.dateTime.weekday(.wide))
        let time = first.dueHasTime ? " at " + first.due.formatted(date: .omitted, time: .shortened) : ""
        let span = items.count == 1 ? "on \(first.due.formatted(.dateTime.month(.wide).day()))"
                                    : "from \(first.due.formatted(.dateTime.month(.wide).day())) to \(last.due.formatted(.dateTime.month(.wide).day()))"
        let skips = skipped == 0 ? "" : ", skipping \(Spoken.count(skipped, "break week"))"
        let lead = added ? "Added \(names)" : "Add \(names)"
        return "\(lead)\(place), \(day)s\(time) \(span)\(skips)" + (added ? "." : "?")
    }

    /// More than one item is asked about before anything is written: they all reach Reminders.
    func confirm(with intent: some AppIntent) async throws {
        guard items.count > 1 else { return }
        try await intent.requestConfirmation(actionName: .add, dialog: IntentDialog(stringLiteral: summary(added: false)))
    }
}

/// Change an item: rename it, move its date, check it off, move it to another course, edit its notes, or answer its
/// review (Review's Confirm and "Use <the other date>").
@AppIntent(schema: .reminders.updateReminder)
struct ChangeItemIntent {
    static let description = IntentDescription("Changes an item: its name, due date, notes or course, whether it's done, or, for one waiting for review, confirms it as read or takes the date a later document gave it. A change by hand stays when a document is read again.",
                                               categoryName: "Items", searchKeywords: ["reschedule", "move", "rename", "done", "complete", "confirm", "review"])

    var target: ItemEntity
    var title: String?
    var note: AttributedString?
    var tags: Set<String>?
    var urls: [URL]?
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool?
    var isFlagged: Bool?
    var list: CourseEntity?
    var locationTrigger: PlaceTriggerEntity?
    @Parameter(title: "Review", description: "For an item waiting for review: confirm it as read, or use the date a later document gave it.") var review: ReviewAnswer?

    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some ReturnsValue<ItemEntity> & ProvidesDialog {
        try model.requireLibrary()
        if case .set(let trigger) = $locationTrigger.valueState, trigger != nil { throw IntentFailure.message("Horizon's items are due at a time, not at a place.") }
        if case .set(let rule) = $recurrence.valueState, rule != nil {
            throw IntentFailure.message("A Horizon item is due once. To add one every week, ask to add it with the day it repeats on.")
        }
        let before = try await model.intentItem(target.id)
        var edits = ObligationEdits()
        var said: [String] = []
        if case .set(let value) = $title.valueState, let value, !value.trimmingCharacters(in: .whitespaces).isEmpty, value != before.title {
            edits.title = value.trimmingCharacters(in: .whitespacesAndNewlines); said.append("renamed it \(edits.title!)")
        }
        if case .set(let value) = $dueDate.valueState {
            if let value {
                guard let due = ItemSeries.due(from: value, now: .now, calendar: .current) else { throw IntentFailure.message("Horizon could not read that date.") }
                edits.due = .some(due.date); edits.dueHasTime = due.hasTime
                said.append("moved it to " + Spoken.due(due.date, hasTime: due.hasTime))
            } else {
                edits.due = .some(nil); said.append("took its date away")
            }
        } else if review == .useOtherDate {
            // A date named outright wins over the other one.
            guard let other = before.otherDate else { throw IntentFailure.message("\(before.title) has only one date.") }
            edits.due = .some(other)
            said.append("gave it the other date, " + Spoken.due(other, hasTime: before.dueHasTime))
        }
        if case .set(let value) = $note.valueState {
            let text = value.map { String($0.characters) }.flatMap { $0.isEmpty ? nil : $0 }
            edits.notes = .some(text); said.append(text == nil ? "cleared its notes" : "changed its notes")
        }
        if case .set(let value) = $list.valueState, let value {
            let id: UUID? = value.isUnfiled ? nil : value.id
            if id != before.courseID {
                if let id, try await model.store.course(id: id) == nil { throw IntentFailure.message("That course is no longer in Horizon.") }
                edits.courseID = .some(id); said.append(id == nil ? "took it out of its course" : "moved it to \(value.name)")
            }
        }
        // Any edit confirms an item in review, as the editor's Save does; a review answered alone confirms it as it stands.
        let inReview = before.state == .pendingReview
        if review == .confirm, inReview, edits == ObligationEdits() { said.append("confirmed it") }
        let confirming = edits != ObligationEdits() || (review != nil && inReview)
        let done: Bool? = if case .set(let value) = $isCompleted.valueState { value } else { nil }
        try await model.changeItem(target.id, edits: confirming ? edits : nil, done: done)
        if let done, done != (before.completedAt != nil) { said.append(done ? "checked it off" : "put it back on your list") }
        if review != nil, !inReview, said.isEmpty { return .result(value: try await model.itemEntity(target.id), dialog: "\(before.title) isn't waiting for review.") }
        let after = try await model.itemEntity(target.id)
        let sentence = said.isEmpty ? "\(after.title) is unchanged." : "\(after.title): " + Spoken.list(said) + "."
        return .result(value: after, dialog: "\(sentence.sentenceStart)")
    }
}

/// Review's answers to an item Horizon wanted checked.
enum ReviewAnswer: String, AppEnum {
    case confirm, useOtherDate
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Review"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .confirm: DisplayRepresentation(title: "Confirm as Read", synonyms: ["confirm", "approve", "looks right", "accept"]),
        .useOtherDate: DisplayRepresentation(title: "Use the Other Date", synonyms: ["the other date", "the new date", "the later date"]),
    ]
}

/// Delete items. Items do not wait in Recently Deleted; the deletion can be undone, as it can in the app.
@AppIntent(schema: .reminders.deleteReminders)
struct DeleteItemsIntent: DeleteIntent, UndoableIntent {
    static let description = IntentDescription("Deletes items, and their reminders. Undo puts them back.", categoryName: "Items")

    var entities: [ItemEntity]

    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try model.requireLibrary()
        let ids = entities.map(\.id)
        try await model.deleteItems(ids)
        undoManager?.registerUndo(withTarget: model) { model in Task { @MainActor in try? await model.restoreItems(ids) } }
        undoManager?.setActionName(ids.count == 1 ? "Delete Item" : "Delete Items")
        let names = entities.map(\.title)
        return .result(dialog: "\(names.count == 1 ? "Deleted \(names[0])." : "Deleted \(Spoken.count(names.count, "item")).")")
    }
}

/// Add a course by hand, ahead of its documents: its syllabus, read later, fills it in.
@AppIntent(schema: .reminders.createList)
struct AddCourseIntent {
    static let description = IntentDescription("Adds a course by name. Reading its syllabus later fills in the rest.", categoryName: "Courses")

    var type: CourseListType
    var name: String

    @Dependency var model: AppModel

    @MainActor func perform() async throws -> some ReturnsValue<CourseEntity> & ProvidesDialog {
        try model.requireLibrary()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw $name.needsValueError("What's the course called?") }
        if let existing = try await model.intentCourses().first(where: { CourseMatch.score(title, name: $0.title, code: $0.code) >= 0.95 }) {
            return .result(value: CourseEntity(existing), dialog: "\(existing.displayName) is already in Horizon.")
        }
        let course = try await model.addCourseFromIntent(title: title)
        return .result(value: CourseEntity(course), dialog: "Added \(course.displayName). Share its syllabus with Horizon to fill in its work and grades.")
    }
}

extension AppModel {
    /// Items added from an intent: each a manual item (`Origin.manual`), then one sync for them all.
    func addItems(_ items: [ItemSeries.Item], courseID: UUID?, componentName: String?, notes: String?, undated: Bool = false) async throws -> [ObligationSnapshot] {
        try requireLibrary()
        var added: [ObligationSnapshot] = []
        for item in items {
            added.append(try await store.addManual(title: item.title, due: undated ? nil : item.due, dueHasTime: item.dueHasTime, courseID: courseID,
                                                   componentName: componentName, notes: notes, deviceName: Self.deviceName))
        }
        Self.log("intent: added \(added.count) item(s)")
        await drainAndSync()
        return added
    }

    /// An item changed from an intent: the edits as the editor's Save makes them (each a hand edit the documents leave
    /// alone, and a review item confirmed; empty edits confirm it as it stands), and its check as the ring makes it.
    func changeItem(_ id: UUID, edits: ObligationEdits?, done: Bool?) async throws {
        try requireLibrary()
        if let edits { try await store.confirm(id: id, edits: edits) }
        if let done { try await store.setCompleted(id: id, done) }
        changedElsewhere = ChangedItems(ids: [id])
        if edits != nil { await drainAndSync() }
        else if done != nil, remindersAuthorized == true { remindersListGone = (try? await sync.sync().listGone) ?? remindersListGone }
    }

    /// Items deleted from an intent; `restoreItems` puts them back.
    func deleteItems(_ ids: [UUID]) async throws {
        try requireLibrary()
        for id in ids { try await store.softDelete(id: id) }
        changedElsewhere = ChangedItems(ids: Set(ids))
        await drainAndSync()
    }

    func restoreItems(_ ids: [UUID]) async throws {
        for id in ids { try await store.undelete(id: id) }
        await drainAndSync()
    }

    func addCourseFromIntent(title: String) async throws -> CourseSnapshot {
        try requireLibrary()
        return try await store.addCourse(CourseEdits(title: title))
    }

    #if DEBUG
    /// The course SiriOnDeviceTests adds a weekly run to (`--seed-siri-test`, cleared by `--clear-siri-test`).
    static let siriTestCourse = "Siri Test"

    /// "Siri Test" with an exam on the Thursday five weeks ahead: a run every Thursday "until the exam" must stop the week before.
    func seedSiriTest() async {
        let calendar = Calendar.current
        guard let thursday = calendar.nextDate(after: .now, matching: DateComponents(weekday: 5), matchingPolicy: .nextTime),
              let examDay = calendar.date(byAdding: .day, value: 35, to: thursday),
              let due = ItemSeries.due(from: calendar.dateComponents([.year, .month, .day], from: examDay), now: .now, calendar: calendar),
              let course = try? await addCourseFromIntent(title: Self.siriTestCourse) else { return }
        _ = try? await addItems([ItemSeries.Item(title: "Exam", due: due.date, dueHasTime: due.hasTime)], courseID: course.id, componentName: nil, notes: nil)
    }
    #endif
}
