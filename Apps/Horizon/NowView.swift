import SwiftUI
import HorizonCore
import IngestKit

/// SPEC §6.3: one button, a disposable plan for the rest of today around the calendar, a reason on every block.
/// Nothing is saved; closing the screen discards it.
struct NowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let plan = model.plan {
                    List {
                        Section {
                            ForEach(plan.blocks) { block in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    Text(range(block)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(block.title)
                                            .font(.body.weight(block.kind == .work ? .medium : .regular))
                                            .foregroundStyle(block.kind == .fixed ? .secondary : .primary)
                                        Text(block.reason).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            if plan.blocks.isEmpty { Text("Nothing to plan.").foregroundStyle(.secondary) }
                        } header: {
                            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        } footer: {
                            Text(footer(plan))
                        }
                    }
                    .listStyle(.plain)
                } else if model.planning {
                    ProgressView("Planning the rest of today…")
                } else {
                    ContentUnavailableView {
                        Label("Now", systemImage: "sun.horizon")
                    } description: {
                        Text("One plan for the rest of today, around your calendar, with a reason on every block. It is not saved.")
                    } actions: {
                        Button("Plan Today") { Task { await model.planToday() } }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Now")
            .toolbar {
                if model.plan != nil {
                    ToolbarItem(placement: .primaryAction) { Button("Plan Again") { Task { await model.planToday() } }.disabled(model.planning) }
                }
            }
            .onAppear { if MainTabs.debugFlag("--plan"), model.plan == nil, !model.planning { Task { await model.planToday() } } }
        }
    }

    private func range(_ block: PlanBlock) -> String {
        let f = Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)).minute()
        return "\(block.start.formatted(f))–\(block.end.formatted(f))"
    }

    private func footer(_ plan: DayPlan) -> String {
        var parts: [String] = []
        if let note = plan.note { parts.append(note) }
        switch plan.route {
        case .privateCloudCompute?: parts.append("Planned in Private Cloud Compute.")
        case .onDevice?: parts.append("Planned on device.")
        case nil: break
        }
        parts.append("Not saved: tomorrow starts from nothing.")
        return parts.joined(separator: " ")
    }
}
