import SwiftUI
import SwiftData
import HorizonCore
import IngestKit

/// The one editor: corrects a parsed item from the review queue, edits any item on file, or enters one by hand (the
/// fallback the user asked for). Cancel leads, Save trails; unsaved changes ask before they are discarded (HIG sheets).
struct ObligationEditor: View {
    enum Mode { case review(Obligation), edit(Obligation), manual }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let courses: [Course]
    @Environment(\.dynamicTypeSize) private var typeSize
    /// For an item added by hand: the course whose page it was added from, chosen to begin with.
    var preferredCourse: UUID? = nil

    @State private var title = ""
    @State private var hasDate = true
    @State private var due = Date()
    @State private var hasTime = false
    @State private var courseID: UUID?
    @State private var componentName = ""
    @State private var platform: Platform = .syllabusOnly
    @State private var notes = ""
    @State private var done = false
    @State private var baseline: Fields?
    @State private var confirmingDelete = false

    /// Everything the form can change, for the unsaved-changes check.
    private struct Fields: Equatable { var title: String; var hasDate: Bool; var due: Date; var hasTime: Bool; var courseID: UUID?; var component: String; var platform: Platform; var notes: String; var done: Bool }
    private var fields: Fields { Fields(title: title, hasDate: hasDate, due: due, hasTime: hasTime, courseID: courseID, component: componentName, platform: platform, notes: notes, done: done) }
    private var isDirty: Bool { baseline.map { $0 != fields } ?? !title.isEmpty }

    private var course: Course? { courses.first { $0.id == courseID } }
    private var item: Obligation? { switch mode { case .review(let o), .edit(let o): o; case .manual: nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldRow(label: "Title", prompt: "Quiz 3", text: $title)
                    Picker("Course", selection: $courseID.animation()) {   // a course with a grade table brings its row in, animated
                        Text("None").tag(UUID?.none)
                        ForEach(courses) { Text($0.displayName).tag(UUID?.some($0.id)) }
                    }
                    .choosesInList(typeSize.isAccessibilitySize)
                    if let course, !course.gradeComponents.isEmpty {
                        Picker("Counts toward", selection: $componentName) {
                            Text("Not stated").tag("")
                            ForEach(course.gradeComponents, id: \.name) { Text($0.name).tag($0.name) }
                        }
                    }
                }
                if case .edit = mode {
                    Section {
                        Toggle("Done", isOn: $done)
                    } footer: {
                        Text("Checked off in Reminders as well.")
                    }
                }
                Section {
                    Toggle("Has a date", isOn: $hasDate.animation())   // the date's rows come and go with it, animated, not in one frame
                    if hasDate {
                        DatePicker("Due", selection: $due, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                        Toggle("At a specific time", isOn: $hasTime.animation())
                    }
                }
                Section {
                    Picker("Platform", selection: $platform) {
                        Text("Not stated").tag(Platform.syllabusOnly)
                        Text("LMS").tag(Platform.lms); Text("WebAssign").tag(Platform.webAssign)
                        Text("Gradescope").tag(Platform.gradescope); Text("MyLab").tag(Platform.myLab)
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if let item, item.origin == .document {
                    Section {
                        if let written = item.dateAsWritten, !written.isEmpty { LabeledContent("Date as written", value: written) }
                        // `sourcePage` is where the read's part began: page 1 for any document read whole, so only a later
                        // part's first page says anything ("from page 9").
                        if let doc = item.sourceDocument { LabeledContent("Source", value: (item.sourcePage ?? 0) > 0 ? "\(doc.displayName), from page \((item.sourcePage ?? 0) + 1)" : doc.displayName) }
                        if let note = item.changeNote { LabeledContent("Changed", value: note) }
                    } header: { Kicker("From the document") }
                }
                if item != nil {
                    Section {
                        Button("Delete Item", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Deleting removes it from Reminders as well.")
                    }
                }
            }
            .paper()
            .editorChrome(title: isManual ? "Add Item" : "Edit Item", confirm: "Save", disabled: title.trimmingCharacters(in: .whitespaces).isEmpty || !isDirty,
                          dirty: isDirty, cancel: { dismiss() }, action: save)
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Delete “\(title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let item { Task { await model.discard(item.id); dismiss() } } }
            } message: {
                Text("It is removed from Reminders as well.")
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 680, minHeight: 420, idealHeight: 560, maxHeight: 720)
        #endif
    }

    private var isManual: Bool { if case .manual = mode { true } else { false } }

    private func load() {
        defer { baseline = isManual ? nil : fields }
        guard let item else { courseID = preferredCourse ?? (courses.count == 1 ? courses[0].id : nil); return }
        title = item.title
        hasDate = item.due != nil
        due = item.due ?? Date()
        hasTime = item.dueHasTime
        courseID = item.course?.id
        componentName = item.componentName ?? ""
        platform = item.platform
        notes = item.notes ?? ""
        done = item.completedAt != nil
    }

    private func save() {
        let dueValue: Date? = hasDate ? (hasTime ? due : Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: due)) : nil
        let model = model
        // Everything is read from the sheet before it goes; then the sheet goes at once, and the save (with the sync
        // after it) runs without holding it up.
        let work: @MainActor () async -> Void
        switch mode {
        case .manual:
            let (title, hasTime, courseID, component, platform, notes) = (title, hasTime, courseID, componentName.isEmpty ? nil : componentName, platform, notes.isEmpty ? nil : notes)
            work = { await model.addManual(title: title, due: dueValue, dueHasTime: hasTime, courseID: courseID, componentName: component, platform: platform, notes: notes) }
        case .review(let item), .edit(let item):
            var edits = ObligationEdits()
            if title != item.title { edits.title = title }
            if dueValue != item.due || hasTime != item.dueHasTime { edits.due = .some(dueValue); edits.dueHasTime = hasTime }
            if platform != item.platform { edits.platform = platform }
            if componentName != (item.componentName ?? "") { edits.componentName = .some(componentName.isEmpty ? nil : componentName) }
            if notes != (item.notes ?? "") { edits.notes = .some(notes.isEmpty ? nil : notes) }
            if courseID != item.course?.id { edits.courseID = .some(courseID) }
            let (id, done, checked) = (item.id, done, done != (item.completedAt != nil))
            work = {
                if checked { await model.setCompleted(id, done) }
                if !checked || edits != ObligationEdits() { await model.confirm(id, edits: edits) }   // a check alone confirms nothing and edits nothing
            }
        }
        dismiss()
        Task { await work() }
    }
}
