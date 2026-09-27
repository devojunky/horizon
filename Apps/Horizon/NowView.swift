import SwiftUI
import HorizonCore
import IngestKit

/// SPEC §6.3: one button, a plan for the rest of today around the calendar, a reason on every block. Set like a
/// printed timetable: a time column, a rail with a dot per block, the block that is on now marked. The plan arrives
/// as the model writes it: each block extends the rail to its point, the dot lands, the words follow. Any block can
/// be changed, added or deleted, and the planner takes what the user tells it. The plan is kept for the day and
/// discarded after it; tomorrow starts from nothing.
struct NowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: PlanBlock?
    @State private var adding = false
    @State private var telling = false
    @State private var confirmingReplan = false
    @State private var revealed: UUID?   // the plan whose rows have arrived; a plan that came at once reveals its rows one after another

    /// What the page shows: the planner at work, the timetable (arriving or settled), or the invitation.
    private enum Stage { case working, timetable, invitation }
    private var stage: Stage {
        if model.planning, model.planDraft.isEmpty { return .working }
        return model.planning || model.plan != nil ? .timetable : .invitation
    }

    var body: some View {
        PageStack {
            // A ZStack, not a Group: a transition needs a container to animate the change of what is inside it
            // (modifiers on a Group attach to each branch, and the hand-over then happens in one frame).
            ZStack {
                switch stage {
                case .working:
                    ScrollView { WorkingLine(kicker: "Planning", line: "Reading your calendar and the coming weeks…") }
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: -16))))   // lifts away as the timetable takes its place
                case .timetable:   // one view for the plan arriving and the plan settled: its rows carry over
                    let plan = model.plan
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        PlanList(blocks: model.planning ? model.planDraft : plan?.blocks ?? [], note: model.planning ? nil : plan?.note,
                                 now: context.date, asking: model.planning ? nil : plan?.awaitingAnswer(at: context.date)?.id,
                                 streaming: model.planning, revealed: model.planning || model.planStreamed || revealed == plan?.id,
                                 reduceMotion: reduceMotion, edit: { editing = $0 }, delete: { model.deleteBlock($0) },
                                 mark: { model.markBlock($0, done: $1) }, skip: { model.skipBlock($0, skipped: $1) })
                            .onChange(of: context.date) { _, _ in Task { await model.syncActivity() } }   // the minute turns: the activity may have a new block on
                    }
                    .onAppear { if let plan { reveal(plan.id) } }
                    .onChange(of: plan?.id) { _, id in if let id { reveal(id) } }
                    .transition(.opacity)
                case .invitation:
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
                    .transition(.opacity)
                }
            }
            .paper()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: stage)
            .navigationTitle("Now")
            .toolbar {
                #if os(iOS)
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
                #else
                ToolbarItemGroup(placement: .primaryAction) {   // every one of these is also in the Plan menu
                    Button { adding = true } label: { Label("Add Block", systemImage: "plus") }.help("Add a block to the plan")
                    Button { telling = true } label: { Label("Tell the Planner", systemImage: "text.bubble") }.help("What the planner should respect (⌥⌘T)")
                    Button { if model.planEdited, model.plan != nil { confirmingReplan = true } else { Task { await model.planToday() } } } label: {
                        Label(model.plan == nil ? "Plan Today" : "Plan Again", systemImage: "sun.horizon").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)   // the page's one prominent action, in words
                    .disabled(model.planning)
                    .help("Plan the rest of today (⇧⌘P)")
                }
                #endif
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
                if MainTabs.debugFlag("--plan"), !model.planning { Task { await model.planToday() } }   // DEBUG: plans afresh, whatever is on file
                if MainTabs.debugFlag("--edit-block"), let first = model.plan?.blocks.first { editing = first }
                if MainTabs.debugFlag("--plan-instructions") { telling = true }
                if MainTabs.debugFlag("--mark-first-done"), let first = model.plan?.blocks.first(where: \.isOpen) { model.markBlock(first.id, done: true) }   // the first still to do, so a second launch marks the next
                #if DEBUG
                if MainTabs.debugOnce("--demo-plan") { model.demoPlan() }   // the Live Activity through each phase, without the planner
                #endif
                #if os(iOS)
                if MainTabs.debugFlag("--intent-first-done"), let first = model.plan?.blocks.first {   // the Live Activity's button, without the button
                    Task { do { _ = try await MarkBlockDoneIntent(blockID: first.id).perform() } catch { PlanCommands.log?("intent failed: \(error)") } }
                }
                if MainTabs.debugOnce("--intent-first-skip"), let first = model.plan?.blocks.first(where: \.isOpen) {   // its Skip, the same way
                    Task { do { _ = try await SkipBlockIntent(blockID: first.id).perform() } catch { PlanCommands.log?("intent failed: \(error)") } }
                }
                #endif
            }
        }
    }

    /// A plan that came all at once (by the numbers, or loaded) reveals its rows one after another; one that streamed
    /// is already on screen.
    private func reveal(_ id: UUID) {
        guard revealed != id else { return }
        if model.planStreamed { revealed = id; return }
        revealed = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))   // laid out hidden first, then the rows arrive
            withAnimation { revealed = id }
        }
    }

}

/// The timetable: the day and the time in the header (and the planner's note, when it has one), one row per block.
/// While the plan streams the rows arrive one by one, each extending the rail, and a line at the foot says the
/// planner is still writing; the list scrolls to keep up. Once settled, a row opens the editor and swipes away.
private struct PlanList: View {
    let blocks: [PlanBlock]
    let note: String?
    let now: Date
    /// The block whose end is asking "finished?" (the Live Activity asks it too).
    let asking: UUID?
    let streaming: Bool
    let revealed: Bool
    let reduceMotion: Bool
    var edit: (PlanBlock) -> Void
    var delete: (UUID) -> Void
    var mark: (UUID, Bool) -> Void
    var skip: (UUID, Bool) -> Void

    private var done: Int { blocks.filter(\.isDone).count }

    /// Skip before a block is over; once it is, the same act answers "finished?" with no.
    private func skipTitle(_ block: PlanBlock) -> String {
        if block.isSkipped { return block.wasLeftUnfinished ? "Undo Not Finished" : "Undo Skip" }
        return block.id == asking || now >= block.end ? "Not Finished" : "Skip"
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        Button { edit(block) } label: {
                            BlockRow(block: block, now: now, asking: block.id == asking, first: index == 0, last: index == blocks.count - 1, arriving: streaming, reduceMotion: reduceMotion,
                                     mark: streaming ? nil : { mark(block.id, $0) })
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!streaming)   // not `disabled`, which would dim the rows as they arrive
                        .frame(maxWidth: 820, alignment: .leading)   // a measure: a wide window does not stretch a timetable
                        .id(block.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparator(.hidden)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 14)
                        .animation(.spring(duration: 0.5).delay(reduceMotion ? 0 : Double(index) * 0.05), value: revealed)
                        .swipeActions(edge: .leading, allowsFullSwipe: !streaming) {
                            if !streaming {
                                Button(block.isDone ? "Not Done" : "Done", systemImage: block.isDone ? "arrow.uturn.backward" : "checkmark") { mark(block.id, !block.isDone) }.tint(Design.accent)
                                Button(skipTitle(block), systemImage: block.isSkipped ? "arrow.uturn.backward" : "forward.end") { skip(block.id, !block.isSkipped) }.tint(.gray)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: !streaming) {
                            if !streaming { Button("Delete", systemImage: "trash", role: .destructive) { delete(block.id) } }
                        }
                        .contextMenu {
                            if !streaming {
                                Button(block.isDone ? "Mark Not Done" : "Mark Done", systemImage: block.isDone ? "arrow.uturn.backward" : "checkmark") { mark(block.id, !block.isDone) }
                                Button(skipTitle(block), systemImage: block.isSkipped ? "arrow.uturn.backward" : "forward.end") { skip(block.id, !block.isSkipped) }
                                Button("Edit Block…") { edit(block) }
                                Button("Delete Block", role: .destructive) { delete(block.id) }
                            }
                        }
                        .accessibilityHint(streaming ? "" : "Opens the editor")
                    }
                    if streaming {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Planning the rest…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 92 + 34)   // under the words, past the time column and the rail
                        .padding(.vertical, 14)
                        .id("planning")
                        .transition(.opacity)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparator(.hidden)
                        .accessibilityLabel("Planning the rest")
                    } else if blocks.isEmpty {
                        Text("Nothing planned. Add a block, or plan again.").foregroundStyle(.secondary).listRowSeparator(.hidden)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Kicker(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            Spacer()
                            Kicker(now.formatted(date: .omitted, time: .shortened))
                        }
                        if let note { Text(note).font(.footnote).foregroundStyle(.secondary).textCase(nil) }
                        if done > 0, !streaming { Kicker(done == blocks.count ? "All done" : "\(done) of \(blocks.count) done") }
                    }
                    .padding(.bottom, 4)
                }
                .onPaper()
            }
            .listStyle(.plain)
            // A row arriving is laid out in a transaction, so the planning line below it glides down as the rail
            // draws (the row's own pieces are still hidden; the list's fade shows nothing). Settled rows change at once.
            .animation(streaming && !reduceMotion ? .easeOut(duration: 0.45) : nil, value: blocks.map(\.id))
            .onChange(of: blocks.count) { _, _ in
                guard streaming else { return }   // keep the newest block in view as the plan grows
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5).delay(0.3)) { proxy.scrollTo("planning", anchor: .bottom) }
            }
        }
    }
}

/// One block: the time column, the rail with its dot, the title and the reason. The block that is on now carries an
/// accent dot with a slow pulse and a "Now" kicker; blocks that have passed fade. A row arriving while the plan
/// streams draws itself in order: the rail above the previous dot has already reached the row's edge, the rail
/// extends down to the dot, the dot lands, and the words fade in.
struct BlockRow: View {
    let block: PlanBlock
    let now: Date
    /// Over, and asking "finished?": the dot answers yes, a swipe or the menu no.
    var asking = false
    var first = false
    var last = false
    /// The plan is streaming: this row draws itself in when it appears.
    var arriving = false
    var reduceMotion = false
    /// Marks the block done or not; nil while the plan streams (no dot to press yet).
    var mark: ((Bool) -> Void)? = nil
    @State private var headDrawn = true   // the rail from the row's edge to the dot
    @State private var landed = true      // the dot
    @State private var wordsIn = true     // the time and the words

    private enum Phase { case past, current, ahead }
    private var phase: Phase { !block.isOpen ? .past : now >= block.end ? .past : now >= block.start ? .current : .ahead }
    private static let dotCentre: CGFloat = 22   // from the row's top

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.clock(block.start)).font(.system(.title3, design: .serif, weight: .semibold)).monospacedDigit()
                Text("to \(Self.clock(block.end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 92, alignment: .trailing)
            .minimumScaleFactor(0.8)
            .padding(.top, 14)
            .opacity(wordsIn ? 1 : 0)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // The rail: a head from the row's edge to the dot (none on the first row), a tail from the dot on
                    // (none on the last row). The tail extends when a row follows; the head draws as the row arrives.
                    Rectangle().fill(Design.rule).frame(width: 1, height: Self.dotCentre)
                        .scaleEffect(y: headDrawn ? 1 : 0, anchor: .top)
                        .opacity(first ? 0 : 1)
                    Rectangle().fill(Design.rule).frame(width: 1).frame(maxHeight: .infinity)
                        .scaleEffect(y: last ? 0 : 1, anchor: .top)
                        .animation(reduceMotion ? nil : .easeIn(duration: 0.22), value: last)
                }
                Button { mark?(!block.isDone) } label: {   // the dot is the mark: press it to cross the block off
                    dot.frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(mark == nil)
                .padding(.top, Self.dotCentre - 22)
                .scaleEffect(landed ? 1 : 0.01)
                .accessibilityLabel(block.isDone ? "Done" : "Mark done")
            }
            .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                if phase == .current { Kicker("Now", accent: true) }
                if block.isDone { Kicker("Done") }
                else if block.isSkipped { Kicker(block.wasLeftUnfinished ? "Not finished" : "Skipped") }
                else if asking { Kicker("Finished?", accent: true) }
                HStack(spacing: 8) {
                    Text(block.title)
                        .font(.body.weight(block.kind == .work ? .semibold : .regular))
                        .foregroundStyle(block.kind == .fixed ? .secondary : .primary)
                        .strikethrough(block.isDone, color: .secondary)
                    if block.kind != .work, block.title.caseInsensitiveCompare(Self.kindName(block.kind)) != .orderedSame {   // "Rest" needs no "Rest" chip
                        Text(Self.kindName(block.kind)).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Design.rule, in: Capsule())
                    }
                }
                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.vertical, 14)
            .opacity(wordsIn ? 1 : 0)
            .offset(x: wordsIn ? 0 : 6)
            Spacer(minLength: 0)
        }
        .opacity(phase == .past && !asking ? 0.45 : 1)   // a block asking "finished?" waits on the user: it is not faded with the past
        .animation(.snappy, value: block.isDone)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.clock(block.start)) to \(Self.clock(block.end)), \(block.title)\(block.isDone ? ", done" : block.isSkipped ? (block.wasLeftUnfinished ? ", not finished" : ", skipped") : asking ? ", finished?" : phase == .current ? ", now" : "")")
        .onAppear {
            guard arriving, !reduceMotion else { return }
            headDrawn = false; landed = false; wordsIn = false
            // The previous row's tail takes 0.22 s to reach this row's edge; then the head reaches the dot, the dot
            // lands with a little bounce, and the words fade in beside it.
            let reach = first ? 0 : 0.22
            withAnimation(.easeOut(duration: 0.28).delay(reach)) { headDrawn = true }
            withAnimation(.spring(duration: 0.4, bounce: 0.4).delay(reach + 0.24)) { landed = true }
            withAnimation(.easeOut(duration: 0.4).delay(reach + 0.3)) { wordsIn = true }
        }
    }

    @ViewBuilder private var dot: some View {
        let size: CGFloat = 10
        if block.isDone {   // crossed off: a filled dot with a check
            ZStack {
                Circle().fill(.primary).frame(width: size + 6, height: size + 6)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Design.paper)
            }
        } else if block.isSkipped {   // set aside: an open ring, nothing in it
            Circle().stroke(.secondary, lineWidth: 1.5).frame(width: size + 4, height: size + 4).background(Design.paper, in: Circle())
        } else if asking {   // over and asking: the accent ring the dot fills when pressed
            Circle().stroke(Design.accent, lineWidth: 2).frame(width: size + 6, height: size + 6).background(Design.paper, in: Circle())
        } else {
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
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)).minute())
    }

    static func kindName(_ kind: PlanBlock.Kind) -> String {
        switch kind { case .work: "Work"; case .meal: "Meal"; case .rest: "Rest"; case .fixed: "Calendar" }
    }
}
