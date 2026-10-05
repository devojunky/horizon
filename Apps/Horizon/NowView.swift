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

    private var stage: NowStage {
        if model.planning, model.planDraft.isEmpty { return .working }
        return model.planning || model.plan != nil ? .timetable : .invitation
    }

    var body: some View {
        PageStack {
            content
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
                    ToolbarSpacer(.fixed, placement: .primaryAction)   // the page's own, apart from the window's
                    ToolbarItemGroup(placement: .primaryAction) {   // every one of these is also in the Plan menu
                        Button { adding = true } label: { Label("Add Block", systemImage: "plus") }.help("Add a block to the plan")
                        Button { telling = true } label: { Label("Tell the Planner", systemImage: "text.bubble") }.help("What the planner should respect (⌥⌘P)")
                    }
                    if stage != .invitation {   // the invitation offers Plan Today itself: one prominent button on the page, not two
                        ToolbarItem(placement: .primaryAction) {
                            Button { if model.planEdited, model.plan != nil { confirmingReplan = true } else { Task { await model.planToday() } } } label: {
                                Label(model.plan == nil ? "Plan Today" : "Plan Again", systemImage: "sun.horizon").labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.borderedProminent)   // the page's one prominent action, in words
                            .disabled(model.planning)
                            .help("Plan the rest of today (⇧⌘P)")
                        }
                    }
                    #endif
                }
                // An alert, not a dialog: asked from Plan Again at the top or Tonight Until at the foot, a popover's
                // arrow pointed at whatever row it happened to be anchored on.
                .alert("Replace the plan you edited?", isPresented: $confirmingReplan) {
                    Button("Plan Again", role: .destructive) { model.planAgain() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(model.pendingTonightEnd.map { "Planning again to \(PlanHours.label($0)) tonight loses your changes to today's blocks." } ?? "Your changes to today's blocks are lost.")
                }
                .onChange(of: confirmingReplan) { _, asking in if !asking { model.pendingTonightEnd = nil } }   // not planned again: tonight's end stays as it was
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
                    if MainTabs.debugOnce("--demo-plan-stream") { Task { await model.demoPlanStream() } }   // a plan streaming in, the same every time
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

    /// On a Mac the day's context sits in a column beside the plan (tonight's end, what the planner was told, what
    /// is due soon); a phone keeps them under the plan.
    @ViewBuilder private var content: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 0) {
            stages.frame(maxWidth: .infinity)
            NowRail(end: model.tonightEnd, usualEnd: model.usualPlanHours.end, chooseEnd: chooseEnd, tell: { telling = true })
                .frame(width: 300)
        }
        .background(Design.paper)
        #else
        stages
        #endif
    }

    /// The planner at work, the timetable, or the invitation: one list for all three, so the page never trades one
    /// scroll view for another under the navigation bar (the large title faded out and back in when it did), and
    /// what arrives takes the place of what was there: the planning line becomes the timetable's foot as the first
    /// block comes, and the foot becomes Tonight Until when the plan settles, so nothing below the rows jumps.
    private var stages: some View {
        let plan = model.plan
        return TimelineView(.everyMinute) { context in   // on the minute itself, not a minute after the page appeared
            PlanList(stage: stage, blocks: model.planning ? model.planDraft : plan?.blocks ?? [], note: model.planning ? nil : plan?.note,
                     now: context.date, asking: model.planning ? nil : plan?.awaitingAnswer(at: context.date)?.id,
                     streaming: model.planning, revealed: model.planning || model.planStreamed || revealed == plan?.id,
                     reduceMotion: reduceMotion, until: model.tonightEnd, usualEnd: model.usualPlanHours.end, instructions: model.planInstructions,
                     planToday: { Task { await model.planToday() } }, tell: { telling = true },
                     edit: { editing = $0 }, delete: { model.deleteBlock($0) },
                     mark: { model.markBlock($0, done: $1) }, skip: { model.skipBlock($0, skipped: $1) }, chooseEnd: chooseEnd)
                .onChange(of: context.date) { _, _ in   // the minute turns: the activity may have a new block on, and a page left open overnight lets yesterday's plan go
                    model.expirePlanIfStale()
                    Task { await model.syncActivity() }
                }
        }
        .onAppear { if let plan { reveal(plan.id) } }
        .onChange(of: plan?.id) { _, id in if let id { reveal(id) } }
        .paper()
    }

    /// Tonight's end chosen: the plan on file is made again up to it, after asking when it was edited by hand.
    private func chooseEnd(_ end: Int) {
        if model.chooseTonightEnd(end) { confirmingReplan = true }
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

/// What Now shows: the planner at work, the timetable (arriving or settled), or the invitation to plan.
private enum NowStage { case working, timetable, invitation }

/// The page, in one list whatever it shows: the day and the time at its head, then the planner's note and how much
/// is done (rows, so they arrive with an animation: a header's height changes in a single frame), one row per block,
/// and a foot that is the planner at work while the plan comes and Tonight Until once it is settled. While the plan
/// streams the rows arrive one by one, each extending the rail, and the list scrolls to keep the foot in view. Once
/// settled, a row opens the editor and swipes away. With no plan, the invitation stands where the rows would.
private struct PlanList: View {
    let stage: NowStage
    let blocks: [PlanBlock]
    let note: String?
    let now: Date
    /// The block whose end is asking "finished?" (the Live Activity asks it too).
    let asking: UUID?
    let streaming: Bool
    let revealed: Bool
    let reduceMotion: Bool
    /// Tonight's end, and the usual one, for the line at the foot of the timetable.
    let until: Int
    let usualEnd: Int
    /// What the user told the planner, shown under the invitation.
    let instructions: String
    var planToday: () -> Void
    var tell: () -> Void
    var edit: (PlanBlock) -> Void
    var delete: (UUID) -> Void
    var mark: (UUID, Bool) -> Void
    var skip: (UUID, Bool) -> Void
    var chooseEnd: (Int) -> Void

    private var work: [PlanBlock] { blocks.filter(\.asksWhenOver) }   // what "x of y done" counts: not meals, rests or the calendar's events
    private var done: Int { work.filter(\.isDone).count }

    /// Whether setting it aside means anything: before it is over, or after it for a block that asks "finished?" (work
    /// and study); a meal or a calendar event that is over was not "not finished". Taking a skip back always is.
    private func canSkip(_ block: PlanBlock) -> Bool { block.isSkipped || now < block.end || block.asksWhenOver }

    /// Skip before a block is over; once it is, the same act answers "finished?" with no.
    private func skipTitle(_ block: PlanBlock) -> String {
        if block.isSkipped { return block.wasLeftUnfinished ? "Undo Not Finished" : "Undo Skip" }
        return block.id == asking || now >= block.end ? "Not Finished" : "Skip"
    }

    /// Where each block stands as the minutes pass (on now, over, asking "finished?"): a change animates the rows it
    /// moves, unless the user has asked for less motion (it is automatic, not theirs).
    private var timeline: [Int] {
        blocks.map { block in block.id == asking ? 3 : !block.isOpen || now >= block.end ? 0 : now >= block.start ? 1 : 2 }
    }

    /// The day and the time: one line, always, so the list under it never moves when something is done; the day's
    /// shorter form when the long one does not fit ("Monday, October 5", then "Mon, Oct 5").
    private var header: some View {
        let day = PlanHours.day(of: now, calendar: .current)   // after midnight, the night's own day
        let time = Kicker(now.formatted(date: .omitted, time: .shortened))
        return ViewThatFits(in: .horizontal) {
            HStack { Kicker(day.formatted(.dateTime.weekday(.wide).month(.wide).day())); Spacer(); time }
            HStack { Kicker(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())); Spacer(); time }
            HStack { Kicker(day.formatted(.dateTime.month(.abbreviated).day())); Spacer(); time }
        }
        .lineLimit(1)
        #if os(macOS)
        .frame(maxWidth: 820, alignment: .leading)   // the timetable's own measure (its rows keep it too)
        #endif
        .padding(.bottom, 4)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    #if os(macOS)
                    header.pageRow(top: 16, bottom: 10).accessibilityAddTraits(.isHeader)   // a row: a Mac pins a header on window grey, off the paper
                    #endif
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: 820, alignment: .leading)
                            .pageRow(top: 0, bottom: 8)
                            .listRowSeparator(.hidden)
                    }
                    if done > 0, !streaming {
                        Kicker(done == work.count ? "All done" : "\(done) of \(work.count) done")
                            .contentTransition(.numericText())
                            .frame(maxWidth: 820, alignment: .leading)
                            .pageRow(top: 0, bottom: 8)
                            .listRowSeparator(.hidden)
                    }
                    if stage == .invitation {
                        EditorialEmpty(title: "Today, planned.", deck: "One plan for the rest of today, around your calendar, with a reason on every block. Tell the planner what to respect, then plan.") {
                            Button("Plan Today", action: planToday).buttonStyle(.borderedProminent)
                            #if os(iOS)   // a Mac has it in the column beside the page
                            Button("Tell the Planner…", action: tell).buttonStyle(.borderless)   // in a list row: its own tap, in the tint, as on any page
                            #endif
                        }
                        .frame(maxWidth: 820, alignment: .leading)
                        .pageRow(top: 0, bottom: 0)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        Button { edit(block) } label: {
                            BlockRow(block: block, now: now, asking: block.id == asking, first: index == 0, last: index == blocks.count - 1, arriving: streaming, reduceMotion: reduceMotion,
                                     mark: streaming ? nil : { mark(block.id, $0) })
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!streaming)   // not `disabled`, which would dim the rows as they arrive
                        .frame(maxWidth: 820, alignment: .leading)   // a measure: a wide window does not stretch a timetable
                        .id(block.id)
                        .pageRow(top: 0, bottom: 0)
                        .listRowSeparator(.hidden)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed || reduceMotion ? 0 : 14)   // with Reduce Motion the rows fade in where they stand
                        .animation(.spring(duration: 0.5).delay(reduceMotion ? 0 : Double(index) * 0.05), value: revealed)
                        .swipeActions(edge: .leading, allowsFullSwipe: !streaming) {
                            if !streaming {
                                Button(block.isDone ? "Not Done" : "Done", systemImage: block.isDone ? "arrow.uturn.backward" : "checkmark") { mark(block.id, !block.isDone) }.tint(Design.accentInk)
                                if canSkip(block) { Button(skipTitle(block), systemImage: block.isSkipped ? "arrow.uturn.backward" : "forward.end") { skip(block.id, !block.isSkipped) }.tint(.gray) }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: !streaming) {
                            if !streaming { Button("Delete", systemImage: "trash", role: .destructive) { delete(block.id) } }
                        }
                        .contextMenu {
                            if !streaming {
                                Button(block.isDone ? "Mark Not Done" : "Mark Done", systemImage: block.isDone ? "arrow.uturn.backward" : "checkmark") { mark(block.id, !block.isDone) }
                                if canSkip(block) { Button(skipTitle(block), systemImage: block.isSkipped ? "arrow.uturn.backward" : "forward.end") { skip(block.id, !block.isSkipped) } }
                                Button("Edit Block…", systemImage: "pencil") { edit(block) }
                                Button("Delete Block", systemImage: "trash", role: .destructive) { delete(block.id) }
                            }
                        }
                        .accessibilityHint(streaming ? "" : "Opens the editor")
                    }
                    if stage == .timetable, !streaming, blocks.isEmpty, note == nil {   // a note ("The day ended at 10 PM…") already says why, and what to do
                        Text("Nothing planned. Add a block, or plan again.").foregroundStyle(.secondary).pageRow(top: 14, bottom: 0).listRowSeparator(.hidden)
                    }
                    foot
                        .id("foot")
                        .pageRow(top: 0, bottom: 0)
                        .listRowSeparator(.hidden)
                    #if os(iOS)   // a Mac keeps it in the column beside the page
                    if stage == .invitation, !instructions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Hairline()
                            Kicker("You told the planner").padding(.top, 12)
                            Text(instructions).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                        }
                        .pageRow(top: 6, bottom: 20)
                        .listRowSeparator(.hidden)
                    }
                    #endif
                } header: {
                    #if os(iOS)
                    header
                    #endif
                }
                .onPaper()
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)   // a one-line row (the note, what is done) is its own height, not 44 points of air
            // A row arriving is laid out in a transaction, so the foot below it glides down as the rail draws (the
            // row's own pieces are still hidden; the list's fade shows nothing).
            .animation(streaming && !reduceMotion ? .easeOut(duration: 0.45) : nil, value: blocks.map(\.id))
            // The page between its stages, and the plan settling: the foot changes what it says in place.
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: stage)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: streaming)
            // The minute turning moves "Now" to the next block, fades the one just over, asks "finished?".
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: timeline)
            .onChange(of: blocks.count) { _, _ in
                guard streaming else { return }   // keep the newest block in view as the plan grows
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5).delay(0.3)) { proxy.scrollTo("foot", anchor: .bottom) }
            }
        }
    }

    /// The last row, one row whatever it says, so the page never loses its foot: the planner at work, large while
    /// nothing has come yet and a line under the rows while they arrive; then, settled, where the plan stops tonight
    /// (on a Mac that is in the column beside the page, and the foot keeps its room so the rows do not drop).
    private var foot: some View {
        VStack(alignment: .leading, spacing: 0) {
            if stage == .working {
                WorkingLine(kicker: "Planning", line: "Reading your calendar and the coming weeks…")
                    .padding(.horizontal, -20)   // the line keeps its own 20 points; the row has the page's already
                    .transition(.fadeThrough)   // one place: the old out before the new in
            } else if streaming {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Planning the rest…").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.leading, 92 + 34)   // under the words, past the time column and the rail
                .padding(.vertical, 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Planning the rest")
                .transition(.fadeThrough)   // one place: the old out before the new in
            } else {
                #if os(iOS)
                // Where the plan stops, the choice of where it stops tonight.
                TonightUntil(end: until, usual: usualEnd, choose: chooseEnd)
                    .padding(.leading, blocks.isEmpty ? 0 : 92 + 34)   // under the words, past the time column and the rail
                    .padding(.vertical, 14)
                    .transition(.fadeThrough)   // one place: the old out before the new in
                #else
                Color.clear.frame(height: 44).accessibilityHidden(true)
                #endif
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
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
            .lineLimit(1)                                       // a time is one figure: never "1:3 / 0 A / M"
            .dynamicTypeSize(...DynamicTypeSize.accessibility1) // the column keeps its measure; the title beside it grows on
            .frame(width: 92, alignment: .trailing)
            .minimumScaleFactor(0.6)
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
                        .font(.body.weight(block.kind == .work || block.kind == .study ? .semibold : .regular))
                        .foregroundStyle(block.kind == .fixed ? .secondary : .primary)
                        .strikethrough(block.isDone, color: .secondary)
                    if block.kind != .work, block.kind != .study, block.title.caseInsensitiveCompare(Self.kindName(block.kind)) != .orderedSame {   // "Rest" needs no "Rest" chip, "Study for Test 1" no "Study" one
                        Text(Self.kindName(block.kind)).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Design.rule, in: Capsule())
                    }
                }
                if let within = block.within {   // time the calendar set aside to study, which the planner filled: the event keeps its name
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").imageScale(.small)
                        Text(within)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !block.reason.isEmpty { Text(block.reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.vertical, 14)
            .opacity(wordsIn ? 1 : 0)
            .offset(x: wordsIn ? 0 : 6)
            Spacer(minLength: 0)
        }
        .opacity(phase == .past && !asking ? 0.45 : 1)   // a block asking "finished?" waits on the user: it is not faded with the past
        // No animation of its own: a mark arrives in the plan's transaction (`AppModel.markBlock`), which the list
        // grows the row by too. One of its own ran on another curve, and the row's words slid inside a row that
        // was still growing.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.clock(block.start)) to \(Self.clock(block.end)), \(block.title)\(block.within.map { ", in \($0)" } ?? "")\(block.reason.isEmpty ? "" : ". \(block.reason)")\(block.isDone ? ", done" : block.isSkipped ? (block.wasLeftUnfinished ? ", not finished" : ", skipped") : asking ? ", finished?" : phase == .current ? ", now" : "")")
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
            case .work, .study: Circle().fill(.primary).frame(width: size, height: size)
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
        switch kind { case .work: "Work"; case .study: "Study"; case .meal: "Meal"; case .rest: "Rest"; case .fixed: "Calendar" }
    }
}

/// Where the plan stops tonight: "Tonight until 10 PM", the time a pop-up button of the ends one may choose, 6 PM to 4 AM.
/// A change is for this night only (Health's one-time sleep change, not its schedule); the usual hours are in Tell the
/// Planner, and the menu marks the usual end so the difference shows.
struct TonightUntil: View {
    let end: Int
    let usual: Int
    var choose: (Int) -> Void

    /// The ends still ahead (at 2 AM, 6 PM to 2 AM are over), and the one chosen whatever it is.
    private var choices: [Int] {
        let calendar = Calendar.current, now = Date()
        let into = calendar.dateComponents([.hour], from: PlanHours.day(of: now, calendar: calendar), to: now).hour ?? 0   // hours since the plan's day began, past midnight too
        return PlanHours.ends.filter { $0 > into || $0 == end }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {   // the pop-up button brings its own inset
            Text("Tonight until").foregroundStyle(.secondary).accessibilityHidden(true)   // the pop-up says it
            // The system's pop-up button on both platforms: the time alone on the button, the usual end marked in the list.
            Picker(selection: Binding(get: { end }, set: { choose($0) })) {
                ForEach(choices, id: \.self) { hour in Text(PlanHours.choice(hour, usual: usual)).tag(hour) }
            } label: {
                Text("Tonight until")
            } currentValueLabel: {
                Text(PlanHours.label(end)).font(.subheadline)   // the menu picker sets its value in body type otherwise, a size above the words beside it
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .font(.subheadline)
    }
}

extension PlanHours {
    /// An hour of the day, past 24 for the night after, as the clock says it: "10 PM", "2 AM".
    static func label(_ hour: Int) -> String {
        (moment(hour, on: .now, calendar: .current) ?? .now).formatted(.dateTime.hour())
    }
    /// An end in a list of them: the usual one says so.
    static func choice(_ hour: Int, usual: Int) -> String { hour == usual ? "\(label(hour)) (Usual)" : label(hour) }
}
