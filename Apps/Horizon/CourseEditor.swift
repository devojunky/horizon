import SwiftUI
import SwiftData
import HorizonCore
import IngestKit

/// Edits every field of a course after parsing, or creates one by hand. Each changed field becomes an override that a
/// later document leaves alone. Cancel leads, Save trails; unsaved changes ask before they are discarded (HIG sheets).
struct CourseEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil creates a course.
    let course: Course?

    @State private var title = ""
    @State private var code = ""
    @State private var term = ""
    @State private var instructor = ""
    @State private var room = ""
    @State private var hasTermDates = false
    @State private var termStart = Date()
    @State private var termEnd = Date()
    @State private var meetings: [MeetingRow] = []
    @State private var components: [ComponentRow] = []
    @State private var breaks: [BreakRow] = []
    @State private var baseline: Fields?

    struct MeetingRow: Identifiable, Equatable { let id = UUID(); var weekday = 2; var start = ClockText.time(9, 30); var end = ClockText.time(10, 45) }
    struct ComponentRow: Identifiable, Equatable { let id = UUID(); var name = ""; var weight: Double?; var count: Int?; var cadence: Cadence?; var dropLowest: Int?; var platform: Platform? }
    struct BreakRow: Identifiable, Equatable { let id = UUID(); var label = ""; var start = Date(); var end = Date() }
    private struct Fields: Equatable {
        var title, code, term, instructor, room: String; var hasTermDates: Bool; var termStart, termEnd: Date
        var meetings: [MeetingRow]; var components: [ComponentRow]; var breaks: [BreakRow]
    }
    private var fields: Fields {
        Fields(title: title, code: code, term: term, instructor: instructor, room: room, hasTermDates: hasTermDates, termStart: termStart, termEnd: termEnd,
               meetings: meetings, components: components, breaks: breaks)
    }
    private var isDirty: Bool { baseline.map { $0 != fields } ?? false }
    private var named: Bool { !(title.trimmingCharacters(in: .whitespaces).isEmpty && code.trimmingCharacters(in: .whitespaces).isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldRow(label: "Name", prompt: "Calculus II", text: $title)
                    FieldRow(label: "Code", prompt: "MA-UY 1124", text: $code).autocorrectionDisabled()
                    FieldRow(label: "Term", prompt: "Fall 2026", text: $term)
                    FieldRow(label: "Instructor", prompt: "Name", text: $instructor).textContentType(.name)
                    FieldRow(label: "Room", prompt: "Rogers Hall 204", text: $room)
                } footer: {
                    Text("The name is what Horizon shows for the course and adds to each reminder.")
                }
                Section {
                    Toggle("Term dates", isOn: $hasTermDates.animation())
                    if hasTermDates {
                        DatePicker("Starts", selection: $termStart, displayedComponents: .date)
                        DatePicker("Ends", selection: $termEnd, in: termStart..., displayedComponents: .date)
                    }
                } footer: {
                    Text("Term dates set how far the Horizon strip runs and when weekly work is expected.")
                }
                Section {
                    ForEach($meetings) { $meeting in
                        HStack(spacing: 8) {
                            Picker("Day", selection: $meeting.weekday) {
                                ForEach(1...7, id: \.self) { Text(ClockText.weekdayName($0)).tag($0) }
                            }
                            .labelsHidden()
                            Spacer(minLength: 0)
                            DatePicker("Starts", selection: $meeting.start, displayedComponents: .hourAndMinute).labelsHidden()
                            Text("to").foregroundStyle(.secondary)
                            DatePicker("Ends", selection: $meeting.end, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                    }
                    .onDelete { meetings.remove(atOffsets: $0) }
                    Button("Add Meeting", systemImage: "plus") { withAnimation { meetings.append(MeetingRow()) } }
                } header: { Kicker("Meetings") }
                Section {
                    ForEach($components) { $component in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("Component", text: $component.name)
                                TextField("Weight", value: $component.weight, format: .number.precision(.fractionLength(0...1)))
                                    .multilineTextAlignment(.trailing).promptOnly().frame(width: 64).decimalKeyboard()
                                Text("%").foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                Picker("Rhythm", selection: $component.cadence) {
                                    Text("No rhythm").tag(Cadence?.none)
                                    Text("Weekly").tag(Cadence?.some(.weekly))
                                    Text("Every two weeks").tag(Cadence?.some(.biweekly))
                                    Text("Once").tag(Cadence?.some(.once))
                                }
                                .labelsHidden()
                                Spacer(minLength: 0)
                                LabeledContent("Count") { TextField("–", value: $component.count, format: .number).multilineTextAlignment(.trailing).promptOnly().frame(width: 36).numberKeyboard() }
                                LabeledContent("Drops") { TextField("–", value: $component.dropLowest, format: .number).multilineTextAlignment(.trailing).promptOnly().frame(width: 36).numberKeyboard() }
                            }
                            .font(.subheadline)
                            Picker("Where", selection: $component.platform) {   // the site its work lives on, for Coverage's "never read" line
                                Text("Site not stated").tag(Platform?.none)
                                Text("LMS").tag(Platform?.some(.lms)); Text("WebAssign").tag(Platform?.some(.webAssign))
                                Text("Gradescope").tag(Platform?.some(.gradescope)); Text("MyLab").tag(Platform?.some(.myLab))
                            }
                            .labelsHidden()
                            .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { components.remove(atOffsets: $0) }
                    Button("Add Component", systemImage: "plus") { withAnimation { components.append(ComponentRow()) } }
                } header: {
                    Kicker("Grade")
                } footer: {
                    let total = components.compactMap(\.weight).reduce(0, +)
                    let overflow = total > 100.5 ? "The weights add up to \(total.formatted(.number.precision(.fractionLength(0...1))))%, more than a whole grade. " : ""
                    Text("\(overflow)Weights set the points at stake on each item and the colour of its mark on the strip. Count is how many of the component there are; Drops is how many lowest scores are dropped. The site is where its work lives; Coverage says when nothing has ever been read from there.")
                }
                Section {
                    ForEach($breaks) { $span in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Thanksgiving", text: $span.label).promptOnly()
                            DatePicker("From", selection: $span.start, displayedComponents: .date)
                            DatePicker("To", selection: $span.end, in: span.start..., displayedComponents: .date)
                        }
                    }
                    .onDelete { breaks.remove(atOffsets: $0) }
                    Button("Add Break", systemImage: "plus") { withAnimation { breaks.append(BreakRow()) } }
                } header: {
                    Kicker("No class")
                }
                if let course {
                    Section {
                        Button("Delete Course", role: .destructive) { Task { await model.deleteCourse(course.id) }; dismiss() }
                    } footer: {
                        Text("It goes to Recently Deleted with its items, their reminders, and its documents, and can be restored from there for 30 days.")
                    }
                }
            }
            .paper()
            .editorChrome(title: course == nil ? "New Course" : "Edit Course", confirm: course == nil ? "Add" : "Save", disabled: !named || !(isDirty || course == nil),
                          dirty: isDirty, cancel: { dismiss() }, action: save)
            .interactiveDismissDisabled(isDirty)
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 720, minHeight: 480, idealHeight: 680, maxHeight: 740)
        #endif
    }

    private func load() {
        guard let course else { baseline = fields; return }
        title = course.title; code = course.code; term = course.term ?? ""; instructor = course.instructor ?? ""; room = course.room ?? ""
        hasTermDates = course.termStart != nil || course.termEnd != nil
        termStart = course.termStart ?? Date()
        termEnd = course.termEnd ?? Calendar.current.date(byAdding: .month, value: 4, to: termStart) ?? termStart
        meetings = course.meetings.map { MeetingRow(weekday: $0.weekday, start: ClockText.time(from: $0.start) ?? ClockText.time(9, 30), end: ClockText.time(from: $0.end) ?? ClockText.time(10, 45)) }
        components = course.gradeComponents.map { ComponentRow(name: $0.name, weight: $0.weight.map { $0 * 100 }, count: $0.expectedCount, cadence: $0.cadence, dropLowest: $0.dropLowest, platform: $0.platform) }
        breaks = course.noClassDates.map { BreakRow(label: $0.label ?? "", start: $0.start, end: $0.end) }
        baseline = fields
    }

    private func save() {
        let calendar = Calendar.current
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        var edits = CourseEdits()
        if course == nil || clean(title) != course?.title { edits.title = clean(title) }
        if course == nil || clean(code) != course?.code { edits.code = clean(code) }
        if clean(term) != (course?.term ?? "") { edits.term = .some(clean(term).isEmpty ? nil : clean(term)) }
        if clean(instructor) != (course?.instructor ?? "") { edits.instructor = .some(clean(instructor).isEmpty ? nil : clean(instructor)) }
        if clean(room) != (course?.room ?? "") { edits.room = .some(clean(room).isEmpty ? nil : clean(room)) }
        let start: Date? = hasTermDates ? calendar.startOfDay(for: termStart) : nil
        let end: Date? = hasTermDates ? calendar.startOfDay(for: termEnd) : nil
        if start != course?.termStart { edits.termStart = .some(start) }
        if end != course?.termEnd { edits.termEnd = .some(end) }
        let slots = meetings.map { MeetingSlot(weekday: $0.weekday, start: ClockText.string(from: $0.start), end: ClockText.string(from: $0.end)) }
        if slots != (course?.meetings ?? []) { edits.meetings = slots }
        let table = components.filter { !clean($0.name).isEmpty }.map {
            GradeComponent(name: clean($0.name), weight: $0.weight.map { $0 / 100 }, expectedCount: $0.count, cadence: $0.cadence, dropLowest: $0.dropLowest, platform: $0.platform)
        }
        if table != (course?.gradeComponents ?? []) { edits.gradeComponents = table }
        let spans = breaks.map { ClosedDateRange(start: calendar.startOfDay(for: $0.start), end: calendar.startOfDay(for: $0.end), label: clean($0.label).isEmpty ? nil : clean($0.label)) }
        if spans != (course?.noClassDates ?? []) { edits.noClassDates = spans }
        let (model, id) = (model, course?.id)   // read from the sheet before it goes
        dismiss()   // at once; the save and the sync after it go on without holding the sheet up
        Task { if let id { await model.updateCourse(id, edits: edits) } else { await model.addCourse(edits) } }
    }

}

/// Meeting times travel as "HH:mm" strings (`MeetingSlot`); the pickers want dates.
private enum ClockText {
    static func weekdayName(_ weekday: Int) -> String { Calendar.current.shortWeekdaySymbols[(weekday - 1 + 7) % 7] }
    static func time(_ hour: Int, _ minute: Int) -> Date { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() }
    static func time(from text: String?) -> Date? {
        guard let text, let colon = text.firstIndex(of: ":"), let h = Int(text[..<colon]), let m = Int(text[text.index(after: colon)...].prefix(2)) else { return nil }
        return time(h, m)
    }
    static func string(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

private extension View {
    /// A numeric keyboard where there is one.
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
    /// Whole numbers (a count): the keypad with no decimal point.
    func numberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
