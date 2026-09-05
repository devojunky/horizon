import SwiftUI
import SwiftData
import HorizonCore
import IngestKit

/// The one editor: corrects a parsed item from the review queue, or enters one by hand (the fallback the user asked for).
struct ObligationEditor: View {
    enum Mode { case review(Obligation), manual }

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

    private var course: Course? { courses.first { $0.id == courseID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Course", selection: $courseID) {
                        Text("None").tag(UUID?.none)
                        ForEach(courses) { Text($0.code.isEmpty ? $0.title : $0.code).tag(UUID?.some($0.id)) }
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
                if case .review(let item) = mode {
                    Section("From the document") {
                        if let written = item.dateAsWritten, !written.isEmpty { LabeledContent("Date as written", value: written) }
                        if let doc = item.sourceDocument { LabeledContent("Source", value: "\(doc.filename), page \((item.sourcePage ?? 0) + 1)") }
                        if let note = item.changeNote { LabeledContent("Changed", value: note) }
                    }
                }
            }
            .navigationTitle(isManual ? "Add by hand" : "Edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var isManual: Bool { if case .manual = mode { true } else { false } }

    private func load() {
        guard case .review(let item) = mode else { courseID = courses.count == 1 ? courses[0].id : nil; return }
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
            case .review(let item):
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
