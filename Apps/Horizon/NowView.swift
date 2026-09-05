import SwiftUI
import HorizonCore
import IngestKit

/// SPEC §6.3: one button, a plan for the rest of today around the calendar, a reason on every block. Any block can be
/// changed, added or deleted, and the planner takes the user's own instructions. The plan is kept for the day and
/// discarded after it; tomorrow starts from nothing.
struct NowView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PlanBlock?
    @State private var adding = false
    @State private var instructing = false
    @State private var confirmingReplan = false

    var body: some View {
        NavigationStack {
            Group {
                if model.planning {
                    ProgressView("Planning the rest of today…")
                } else if let plan = model.plan {
                    List {
                        Section {
                            ForEach(plan.blocks) { block in
                                Button { editing = block } label: { BlockRow(block: block) }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteBlock(block.id) }
                                    }
                                    .accessibilityHint("Opens the editor")
                            }
                            if plan.blocks.isEmpty { Text("Nothing planned. Add a block, or plan again.").foregroundStyle(.secondary) }
                        } header: {
                            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        } footer: {
                            Text(footer(plan))
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView {
                        Label("Now", systemImage: "sun.horizon")
                    } description: {
                        Text("One plan for the rest of today, around your calendar, with a reason on every block.")
                    } actions: {
                        Button("Plan Today") { Task { await model.planToday() } }.buttonStyle(.borderedProminent)
                        Button("Instructions…") { instructing = true }
                    }
                }
            }
            .animation(.default, value: model.planning)
            .navigationTitle("Now")
            .toolbar {
                if model.plan != nil, !model.planning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Plan Again") { if model.planEdited { confirmingReplan = true } else { Task { await model.planToday() } } }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { adding = true } label: { Label("Add Block…", systemImage: "plus") }
                        Button { instructing = true } label: { Label("Instructions…", systemImage: "text.quote") }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                    .disabled(model.planning)
                }
            }
            .confirmationDialog("Replace the plan you edited?", isPresented: $confirmingReplan, titleVisibility: .visible) {
                Button("Plan Again", role: .destructive) { Task { await model.planToday() } }
            } message: {
                Text("Your changes to today's blocks are lost.")
            }
            .sheet(item: $editing) { PlanBlockEditor(block: $0) }
            .sheet(isPresented: $adding) { PlanBlockEditor(block: nil) }
            .sheet(isPresented: $instructing) { PlanInstructionsEditor() }
            .onAppear {
                model.expirePlanIfStale()
                if MainTabs.debugFlag("--plan"), model.plan == nil, !model.planning { Task { await model.planToday() } }
                if MainTabs.debugFlag("--edit-block"), let first = model.plan?.blocks.first { editing = first }
                if MainTabs.debugFlag("--plan-instructions") { instructing = true }
            }
        }
    }

    private func footer(_ plan: DayPlan) -> String {
        var parts: [String] = []
        if let note = plan.note { parts.append(note) }
        switch plan.route {
        case .privateCloudCompute?: parts.append("Planned in Private Cloud Compute.")
        case .onDevice?: parts.append("Planned on device.")
        case nil: break
        }
        if model.planEdited { parts.append("Edited by hand.") }
        parts.append("Kept for today; tomorrow starts from nothing.")
        return parts.joined(separator: " ")
    }
}

struct BlockRow: View {
    let block: PlanBlock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Self.range(block)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(block.title)
                    .font(.body.weight(block.kind == .work ? .medium : .regular))
                    .foregroundStyle(block.kind == .fixed ? .secondary : .primary)
                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }

    static func range(_ block: PlanBlock) -> String {
        let f = Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)).minute()
        return "\(block.start.formatted(f))–\(block.end.formatted(f))"
    }
}
