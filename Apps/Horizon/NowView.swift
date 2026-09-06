import SwiftUI
import HorizonCore
import IngestKit

/// SPEC §6.3: one button, a plan for the rest of today around the calendar, a reason on every block. Set like a
/// printed timetable: a time column, a rail with a dot per block, the block that is on now marked. Any block can be
/// changed, added or deleted, and the planner takes what the user tells it. The plan is kept for the day and
/// discarded after it; tomorrow starts from nothing.
struct NowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: PlanBlock?
    @State private var adding = false
    @State private var telling = false
    @State private var confirmingReplan = false
    @State private var revealed: UUID?   // the plan whose rows have arrived; a new plan's rows come in one after another

    var body: some View {
        NavigationStack {
            Group {
                if model.planning {
                    ScrollView { WorkingLine(kicker: "Planning", line: "Reading your calendar and the coming weeks…") }
                } else if let plan = model.plan {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        PlanList(plan: plan, now: context.date, footer: footer(plan), revealed: revealed == plan.id, reduceMotion: reduceMotion,
                                 edit: { editing = $0 }, delete: { model.deleteBlock($0) })
                    }
                    .onAppear { reveal(plan.id) }
                    .onChange(of: plan.id) { _, id in reveal(id) }
                } else {
                    ScrollView {
                        EditorialEmpty(title: "Today, planned.", deck: "One plan for the rest of today, around your calendar, with a reason on every block. Tell the planner what to respect, then plan.") {
                            Button("Plan Today") { Task { await model.planToday() } }.buttonStyle(.borderedProminent)
                            Button("Tell the Planner…") { telling = true }
                        }
                        .padding(.horizontal, 20)
                        if !model.planInstructions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Hairline()
                                Kicker("You told the planner").padding(.top, 12)
                                Text(model.planInstructions).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
            .paper()
            .animation(.snappy, value: model.planning)
            .animation(.snappy, value: model.plan == nil)
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
                        Button { telling = true } label: { Label("Tell the Planner…", systemImage: "text.bubble") }
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
            .sheet(isPresented: $telling) { PlannerNotesEditor() }
            .onAppear {
                model.expirePlanIfStale()
                if MainTabs.debugFlag("--plan"), model.plan == nil, !model.planning { Task { await model.planToday() } }
                if MainTabs.debugFlag("--edit-block"), let first = model.plan?.blocks.first { editing = first }
                if MainTabs.debugFlag("--plan-instructions") { telling = true }
            }
        }
    }

    private func reveal(_ id: UUID) {
        guard revealed != id else { return }
        revealed = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))   // laid out hidden first, then the rows arrive
            withAnimation { revealed = id }
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

/// The timetable: the day and the time in the header, one row per block, the footer's provenance.
private struct PlanList: View {
    let plan: DayPlan
    let now: Date
    let footer: String
    let revealed: Bool
    let reduceMotion: Bool
    var edit: (PlanBlock) -> Void
    var delete: (UUID) -> Void

    var body: some View {
        List {
            Section {
                ForEach(Array(plan.blocks.enumerated()), id: \.element.id) { index, block in
                    Button { edit(block) } label: {
                        BlockRow(block: block, now: now, first: index == 0, last: index == plan.blocks.count - 1, reduceMotion: reduceMotion)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 14)
                    .animation(.spring(duration: 0.5).delay(reduceMotion ? 0 : Double(index) * 0.05), value: revealed)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(block.id) }
                    }
                    .accessibilityHint("Opens the editor")
                }
                if plan.blocks.isEmpty {
                    Text("Nothing planned. Add a block, or plan again.").foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Kicker(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    Spacer()
                    Kicker(now.formatted(date: .omitted, time: .shortened))
                }
                .padding(.bottom, 4)
            } footer: {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
            }
            .onPaper()
        }
        .listStyle(.plain)
    }
}

/// One block: the time column, the rail with its dot, the title and the reason. The block that is on now carries an
/// accent dot with a slow pulse and a "Now" kicker; blocks that have passed fade.
struct BlockRow: View {
    let block: PlanBlock
    let now: Date
    var first = false
    var last = false
    var reduceMotion = false

    private enum Phase { case past, current, ahead }
    private var phase: Phase { now >= block.end ? .past : now >= block.start ? .current : .ahead }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.clock(block.start)).font(.system(.title3, design: .serif, weight: .semibold)).monospacedDigit()
                Text("to \(Self.clock(block.end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 92, alignment: .trailing)
            .minimumScaleFactor(0.8)
            .padding(.top, 14)
            ZStack(alignment: .top) {
                Rectangle().fill(Design.rule).frame(width: 1)
                    .padding(.top, first ? 22 : 0)
                    .frame(maxHeight: last ? 22 : .infinity, alignment: .top)
                dot.padding(.top, 17)
            }
            .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                if phase == .current { Kicker("Now", accent: true) }
                HStack(spacing: 8) {
                    Text(block.title)
                        .font(.body.weight(block.kind == .work ? .semibold : .regular))
                        .foregroundStyle(block.kind == .fixed ? .secondary : .primary)
                    if block.kind != .work, block.title.caseInsensitiveCompare(Self.kindName(block.kind)) != .orderedSame {   // "Rest" needs no "Rest" chip
                        Text(Self.kindName(block.kind)).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Design.rule, in: Capsule())
                    }
                }
                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.vertical, 14)
            Spacer(minLength: 0)
        }
        .opacity(phase == .past ? 0.45 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.clock(block.start)) to \(Self.clock(block.end)), \(block.title)\(phase == .current ? ", now" : "")")
    }

    @ViewBuilder private var dot: some View {
        let size: CGFloat = 10
        switch phase {
        case .current:
            ZStack {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2   // a two-second breath
                        Circle().stroke(Design.accent.opacity(0.6 * (1 - t)), lineWidth: 1.5).frame(width: size, height: size).scaleEffect(1 + 1.4 * t)
                    }
                }
                Circle().fill(Design.accent).frame(width: size, height: size)
            }
        case .past, .ahead:
            switch block.kind {
            case .work: Circle().fill(.primary).frame(width: size, height: size)
            case .fixed: Circle().fill(.secondary).frame(width: size, height: size)
            case .meal, .rest: Circle().stroke(.primary, lineWidth: 1.5).frame(width: size - 1.5, height: size - 1.5).background(Design.paper, in: Circle())
            }
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)).minute())
    }

    static func kindName(_ kind: PlanBlock.Kind) -> String {
        switch kind { case .work: "Work"; case .meal: "Meal"; case .rest: "Rest"; case .fixed: "Calendar" }
    }
}
