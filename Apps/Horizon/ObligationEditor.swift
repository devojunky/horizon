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

    @State private var title = ""
    @State private var hasDate = true
    @State private var due = Date()
    @State private var hasTime = false
    @State private var courseID: UUID?
    @State private var componentName = ""
    @State private var platform: Platform = .syllabusOnly
    @State private var notes = ""
    @State private var baseline: Fields?
    @State private var confirmingDiscard = false
    @State private var confirmingDelete = false

    /// Everything the form can change, for the unsaved-changes check.
    private struct Fields: Equatable { var title: String; var hasDate: Bool; var due: Date; var hasTime: Bool; var courseID: UUID?; var component: String; var platform: Platform; var notes: String }
    private var fields: Fields { Fields(title: title, hasDate: hasDate, due: due, hasTime: hasTime, courseID: courseID, component: componentName, platform: platform, notes: notes) }
    private var isDirty: Bool { baseline.map { $0 != fields } ?? !title.isEmpty }

    private var course: Course? { courses.first { $0.id == courseID } }
    private var item: Obligation? { switch mode { case .review(let o), .edit(let o): o; case .manual: nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Title") { TextField("Quiz 3", text: $title).multilineTextAlignment(.trailing) }
                    Picker("Course", selection: $courseID) {
                        Text("None").tag(UUID?.none)
                        ForEach(courses) { Text($0.displayName).tag(UUID?.some($0.id)) }
                    }
                    if let course, !course.gradeComponents.isEmpty {
                        Picker("Counts toward", selection: $componentName) {
                            Text("Not stated").tag("")
                            ForEach(course.gradeComponents, id: \.name) { Text($0.name).tag($0.name) }
                        }
                    }
                }
                Section {
                    Toggle("Has a date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Due", selection: $due, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                        Toggle("At a specific time", isOn: $hasTime)
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
                    Section("From the document") {
                        if let written = item.dateAsWritten, !written.isEmpty { LabeledContent("Date as written", value: written) }
                        if let doc = item.sourceDocument { LabeledContent("Source", value: "\(doc.filename), page \((item.sourcePage ?? 0) + 1)") }
                        if let note = item.changeNote { LabeledContent("Changed", value: note) }
                    }
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
            .navigationTitle(isManual ? "Add by Hand" : "Edit Item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if isDirty { confirmingDiscard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || !isDirty) }
            }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .confirmationDialog("Delete “\(title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let item { Task { await model.discard(item.id); dismiss() } } }
            } message: {
                Text("It is removed from Reminders as well.")
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var isManual: Bool { if case .manual = mode { true } else { false } }

    private func load() {
        defer { baseline = isManual ? nil : fields }
        guard let item else { courseID = courses.count == 1 ? courses[0].id : nil; return }
        title = item.title
        hasDate = item.due != nil
        due = item.due ?? Date()
        hasTime = item.dueHasTime
        courseID = item.course?.id
        componentName = item.componentName ?? ""
        platform = item.platform
        notes = item.notes ?? ""
    }

    private func save() {
        let dueValue: Date? = hasDate ? (hasTime ? due : Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: due)) : nil
        Task {
            switch mode {
            case .manual:
                await model.addManual(title: title, due: dueValue, dueHasTime: hasTime, courseID: courseID, componentName: componentName.isEmpty ? nil : componentName, notes: notes.isEmpty ? nil : notes)
            case .review(let item), .edit(let item):
                var edits = ObligationEdits()
                if title != item.title { edits.title = title }
                if dueValue != item.due || hasTime != item.dueHasTime { edits.due = .some(dueValue); edits.dueHasTime = hasTime }
                if platform != item.platform { edits.platform = platform }
                if componentName != (item.componentName ?? "") { edits.componentName = .some(componentName.isEmpty ? nil : componentName) }
                if notes != (item.notes ?? "") { edits.notes = .some(notes.isEmpty ? nil : notes) }
                if courseID != item.course?.id { edits.courseID = .some(courseID) }
                await model.confirm(item.id, edits: edits)
            }
            dismiss()
        }
    }
}
