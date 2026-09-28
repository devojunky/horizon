#if os(macOS)
import SwiftUI
import SwiftData
import HorizonCore

/// The column beside the day's plan on a Mac: where tonight ends, what the planner was told, and what is due in the
/// coming week, the work a plan is made of. A phone keeps tonight's end at the foot of the plan and the rest in
/// the planner's sheet; a window has room to keep all of it in view while the plan is read. An item opens its editor.
struct NowRail: View {
    let end: Int
    let usualEnd: Int
    var chooseEnd: (Int) -> Void
    var tell: () -> Void
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Obligation> { $0.deletedAt == nil && $0.due != nil }, sort: \Obligation.due) private var dated: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var editing: Obligation?

    /// What falls due from today through the next seven days.
    private var dueSoon: [Obligation] {
        let today = Calendar.current.startOfDay(for: Date())
        let limit = today.addingTimeInterval(8 * 86_400)
        return dated.filter { item in
            guard item.completedAt == nil, let due = item.due else { return false }
            return due >= today && due < limit
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                RailSection("Tonight") {
                    TonightUntil(end: end, usual: usualEnd, choose: chooseEnd)
                    Text("For tonight only. Your usual hours are in Tell the Planner.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RailSection("You told the planner") {
                    Text(model.planInstructions.isEmpty ? "Nothing yet. A shift, practice, a night off: the planner works around what you tell it." : model.planInstructions)
                        .font(.subheadline).foregroundStyle(model.planInstructions.isEmpty ? .secondary : .primary)
                        .lineLimit(10).fixedSize(horizontal: false, vertical: true)
                    Button("Tell the Planner…", action: tell).controlSize(.small).padding(.top, 2)
                }
                RailSection("Due this week") {
                    if dueSoon.isEmpty { Text("Nothing due in the next seven days.").font(.subheadline).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(dueSoon.prefix(8)) { item in
                            Button { editing = item } label: { DueRow(item: item) }
                                .buttonStyle(.plain)
                                .help("Edit \(item.title)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.trailing, Design.margin)
            .padding(.vertical, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
    }
}

/// An item due soon, in the column beside the plan: its name, its course and when, and what it is worth.
private struct DueRow: View {
    let item: Obligation
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium).lineLimit(2)
                Text([item.course?.displayName, Design.due(item.due, hasTime: item.dueHasTime)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Design.points(item.pointsAtStake).font(.subheadline.weight(.semibold))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
