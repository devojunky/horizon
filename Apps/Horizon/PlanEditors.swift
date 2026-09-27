import SwiftUI
import IngestKit

/// Edits one block of today's plan, or adds one. Cancel leads, Save trails and is off until something changed and
/// the times make sense; swiping the sheet away with changes asks first (HIG sheets), like the item editor.
struct PlanBlockEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil adds a block.
    let block: PlanBlock?

    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var kind: PlanBlock.Kind = .work
    @State private var reason = ""
    @State private var baseline: Fields?
    @State private var confirmingDiscard = false

    private struct Fields: Equatable { var title: String; var start: Date; var end: Date; var kind: PlanBlock.Kind; var reason: String }
    private var fields: Fields { Fields(title: title, start: start, end: end, kind: kind, reason: reason) }
    private var isDirty: Bool { baseline.map { $0 != fields } ?? !title.isEmpty }
    private var isValid: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && end > start }

    /// The items the plan chose from, one per title, for the picker.
    private var candidates: [PlanObligation] {
        var seen: Set<String> = []
        return model.planCandidates.filter { seen.insert($0.title).inserted }
    }
    /// The picker shows the item whose title is in the field, or "Something else"; picking one fills the field.
    private var pickedTitle: Binding<String> {
        Binding(get: { candidates.contains { $0.title == title } ? title : "" }, set: { if !$0.isEmpty { title = $0 } })
    }
    private static func label(_ o: PlanObligation) -> String { o.course.map { "\(o.title) · \($0)" } ?? o.title }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Title") { TextField("Problem set 3", text: $title).multilineTextAlignment(.trailing).promptOnly() }
                    if !candidates.isEmpty {
                        Picker("Item", selection: pickedTitle) {
                            Text("Something else").tag("")
                            ForEach(candidates, id: \.title) { candidate in Text(Self.label(candidate)).tag(candidate.title) }
                        }
                    }
                    Picker("Kind", selection: $kind) {
                        Text("Work").tag(PlanBlock.Kind.work)
                        Text("Study").tag(PlanBlock.Kind.study)
                        Text("Meal").tag(PlanBlock.Kind.meal)
                        Text("Rest").tag(PlanBlock.Kind.rest)
                        if block?.kind == .fixed { Text("Calendar").tag(PlanBlock.Kind.fixed) }
                    }
                }
                Section {
                    DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                } footer: {
                    if end <= start { Text("It ends before it starts.") }
                    else if block?.kind == .fixed { Text("From your calendar. Changing it here does not change the event.") }
                }
                Section {
                    TextField("Why this, why now", text: $reason, axis: .vertical).lineLimit(2...6)
                } header: {
                    Text("Reason")
                }
                if let block {
                    Section {
                        Button(block.isDone ? "Mark Not Done" : "Mark Done", systemImage: block.isDone ? "arrow.uturn.backward" : "checkmark") { model.markBlock(block.id, done: !block.isDone); dismiss() }
                        Button(block.isSkipped ? (block.wasLeftUnfinished ? "Undo Not Finished" : "Undo Skip") : Date() >= block.end ? "Not Finished" : "Skip Block",
                               systemImage: block.isSkipped ? "arrow.uturn.backward" : "forward.end") { model.skipBlock(block.id, skipped: !block.isSkipped); dismiss() }
                        Button("Delete Block", role: .destructive) { model.deleteBlock(block.id); dismiss() }
                    }
                }
            }
            .paper()
            .editorChrome(title: block == nil ? "New Block" : "Edit Block", confirm: block == nil ? "Add" : "Save", disabled: !isValid || !isDirty,
                          cancel: { if isDirty { confirmingDiscard = true } else { dismiss() } }, action: save)
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 680, minHeight: 420, idealHeight: 540, maxHeight: 720)
        #endif
    }

    private func load() {
        defer { baseline = block == nil ? nil : fields }
        if let block {
            title = block.title; start = block.start; end = block.end; kind = block.kind; reason = block.reason
            return
        }
        // A new block starts when the current one ends, or now, on a five-minute mark, and runs 50 minutes.
        let now = Date()
        let after = model.plan?.blocks.first { $0.start <= now && $0.end > now }?.end ?? now
        let minute = Calendar.current.component(.minute, from: after)
        start = Calendar.current.date(byAdding: .minute, value: (5 - minute % 5) % 5, to: after).map { Calendar.current.date(bySetting: .second, value: 0, of: $0) ?? $0 } ?? after
        end = start.addingTimeInterval(50 * 60)
    }

    private func save() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if var block {
            block.title = title; block.start = start; block.end = end; block.kind = kind; block.reason = reason
            model.updateBlock(block)
        } else {
            model.addBlock(PlanBlock(start: start, end: end, title: title, reason: reason, kind: kind))
        }
        dismiss()
    }
}

/// What the user tells the planner, in their own words: standing rules or today's. Read on every plan; the plan on
/// screen stays as it is until the next one. Capped, because it shares a 4096-token on-device context with the rest.
struct PlannerNotesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirmingDiscard = false
    @FocusState private var focused: Bool
    private let limit = 1500
    private var isDirty: Bool { text != model.planInstructions }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .focused($focused)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("No work after 9 pm. Lunch at 12:30. The essay before anything else.")
                                    .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                        .onChange(of: text) { _, value in if value.count > limit { text = String(value.prefix(limit)) } }
                } header: {
                    Text("What the planner should respect")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Standing rules or today's, in your words. The planner reads this every time you plan; calendar events stay fixed either way. Takes effect the next time you plan.")
                        if text.count > limit - 300 { Text("\(text.count) of \(limit) characters").monospacedDigit() }
                    }
                }
            }
            .paper()
            .editorChrome(title: "Tell the Planner", confirm: "Save", disabled: !isDirty,
                          cancel: { if isDirty { confirmingDiscard = true } else { dismiss() } },
                          action: { model.planInstructions = text.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() })
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .onAppear { text = model.planInstructions; focused = text.isEmpty }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 680, minHeight: 360, idealHeight: 420, maxHeight: 600)
        #endif
    }
}
